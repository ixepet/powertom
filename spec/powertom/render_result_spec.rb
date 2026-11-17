# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe PowerTom::RenderResult do
  def surgery_files
    Dir.glob(File.join(Dir.tmpdir, "powertom_surgery*.pptx"))
  end

  it "#close removes the intermediate surgery file" do
    tempfile = Tempfile.new(["powertom_surgery", ".pptx"])
    path = tempfile.path
    result = described_class.new(nil, nil, [], tempfile: tempfile)

    expect(File).to exist(path)
    result.close
    expect(File).not_to exist(path)
  end

  it "#save removes the intermediate surgery file" do
    tempfile = Tempfile.new(["powertom_surgery", ".pptx"])
    path = tempfile.path
    adapter = double("adapter", save: nil)
    result = described_class.new(adapter, double("prs"), [], tempfile: tempfile)

    result.save("/tmp/powertom_render_result_spec.pptx")
    expect(File).not_to exist(path)
  end

  it "removes the intermediate file when rendering fails after surgery" do
    Dir.mktmpdir("powertom_render_result_spec") do |dir|
      path = File.join(dir, "template.pptx")
      prs = Pptx::Presentation.new_default
      slide = prs.slides.add(prs.slide_layouts["Blank"])
      box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(1)],
                                     size: [Pptx.inches(4), Pptx.inches(1)])
      box.text_frame.text = "{{name}}"
      slide.notes = "{{#each classes}}"
      prs.save(path)

      before = surgery_files.size
      expect { PowerTom.render(path, data: { classes: [{}] }) }
        .to raise_error(PowerTom::MissingDataError)
      expect(surgery_files.size).to eq(before)
    end
  end
end
