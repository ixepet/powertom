# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# 受限聚合(0.8.0):{{array[].field:sum/avg/min/max}} / {{array[]:count}}。
RSpec.describe "受限聚合" do
  around do |example|
    Dir.mktmpdir("aggregation_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def save(prs, name)
    path = File.join(@dir, "#{name}_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def text_deck(text, notes: nil)
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(0.5)],
                                   size: [Pptx.inches(10), Pptx.inches(1)])
    box.text_frame.text = text
    slide.notes = notes if notes
    prs
  end

  def texts(pptx)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    adapter.paragraph_contexts(adapter.open(pptx)).map { |c| c[:run_texts].join }
  end

  def render_text(prs, data)
    out = File.join(@dir, "out_#{SecureRandom.hex(4)}.pptx")
    PowerTom.render(save(prs, "template"), data: data).save(out)
    texts(out)
  end

  it "页面文本:sum / avg / min / max / count,nil 跳过" do
    data = { classes: [{ avg: 82.5 }, { avg: 91.0 }, { avg: nil }, { avg: 70.5 }] }
    text = "{{classes[].avg:sum}}|{{classes[].avg:avg}}|{{classes[].avg:min}}|" \
           "{{classes[].avg:max}}|{{classes[]:count}}"

    expect(render_text(text_deck(text), data)).to eq(["244.0|81.33333333333333|70.5|91.0|4"])
  end

  it "空数组:sum=0、count=0、avg 为空" do
    text = "{{rows[].value:sum}}|{{rows[]:count}}|{{rows[].value:avg}}"

    expect(render_text(text_deck(text), rows: [])).to eq(["0|0|"])
  end

  it "#each 页:聚合取当前项的数组" do
    data = { groups: [{ rows: [1, 2] }, { rows: [10] }] }
    template = save(text_deck("{{rows[]:sum}}", notes: "{{#each groups}}"), "each")

    out = File.join(@dir, "each_out.pptx")
    PowerTom.render(template, data: data).save(out)

    expect(texts(out)).to eq(%w[3 10])
  end

  it "表格合计行:循环行照常展开,合计行做聚合" do
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    frame = slide.shapes.add_table(
      3, 2,
      at: [Pptx.inches(0.5), Pptx.inches(1)],
      size: [Pptx.inches(8), Pptx.inches(3)]
    )
    table = frame.table
    table.cell(0, 0).text = "班级"
    table.cell(0, 1).text = "均分"
    table.cell(1, 0).text = "{{classes[].name}}"
    table.cell(1, 1).text = "{{classes[].avg}}"
    table.cell(2, 0).text = "合计"
    table.cell(2, 1).text = "{{classes[].avg:sum}}"

    out = File.join(@dir, "table_out.pptx")
    data = { classes: [{ name: "A", avg: 80 }, { name: "B", avg: 90 }] }
    template = save(prs, "table")
    PowerTom.render(template, data: data).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    rendered = adapter.open(out).slides[0].shapes.to_a.find { |s| s.respond_to?(:table?) && s.table? }
    rows = (0...rendered.table.rows.size).map do |r|
      (0...rendered.table.columns.size).map { |c| rendered.table.cell(r, c).text }
    end
    expect(rows).to eq([%w[班级 均分], %w[A 80], %w[B 90], %w[合计 170]])
  end

  it "check 拒绝非数值字段与缺失数组" do
    text = "{{classes[].avg:sum}}"
    non_numeric = PowerTom.check(save(text_deck(text), "bad"), data: { classes: [{ avg: "n/a" }] })
    expect(non_numeric.errors.map(&:message).join).to include("must be numeric")

    missing = PowerTom.check(save(text_deck(text), "missing"), data: {})
    expect(missing.errors.map(&:message).join).to include("classes")
  end

  it "非聚合的 [] 在表格外仍是语法错误" do
    report = PowerTom.check(save(text_deck("{{classes[].avg}}"), "plain"))

    expect(report.ok?).to be(false)
    expect(report.errors.map(&:message).join).to include("outside a table row")
  end
end
