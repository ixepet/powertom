# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# 图片 contain 模式:powertom:image:<field>; mode=contain。
# 等比缩放到占位框内并居中,不裁切;fill 仍是默认行为。
RSpec.describe PowerTom, ".render 图片 contain 模式" do
  around do |example|
    Dir.mktmpdir("image_contain_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template(width_inches, height_inches, label: "powertom:image:cover; mode=contain")
    placeholder = PowerTomDev::ImageFactory.write_png(
      File.join(@dir, "placeholder.png"), 300, 200
    )
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    picture = slide.shapes.add_picture(
      placeholder,
      at: [Pptx.inches(1), Pptx.inches(1)],
      width: Pptx.inches(width_inches), height: Pptx.inches(height_inches)
    )
    picture.name = label

    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def image(width, height)
    PowerTomDev::ImageFactory.write_png(
      File.join(@dir, "image_#{width}x#{height}.png"), width, height
    )
  end

  def picture(pptx, shape_name)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    picture = adapter.find_shape(adapter.open(pptx), 1, shape_name)
    {
      left: picture.left.inches,
      top: picture.top.inches,
      width: picture.width.inches,
      height: picture.height.inches,
      crop_left: picture.crop_left,
      crop_top: picture.crop_top,
      crop_right: picture.crop_right,
      crop_bottom: picture.crop_bottom
    }
  end

  def render(template, image_path)
    out = File.join(@dir, "out_#{SecureRandom.hex(4)}.pptx")
    PowerTom.render(template, data: { cover: image_path }).save(out)
    out
  end

  it "contain:等比缩放 + 居中留边,不裁切" do
    template = build_template(4, 4) # 1:1 占位框
    out = render(template, image(600, 200)) # 3:1 图片
    info = picture(out, "powertom:image:cover; mode=contain")

    aggregate_failures do
      # 4in 宽 × (4/3)in 高,垂直居中
      expect(info[:left]).to be_within(0.01).of(1.0)
      expect(info[:top]).to be_within(0.01).of(1.0 + ((4 - (4.0 / 3)) / 2))
      expect(info[:width]).to be_within(0.01).of(4.0)
      expect(info[:height]).to be_within(0.01).of(4.0 / 3)
      expect(info.values_at(:crop_left, :crop_top, :crop_right, :crop_bottom)).to all(eq(0.0))
    end
  end

  it "显式 mode=fill 保持原有填满裁切行为" do
    template = build_template(4, 4, label: "powertom:image:cover; mode=fill")
    out = render(template, image(600, 200))
    info = picture(out, "powertom:image:cover; mode=fill")

    aggregate_failures do
      expect(info[:left]).to be_within(0.01).of(1.0)
      expect(info[:top]).to be_within(0.01).of(1.0)
      expect(info[:width]).to be_within(0.01).of(4.0)
      expect(info[:height]).to be_within(0.01).of(4.0)
      expect(info[:crop_left]).to be_within(0.01).of(1.0 / 3)
      expect(info[:crop_right]).to be_within(0.01).of(1.0 / 3)
      expect(info[:crop_top]).to eq(0.0)
    end
  end

  it "contain 不触发居中裁切 warning" do
    template = build_template(4, 4)
    result = PowerTom.render(template, data: { cover: image(600, 200) })
    expect(result.warnings.join).not_to include("centre-cropped")
  end

  it "alt text 中声明 mode=contain 同样生效" do
    template = build_template(4, 4, label: "cover")
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(template)
    picture = adapter.find_shape(prs, 1, "cover")
    picture.element.xpath("./p:nvPicPr/p:cNvPr").first.set("descr", "powertom:image:cover; mode=contain")
    adapter.save(prs, template)

    out = render(template, image(600, 200))
    info = picture(out, "cover")

    expect(info[:width]).to be_within(0.01).of(4.0)
    expect(info[:height]).to be_within(0.01).of(4.0 / 3)
  end

  it "非法 mode → render 报错,check 也报 error" do
    template = build_template(4, 4, label: "powertom:image:cover; mode=zoom")

    aggregate_failures do
      expect { PowerTom.render(template, data: { cover: image(600, 200) }) }
        .to raise_error(PowerTom::Error,
                        /picture 'powertom:image:cover; mode=zoom'.*unsupported picture option 'mode=zoom'/)

      result = PowerTom.check(template)
      expect(result.errors.map(&:message).join).to include("unsupported picture option 'mode=zoom'")
    end
  end
end
