# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "zip"
require_relative "../../tools/ooxml_lint"

# 公开金样本(§5.5):提交在库内的微型模板,让 split-run 合并(§5.1)、一段多标签、
# {{#each}} 页克隆、{{#if}} 删页、图片替换(§5.3)、图表数据绑定(§5.4)与 LibreOffice
# 保真的端到端验收进入公开 CI,不再依赖私有 hai_mate 金样本。
# 模板由 tools/build_mini_golden.rb 生成,结构与下面的断言一一对应。
RSpec.describe PowerTom, ".render mini golden" do
  template_path = File.expand_path("../fixtures/mini/template.pptx", __dir__)

  # 注意:describe 体内的常量是全局作用域,命名必须唯一,避免与其他 spec 互踩
  MINI_DATA = {
    title: "Mini Golden",
    split_title: "Merged",
    first: "A",
    second: "B",
    caption: "caption text",
    items: [
      { headline: "Item One", detail: "Detail One" },
      { headline: "Item Two", detail: "Detail Two" },
      { headline: "Item Three", detail: "Detail Three" }
    ],
    show_extra: true,
    extra_note: "extra visible",
    sales: {
      categories: %w[Jan Feb],
      series: [{ name: "2025", values: [10, 20] }, { name: "2026", values: [30, 40] }]
    }
  }.freeze

  @tmp_root = nil
  before(:all) do
    skip "缺少 fixture — 运行 bundle exec ruby tools/build_mini_golden.rb 重新生成" unless
      File.file?(template_path)

    @tmp_root = Dir.mktmpdir("powertom_mini_golden")
    @cover_image = PowerTomDev::ImageFactory.write_png(File.join(@tmp_root, "cover.png"), 450, 300)
    @out = File.join(@tmp_root, "out.pptx")
    rendered = PowerTom.render(template_path, data: MINI_DATA.merge(cover: @cover_image))
    @warnings = rendered.warnings
    rendered.save(@out)
  end
  after(:all) do
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  def slide_count(pptx)
    PowerTom::Adapter::RubyPptxAdapter.new.open(pptx).slides.size
  end

  def paragraph_texts(pptx, slide_no)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    adapter.paragraph_contexts(prs)
           .select { |c| c[:slide_no] == slide_no }
           .map { |c| [c[:shape], c[:run_texts]] }
  end

  # 输出文件里指定页指定形状的媒体字节(与 image_replace_spec 同一取法)
  def picture_bytes(pptx, slide_no, shape_name)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    picture = adapter.find_shape(prs, slide_no, shape_name)
    raise "占位形状不存在: #{shape_name}" unless picture

    r_id = picture.element.blip_rId
    Zip::File.open(pptx) do |zip|
      rels = zip.get_input_stream("ppt/slides/_rels/slide#{slide_no}.xml.rels").read
      target = rels[/Id="#{r_id}"[^>]*Target="([^"]+)"/, 1] ||
               rels[/Target="([^"]+)"[^>]*Id="#{r_id}"/, 1]
      zip.get_input_stream("ppt/media/#{File.basename(target.to_s)}").read
    end
  end

  # 输出文件里指定页指定图表的数据(与 chart_binding_spec 同一取法)
  def read_chart(pptx, slide_no, shape_name)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    chart = adapter.find_shape(adapter.open(pptx), slide_no, shape_name).chart
    { categories: chart.categories.map { |c| c.respond_to?(:label) ? c.label : c },
      series: chart.series.map { |s| [s.name, s.values.map(&:to_f)] } }
  end

  it "单 run 标签被替换" do
    title = paragraph_texts(@out, 1).find { |shape, _| shape == "mini-title" }
    expect(title).to eq(["mini-title", ["Mini Golden"]])
  end

  it "跨 run 标签合并到首个 run,静态前后缀保留(§5.1)" do
    split = paragraph_texts(@out, 1).find { |shape, _| shape == "mini-split" }
    expect(split).to eq(["mini-split", ["Before Merged after", ""]])
  end

  it "一段多标签全部替换" do
    pair = paragraph_texts(@out, 1).find { |shape, _| shape == "mini-pair" }
    expect(pair).to eq(["mini-pair", ["A 和 B"]])
  end

  it "{{#each}} 克隆 3 页,克隆页内的跨 run 标签同样合并(§5.2)" do
    expect(slide_count(@out)).to eq(8) # 封面 + 图片 + 3×循环 + 条件 + 图表 + 尾页
    aggregate_failures do
      expect(paragraph_texts(@out, 3)).to include(["mini-headline", ["Item One"]])
      expect(paragraph_texts(@out, 3)).to include(["mini-detail", ["Detail One", ""]])
      expect(paragraph_texts(@out, 4)).to include(["mini-headline", ["Item Two"]])
      expect(paragraph_texts(@out, 5)).to include(["mini-detail", ["Detail Three", ""]])
    end
  end

  it "{{#if}} 为真保留条件页,图表页与静态尾页顺延保留(§5.2)" do
    aggregate_failures do
      expect(paragraph_texts(@out, 6)).to include(["mini-extra", ["extra visible"]])
      expect(paragraph_texts(@out, 8)).to include(["mini-end", ["THE END"]])
    end
  end

  it "图片占位被数据替换:媒体字节一致,比例匹配时零裁切(§5.3)" do
    bytes = picture_bytes(@out, 2, "powertom:image:cover")
    expect(bytes).to eq(File.binread(@cover_image))

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    picture = adapter.find_shape(adapter.open(@out), 2, "powertom:image:cover")
    aggregate_failures do
      expect(picture.crop_left).to eq(0.0)
      expect(picture.crop_right).to eq(0.0)
      expect(picture.crop_top).to eq(0.0)
      expect(picture.crop_bottom).to eq(0.0)
    end
  end

  it "比例匹配的图片不触发居中裁切告警" do
    expect(@warnings.join).not_to include("centre-cropped")
  end

  it "图表占位被数据替换:分类 3→2 缩减,双系列保留(§5.4)" do
    expect(read_chart(@out, 7, "powertom:chart:sales")).to eq(
      categories: %w[Jan Feb],
      series: [["2025", [10.0, 20.0]], ["2026", [30.0, 40.0]]]
    )
  end

  it "输出通过 OOXML 结构校验:无悬空声明/引用,无重复 entry(L1)" do
    expect(PowerTomDev::OoxmlLint.lint(@out)).to be_empty
  end

  it "空数组与假条件:整组删除(all or nothing)" do
    Dir.mktmpdir("powertom_mini_empty") do |dir|
      out = File.join(dir, "out_empty.pptx")
      PowerTom.render(template_path,
                      data: MINI_DATA.merge(cover: @cover_image, items: [], show_extra: false)).save(out)
      expect(slide_count(out)).to eq(4) # 封面 + 图片 + 图表 + 尾页
    end
  end

  context "保真验收(§5.5)" do
    it "渲染产物经 LibreOffice 转换成功且页数正确" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      pdf_dir = Dir.mktmpdir("powertom_mini_pdf")
      profile_dir = Dir.mktmpdir("powertom_mini_lo")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile_dir}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, @out)
      expect(ok).to be(true), "LibreOffice 转换失败"

      pdf = File.join(pdf_dir, "out.pdf")
      expect(File.exist?(pdf)).to be(true)
      expect(File.binread(pdf).scan(%r{/Type\s*/Page[^s]}).size).to eq(8)
    end
  end
end
