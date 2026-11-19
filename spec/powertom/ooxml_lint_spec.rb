# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "zip"
require_relative "../../tools/ooxml_lint"

# L1 结构校验(外部评审 2026-11-17 P0-1/P2-2):PageSurgery 的输出包本身必须
# 是合法 OPC 包——无 notes 的页不得声明 notesSlide Override,任何 .rels 目标
# 与 [Content_Types].xml 声明都不得悬空。PowerPoint 对悬空声明弹"修复",
# LibreOffice 静默容忍,所以用独立结构 lint 把守。
RSpec.describe PowerTom::Adapter::PageSurgery, ".execute" do
  around do |example|
    Dir.mktmpdir("ooxml_lint_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template(notes: nil)
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    box = slide.shapes.add_textbox(at: [Pptx.inches(1), Pptx.inches(1)],
                                   size: [Pptx.inches(6), Pptx.inches(1)])
    box.name = "lint-probe"
    box.text_frame.text = "{{headline}}"
    slide.notes = notes if notes

    path = File.join(@dir, "lint_template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def content_types(path)
    Zip::File.open(path) do |zip|
      zip.get_input_stream("[Content_Types].xml", &:read)
    end
  end

  it "无 notes 的模板克隆后不声明 notesSlide Override(P0-1 回归)" do
    template = build_template
    out = File.join(@dir, "out_no_notes.pptx")
    plan = [{ source: 1, iteration: nil }, { source: 1, iteration: 0 }]

    PowerTom::Adapter::PageSurgery.execute(template, out, plan)

    aggregate_failures do
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
      expect(content_types(out)).not_to include("/ppt/notesSlides/")
    end
  end

  it "有 notes 的模板克隆后 Override 与 part 一一对应" do
    template = build_template(notes: "{{#each items}}")
    out = File.join(@dir, "out_with_notes.pptx")
    plan = [{ source: 1, iteration: 0 }, { source: 1, iteration: 1 }]

    PowerTom::Adapter::PageSurgery.execute(template, out, plan)

    expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    Zip::File.open(out) do |zip|
      parts = zip.entries.map(&:name).grep(%r{ppt/notesSlides/notesSlide\d+\.xml\z})
      overrides = content_types(out).scan(%r{/ppt/notesSlides/notesSlide\d+\.xml})
      aggregate_failures do
        expect(parts.size).to eq(2)
        expect(overrides.sort).to eq(parts.sort.map { |p| "/#{p}" })
      end
    end
  end

  it "lint 能识别人为构造的悬空 Override(防 lint 静默通过)" do
    broken = File.join(@dir, "broken.pptx")
    Zip::OutputStream.open(broken) do |zos|
      zos.put_next_entry("[Content_Types].xml")
      zos.write <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Override PartName="/ppt/notesSlides/notesSlide9.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/>
        </Types>
      XML
    end

    expect(PowerTomDev::OoxmlLint.lint(broken))
      .to include(a_string_matching(%r{Override for missing part: /ppt/notesSlides/notesSlide9\.xml}))
  end
end
