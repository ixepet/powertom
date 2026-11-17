# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# 已知限制的温和告警:图片比例与占位形状差异较大时提示"居中裁切"。
# 不依赖私有金样本,CI 可直接运行。
RSpec.describe "图片比例告警" do
  around do |example|
    Dir.mktmpdir("image_aspect_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template(width_inches, height_inches)
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
    picture.name = "powertom:image:cover"

    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def image(width, height)
    PowerTomDev::ImageFactory.write_png(
      File.join(@dir, "image_#{width}x#{height}.png"), width, height
    )
  end

  it "图片比例与占位形状差异大 → 渲染 warning" do
    template = build_template(4, 4) # 1:1
    result = PowerTom.render(template, data: { cover: image(600, 200) }) # 3:1

    expect(result.warnings.join).to include("picture 'cover'", "differs significantly", "centre-cropped")
  end

  it "图片比例接近占位形状 → 不告警" do
    template = build_template(4, 3) # 1.33:1
    result = PowerTom.render(template, data: { cover: image(400, 300) }) # 1.33:1

    expect(result.warnings.join).not_to include("居中裁切")
  end
end
