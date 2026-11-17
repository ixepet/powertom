# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# 母版/版式标签检查:运行时永远不绑定,PowerTom.check 必须提前报 error。
# 不依赖私有金样本,CI 可直接运行。
RSpec.describe "母版/版式标签检查" do
  around do |example|
    Dir.mktmpdir("check_container_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template
    prs = Pptx::Presentation.new_default
    prs.slides.add(prs.slide_layouts["Blank"])
    yield prs if block_given?

    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  it "母版上的标签 → check 报 error" do
    template = build_template do |prs|
      footer = prs.slide_masters.first.placeholders
                  .by_type(Pptx::Enum::PP_PLACEHOLDER_TYPE::FOOTER)
      footer.text = "{{company}}"
    end

    result = PowerTom.check(template)
    messages = result.errors.map(&:message).join("\n")

    expect(result.ok?).to be(false)
    expect(messages).to include("master shape 'Footer Placeholder 4' contains tags {{company}}")
    expect(messages).to include("tags on masters/layouts never take effect")
  end

  it "版式上的标签 → check 报 error 并指出 layout 名称" do
    template = build_template do |prs|
      layout = prs.slide_masters.first.slide_layouts.first
      layout.placeholders.first.text = "{{agenda}}"
    end

    result = PowerTom.check(template)
    messages = result.errors.map(&:message).join("\n")

    expect(messages).to include("layout『Title Slide』 shape 'Title 1' contains tags {{agenda}}")
  end

  it "母版/版式无标签 → check 不误报" do
    template = build_template
    result = PowerTom.check(template)

    aggregate_failures do
      expect(result.ok?).to be(true)
      expect(result.errors.map(&:message).join).not_to include("masters/layouts")
    end
  end
end
