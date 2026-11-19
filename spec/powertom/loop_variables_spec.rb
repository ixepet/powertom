# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# 循环内只读变量:@index(0 基)/ @index1(1 基)/ @first / @last。
# 覆盖页级 #each、简单行循环、#rows 区块与 #grid。
RSpec.describe "循环变量" do
  around do |example|
    Dir.mktmpdir("loop_variables_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def save(prs, name)
    path = File.join(@dir, "#{name}_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def read_table(pptx)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    frame = prs.slides[0].shapes.to_a.find { |s| s.respond_to?(:table?) && s.table? }
    table = frame.table
    (0...table.rows.size).map { |r| (0...table.columns.size).map { |c| table.cell(r, c).text } }
  end

  def render_table(prs, data)
    out = File.join(@dir, "out_#{SecureRandom.hex(4)}.pptx")
    PowerTom.render(save(prs, "template"), data: data).save(out)
    read_table(out)
  end

  def table_deck(rows)
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    columns = rows.map(&:size).max
    frame = slide.shapes.add_table(
      rows.size, columns,
      at: [Pptx.inches(0.5), Pptx.inches(1)],
      size: [Pptx.inches(10), Pptx.inches(4)]
    )
    table = frame.table
    rows.each_with_index { |cells, r| cells.each_with_index { |text, c| table.cell(r, c).text = text } }
    prs
  end

  it "页级 #each:@index / @index1 / @first / @last 逐项变化" do
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(0.5)],
                                   size: [Pptx.inches(8), Pptx.inches(1)])
    box.text_frame.text = "{{name}} {{@index}} {{@index1}} {{@first}} {{@last}}"
    slide.notes = "{{#each classes}}"
    template = save(prs, "each")

    out = File.join(@dir, "each_out.pptx")
    PowerTom.render(template, data: { classes: [{ name: "A" }, { name: "B" }] }).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    texts = adapter.paragraph_contexts(adapter.open(out)).map { |c| c[:run_texts].join }
    expect(texts).to eq(["A 0 1 true false", "B 1 2 false true"])
  end

  it "简单行循环:{{@index1}} 按行递增,静态行保持原样" do
    rows = [["班级", "序号"],
            ["{{classes[].name}}", "{{@index1}}"],
            ["合计", "-"]]
    result = render_table(table_deck(rows), classes: [{ name: "A" }, { name: "B" }, { name: "C" }])

    expect(result).to eq([["班级", "序号"], ["A", "1"], ["B", "2"], ["C", "3"], ["合计", "-"]])
  end

  it "#rows 区块:{{@index1}} 指向当前区块项" do
    rows = [["年级", "序号"],
            ["{{#rows grades}}", ""],
            ["{{grades[].name}}", "{{@index1}}"],
            ["{{/rows}}", ""]]
    result = render_table(table_deck(rows), grades: [{ name: "G1" }, { name: "G2" }])

    expect(result).to eq([%w[年级 序号], %w[G1 1], %w[G2 2]])
  end

  it "#grid:{{@index1}} 指向当前数据行" do
    rows = [["班级 {{#grid rows: distribution cols: bands value: counts}}", "{{col.label}}"],
            ["{{row.name}} {{@index1}}", "{{cell}}"]]
    data = {
      distribution: [{ name: "A", counts: { "X" => 1 } }, { name: "B", counts: { "X" => 2 } }],
      bands: [{ key: "X", label: "X" }]
    }
    result = render_table(table_deck(rows), data)

    expect(result).to eq([["班级", "X"], ["A 1", "1"], ["B 2", "2"]])
  end

  it "循环外使用:@index 在 check 与 render 都是模板错误" do
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(0.5)],
                                   size: [Pptx.inches(4), Pptx.inches(1)])
    box.text_frame.text = "{{@index}}"
    template = save(prs, "outside")

    report = PowerTom.check(template, data: {})
    expect(report.errors.map(&:message).join).to include("is only available inside a table row loop")
    expect { PowerTom.render(template, data: {}) }.to raise_error(PowerTom::TemplateSyntaxError,
                                                                  /only available inside a loop/)
  end

  it "表格静态行使用:@index 被 check 拒绝" do
    rows = [["序号 {{@index}}", "班级"],
            ["{{classes[].name}}", "{{@index1}}"]]
    template = save(table_deck(rows), "static")
    report = PowerTom.check(template, data: { classes: [{ name: "A" }] })

    expect(report.ok?).to be(false)
    expect(report.errors.map(&:message).join).to include("outside the table's loop rows")
  end

  it "未知的 @ 变量仍是语法错误" do
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(0.5)],
                                   size: [Pptx.inches(4), Pptx.inches(1)])
    box.text_frame.text = "{{@nope}}"
    template = save(prs, "unknown")

    report = PowerTom.check(template)
    expect(report.ok?).to be(false)
    expect(report.errors.map(&:message).join).to include("not a valid tag")
  end
end
