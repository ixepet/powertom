# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "zip"

# AssetResolver(0.7.0):图片字段是引用,由应用决定真实来源(路径或字节)。
RSpec.describe "AssetResolver" do
  around do |example|
    Dir.mktmpdir("asset_resolver_spec") do |dir|
      @dir = dir
      PowerTom.configure { |config| config.asset_resolver = nil }
      example.run
    ensure
      PowerTom.configure { |config| config.asset_resolver = nil }
    end
  end

  def placeholder
    @placeholder ||= PowerTomDev::ImageFactory.write_png(File.join(@dir, "placeholder.png"), 200, 200)
  end

  def target_png
    @target_png ||= PowerTomDev::ImageFactory.write_png(File.join(@dir, "target.png"), 320, 180)
  end

  def build_template
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    picture = slide.shapes.add_picture(
      placeholder,
      at: [Pptx.inches(1), Pptx.inches(1)],
      width: Pptx.inches(4), height: Pptx.inches(3)
    )
    picture.name = "powertom:image:logo"
    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def media_bytes(pptx)
    Zip::File.open(pptx) do |zip|
      zip.entries.select { |e| e.name.start_with?("ppt/media/") }
         .map { |e| zip.get_input_stream(e.name).read }
    end
  end

  it "resolver 返回字节:按 {data:, extension:} 写入图片 part" do
    resolver = ->(_ref, _ctx) { { data: File.binread(target_png), extension: "png" } }
    out = File.join(@dir, "out.pptx")
    PowerTom.render(build_template, data: { logo: "store://logo" }, asset_resolver: resolver).save(out)

    expect(media_bytes(out)).to include(File.binread(target_png))
  end

  it "resolver 返回路径:与直接传路径等价" do
    resolver = ->(_ref, _ctx) { target_png }
    out = File.join(@dir, "out_path.pptx")
    PowerTom.render(build_template, data: { logo: "store://logo" }, asset_resolver: resolver).save(out)

    expect(media_bytes(out)).to include(File.binread(target_png))
  end

  it "全局配置生效" do
    PowerTom.configure do |config|
      config.asset_resolver = ->(_ref, _ctx) { { data: File.binread(target_png), extension: "png" } }
    end
    out = File.join(@dir, "out_global.pptx")
    PowerTom.render(build_template, data: { logo: "anything" }).save(out)

    expect(media_bytes(out)).to include(File.binread(target_png))
  end

  it "resolver 返回 nil:render 报错" do
    resolver = ->(_ref, _ctx) {}

    expect do
      PowerTom.render(build_template, data: { logo: "missing" }, asset_resolver: resolver)
    end.to raise_error(PowerTom::Error, /asset resolver returned nil/)
  end

  it "check 使用 resolver 校验资源" do
    data = { logo: "store://logo" }
    template = build_template

    ok = PowerTom.check(template, data: data,
                                  asset_resolver: ->(_ref, _ctx) { { data: "png", extension: "png" } })
    expect(ok.ok?).to be(true)

    missing = PowerTom.check(template, data: data, asset_resolver: ->(_ref, _ctx) {})
    expect(missing.ok?).to be(false)
    expect(missing.errors.map(&:message).join).to include("asset resolver returned nil")

    raised = PowerTom.check(template, data: data,
                                      asset_resolver: ->(_ref, _ctx) { raise "boom" })
    expect(raised.ok?).to be(false)
    expect(raised.errors.map(&:message).join).to include("asset resolver failed")
  end
end
