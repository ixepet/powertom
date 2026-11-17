# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "fileutils"
require "zip"

# M4:图片替换(§5.3)。powertom:image:字段名 占位 → 数据里的图片文件,
# 填满形状、居中裁切;#each 克隆页作用域感知,每页各自取本项的图片。
RSpec.describe PowerTom, ".render 图片替换" do
  fixture_dir = File.expand_path("../fixtures/hai_mate", __dir__)
  template_path = File.join(fixture_dir, "template.pptx")

  # 占位形状:图片 41(P5,7.7x4.5in,纵横比 1.71)、图片 18(P9,6.3x3.7in,1.70)
  RENAMES = [
    { slide_no: 5, old_name: "图片 41", new_name: "powertom:image:banner" },
    { slide_no: 9, old_name: "图片 18", new_name: "powertom:image:cover" }
  ].freeze

  IMAGE_COVER_LABELS = [
    { slide_no: 9, shape: "文本框 30", old_text: "每周日晚自动生成下周晨读材料包",
      runs: ["{{headline}}"] }
  ].freeze

  # 三张不同纵横比的 PNG:1.5 / 2.0 / 0.25
  IMG_A = { w: 300, h: 200 }.freeze
  IMG_B = { w: 600, h: 300 }.freeze
  IMG_C = { w: 100, h: 400 }.freeze

  @tmp_root = nil
  before(:all) do
    skip "缺少 fixture — 放好原始 pptx 后运行 rake fixtures:generate" unless File.file?(template_path)
    @tmp_root = Dir.mktmpdir("powertom_image_spec")
    @img_a = PowerTomDev::ImageFactory.write_png(File.join(@tmp_root, "img_a.png"), IMG_A[:w], IMG_A[:h])
    @img_b = PowerTomDev::ImageFactory.write_png(File.join(@tmp_root, "img_b.png"), IMG_B[:w], IMG_B[:h])
    @img_c = PowerTomDev::ImageFactory.write_png(File.join(@tmp_root, "img_c.png"), IMG_C[:w], IMG_C[:h])

    @labeled = File.join(@tmp_root, "labeled.pptx")
    PowerTomDev::LabelInjector.inject(
      template_path, @labeled, IMAGE_COVER_LABELS,
      notes_assignments: { 9 => "{{#each scenarios}}" },
      renames: RENAMES
    )

    @out = File.join(@tmp_root, "out.pptx")
    PowerTom.render(@labeled, data: {
                      banner: @img_b,
                      scenarios: [
                        { headline: "晨读材料包", cover: @img_a },
                        { headline: "家长会材料", cover: @img_b },
                        { headline: "成绩分析", cover: @img_c }
                      ]
                    }).save(@out)
  end
  after(:all) do
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  def slide_count(pptx)
    PowerTom::Adapter::RubyPptxAdapter.new.open(pptx).slides.size
  end

  # 输出文件里指定页指定形状的 {rId:, part:, bytes:, crop:}
  def picture_info(pptx, slide_no, shape_name)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    picture = adapter.find_shape(prs, slide_no, shape_name)
    return nil unless picture

    r_id = picture.element.blip_rId
    Zip::File.open(pptx) do |zip|
      rels_name = "ppt/slides/_rels/slide#{slide_no}.xml.rels"
      rels = zip.get_input_stream(rels_name).read
      target = rels[/Id="#{r_id}"[^>]*Target="([^"]+)"/, 1] ||
               rels[/Target="([^"]+)"[^>]*Id="#{r_id}"/, 1]
      part = "ppt/media/#{File.basename(target.to_s)}"
      bytes = zip.get_input_stream(part).read
      { r_id: r_id, part: part, bytes: bytes, crop: picture }
    end
  end

  it "#each 克隆页各自替换为本项图片:字节逐一对得上" do
    aggregate_failures do
      expect(slide_count(@out)).to eq(20)
      expect(picture_info(@out, 9, "powertom:image:cover")[:bytes])
        .to eq(File.binread(@img_a))
      expect(picture_info(@out, 10, "powertom:image:cover")[:bytes])
        .to eq(File.binread(@img_b))
      expect(picture_info(@out, 11, "powertom:image:cover")[:bytes])
        .to eq(File.binread(@img_c))
    end
  end

  it "非克隆页图片替换 + 内容类型一致(§5.3):banner 字节匹配" do
    expect(picture_info(@out, 5, "powertom:image:banner")[:bytes])
      .to eq(File.binread(@img_b))
  end

  it "填满形状居中裁切:图比框扁 → 裁左右;图比框瘦长 → 裁上下" do
    # banner 占位 1.71,IMG_B 2.0(更扁)→ 裁左右各约 0.072,上下不裁
    banner = picture_info(@out, 5, "powertom:image:banner")[:crop]
    aggregate_failures do
      expect(banner.crop_left).to be_within(0.01).of(0.072)
      expect(banner.crop_right).to be_within(0.01).of(0.072)
      expect(banner.crop_top).to eq(0.0)
      expect(banner.crop_bottom).to eq(0.0)
    end

    # cover 占位 1.70,IMG_A 1.5(更瘦)→ 裁上下,左右不裁
    cover9 = picture_info(@out, 9, "powertom:image:cover")[:crop]
    aggregate_failures do
      expect(cover9.crop_top).to be_within(0.01).of(0.0597)
      expect(cover9.crop_bottom).to be_within(0.01).of(0.0597)
      expect(cover9.crop_left).to eq(0.0)
    end

    # IMG_C 0.25(极瘦)→ 大幅裁上下
    cover11 = picture_info(@out, 11, "powertom:image:cover")[:crop]
    expect(cover11.crop_top + cover11.crop_bottom).to be_within(0.02).of(0.853)
  end

  it "strict 缺图片字段 → MissingDataError 定位页码与字段" do
    expect do
      PowerTom.render(@labeled, data: {
                        scenarios: [{ headline: "x", cover: @img_a }, { headline: "y", cover: @img_b },
                                    { headline: "z", cover: @img_c }]
                      })
    end.to raise_error(PowerTom::MissingDataError, /slide 5.*banner/)
  end

  it "strict: false 缺图片字段 → 保留占位图并记 warning" do
    result = PowerTom.render(@labeled, data: {
                               scenarios: [{ headline: "x", cover: @img_a }, { headline: "y", cover: @img_b },
                                           { headline: "z", cover: @img_c }]
                             }, strict: false)
    result.save(File.join(@tmp_root, "loose.pptx"))
    aggregate_failures do
      expect(result.warnings.join).to include("banner", "keeping the placeholder")
      # 占位图未被动过:blip rId 与注入模板一致
      before_rid = picture_info(@labeled, 5, "powertom:image:banner")[:r_id]
      after_rid = picture_info(File.join(@tmp_root, "loose.pptx"), 5, "powertom:image:banner")[:r_id]
      expect(after_rid).to eq(before_rid)
    end
  end

  it "图片字段非字符串 → 明确报错" do
    expect do
      PowerTom.render(@labeled, data: { banner: 123, scenarios: [
                        { headline: "x", cover: @img_a }, { headline: "y", cover: @img_b },
                        { headline: "z", cover: @img_c }
                      ] })
    end.to raise_error(PowerTom::Error, /banner.*String/)
  end

  it "图片文件不存在 → 明确报错" do
    missing = File.join(@tmp_root, "no_such.png")
    expect do
      PowerTom.render(@labeled, data: { banner: missing, scenarios: [
                        { headline: "x", cover: @img_a }, { headline: "y", cover: @img_b },
                        { headline: "z", cover: @img_c }
                      ] })
    end.to raise_error(PowerTom::Error, /file does not exist.*no_such\.png/)
  end

  it "alt text 定位也能命中(§5.3:name 或 alt text)" do
    # 把 P9 的图片改回原名、alt text 写约定格式 → 引擎照样识别
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(@labeled)
    pic = adapter.find_shape(prs, 9, "powertom:image:cover")
    cnv_pr = pic.element.xpath("./p:nvPicPr/p:cNvPr").first
    cnv_pr.set("descr", "powertom:image:alt_cover")
    pic.name = "图片 18"
    alt_labeled = File.join(@tmp_root, "alt_labeled.pptx")
    adapter.save(prs, alt_labeled)

    contexts = adapter.picture_contexts(adapter.open(alt_labeled))
    fields = contexts.select { |c| c[:slide_no] == 9 }.map { |c| c[:field] }
    expect(fields).to include("alt_cover")
  end

  context "保真验收(§5.5)" do
    it "替换后的 deck 经 LibreOffice 转换成功且页数正确" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      pdf_dir = Dir.mktmpdir("powertom_pdf")
      profile_dir = Dir.mktmpdir("powertom_lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile_dir}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, @out)
      expect(ok).to be(true), "LibreOffice 转换失败"
      pdf = File.join(pdf_dir, "out.pdf")
      expect(File.exist?(pdf)).to be(true)
      expect(File.binread(pdf).scan(%r{/Type\s*/Page[^s]}).size).to eq(20)
    end
  end
end
