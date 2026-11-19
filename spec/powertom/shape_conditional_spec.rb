# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# 形状级条件:powertom:if:<field>,falsy 时删除该形状(含组合)。
RSpec.describe "形状级条件(powertom:if)" do
  around do |example|
    Dir.mktmpdir("shape_conditional_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template(notes: nil)
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    add_box(slide, "powertom:if:show_logo", "LOGO", 0.5)
    add_box(slide, "powertom:if:show_note", "NOTE", 2.0)
    add_box(slide, "body", "BODY", 3.5)
    slide.notes = notes if notes
    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def add_box(slide, name, text, top)
    box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(top)],
                                   size: [Pptx.inches(6), Pptx.inches(1)])
    box.name = name
    box.text_frame.text = text
    box
  end

  def render(template, data)
    out = File.join(@dir, "out_#{SecureRandom.hex(4)}.pptx")
    PowerTom.render(template, data: data).save(out)
    out
  end

  def texts(pptx)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    adapter.paragraph_contexts(adapter.open(pptx)).map { |c| c[:run_texts].join }
  end

  it "falsy 删除形状,truthy 保留" do
    out = render(build_template, show_logo: false, show_note: true)

    expect(texts(out)).to eq(%w[NOTE BODY])
  end

  it "全部 falsy 时只留下普通形状" do
    out = render(build_template, show_logo: nil, show_note: false)

    expect(texts(out)).to eq(["BODY"])
  end

  it "#each 页按当前项求值" do
    template = build_template(notes: "{{#each slides}}")
    out = render(template, slides: [{ show_logo: true, show_note: false },
                                    { show_logo: false, show_note: true }])

    expect(texts(out)).to eq(%w[LOGO BODY NOTE BODY])
  end

  it "check 在样例数据缺字段时报 error" do
    report = PowerTom.check(build_template, data: { show_logo: true })

    expect(report.ok?).to be(false)
    expect(report.errors.map(&:message).join).to include("show_note")
  end

  it "check 无样例数据时不报 error" do
    report = PowerTom.check(build_template)

    expect(report.ok?).to be(true)
  end
end
