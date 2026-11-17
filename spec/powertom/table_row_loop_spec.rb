# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# 表格行循环:{{数组[].字段}} 标记模板行,按数组长度克隆行。
RSpec.describe "表格行循环" do
  around do |example|
    Dir.mktmpdir("table_row_loop_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template(rows, extra_text: nil, notes: nil)
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])

    frame = slide.shapes.add_table(
      rows.size, 2,
      at: [Pptx.inches(0.5), Pptx.inches(1)],
      size: [Pptx.inches(8), Pptx.inches(3)]
    )
    table = frame.table
    rows.each_with_index do |cells, r|
      cells.each_with_index { |text, c| table.cell(r, c).text = text }
    end

    if extra_text
      box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(5)],
                                     size: [Pptx.inches(6), Pptx.inches(0.6)])
      box.text_frame.text = extra_text
    end
    slide.notes = notes if notes

    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def basic_template(**options)
    build_template(
      [["班级", "均分"],
       ["{{classes[].name}}", "{{classes[].avg}}"],
       ["合计", "{{total}}"]],
      **options
    )
  end

  def read_table(pptx)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    frame = prs.slides[0].shapes.to_a.find { |s| s.respond_to?(:table?) && s.table? }
    table = frame.table
    (0...table.rows.size).map do |r|
      (0...table.columns.size).map { |c| table.cell(r, c).text }
    end
  end

  def render(template, data)
    out = File.join(@dir, "out_#{SecureRandom.hex(4)}.pptx")
    PowerTom.render(template, data: data).save(out)
    out
  end

  it "3 项数组 → 克隆 3 行,表头与合计行照常绑定" do
    out = render(basic_template, {
                   classes: [{ name: "一班", avg: 85.1 }, { name: "二班", avg: 79.8 },
                             { name: "三班", avg: 82.3 }],
                   total: "247.2"
                 })

    expect(read_table(out)).to eq([
                                    ["班级", "均分"],
                                    ["一班", "85.1"],
                                    ["二班", "79.8"],
                                    ["三班", "82.3"],
                                    ["合计", "247.2"]
                                  ])
  end

  it "空数组 → 移除循环行,表头与合计保留" do
    out = render(basic_template, { classes: [], total: "0" })
    expect(read_table(out)).to eq([%w[班级 均分], %w[合计 0]])
  end

  it "单元格里的 formatter 生效" do
    template = build_template(
      [["班级", "均分"],
       ["{{classes[].name}}", "{{classes[].avg:number.1}}"]]
    )
    out = render(template, { classes: [{ name: "一班", avg: 85 }] })
    expect(read_table(out)[1]).to eq(["一班", "85.0"])
  end

  it "数组项缺字段 → 报错并定位到行标签" do
    expect { render(basic_template, { classes: [{ name: "一班" }], total: "0" }) }
      .to raise_error(PowerTom::MissingDataError, /classes\[\]\.avg/)
  end

  it "路径写错(缺 [] 前缀)→ 明确报错" do
    template = build_template(
      [["班级"], ["{{classes[].name}}"], ["{{other[].name}}"]]
    )
    expect { render(template, { classes: [{ name: "x" }], other: [{ name: "y" }] }) }
      .to raise_error(PowerTom::TemplateSyntaxError, /supports only one row loop/)
  end

  it "同一行出现两个不同数组 → 语法错误" do
    template = build_template(
      [["{{classes[].name}}", "{{teachers[].name}}"]]
    )
    expect { render(template, { classes: [], teachers: [] }) }
      .to raise_error(PowerTom::TemplateSyntaxError, /multiple loop arrays/)
  end

  it "正文（非表格）里写 [] → 语法错误" do
    template = build_template([%w[占位 占位]], extra_text: "{{classes[].name}}")
    expect { render(template, { classes: [] }) }
      .to raise_error(PowerTom::TemplateSyntaxError, /only allowed in table row loops/)
  end

  it "页级 #each 与表格行循环叠加 → 明确拒绝" do
    template = basic_template(notes: "{{#each classes}}")
    expect { render(template, { classes: [{ name: "x", avg: 1 }], total: "0" }) }
      .to raise_error(PowerTom::Error, /cannot be combined with table row loops/)
  end

  describe "PowerTom.check" do
    it "数据齐全 → 无 error" do
      result = PowerTom.check(basic_template, data: {
                                classes: [{ name: "一班", avg: 85 }], total: "85"
                              })
      expect(result.errors).to be_empty
    end

    it "数组项缺字段 → error 指出第几项与期望路径" do
      result = PowerTom.check(basic_template,
                              data: { classes: [{ name: "一班" }], total: "0" })
      error = result.errors.first
      aggregate_failures do
        expect(error.label).to eq("classes[].avg")
        expect(error.message).to include("item 1", "expected: classes[0].avg")
      end
    end

    it "空数组 → warning 提示循环行会被移除" do
      result = PowerTom.check(basic_template, data: { classes: [], total: "0" })
      expect(result.warnings.map(&:message).join).to include("table loop row will be removed")
    end

    it "循环数组不是数组 → error" do
      result = PowerTom.check(basic_template, data: { classes: "x", total: "0" })
      expect(result.errors.map(&:message).join).to include("expected an array for the row loop")
    end
  end

  context "保真验收" do
    it "克隆后的表格 deck 经 LibreOffice 转换成功" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      out = render(basic_template, {
                     classes: [{ name: "一班", avg: 85 }, { name: "二班", avg: 79 }],
                     total: "164"
                   })
      pdf_dir = Dir.mktmpdir("table_pdf")
      profile = Dir.mktmpdir("table_lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, out)
      expect(ok).to be(true)
      expect(File.binread(File.join(pdf_dir, "#{File.basename(out, '.pptx')}.pdf"))
                 .scan(%r{/Type\s*/Page[^s]}).size).to eq(1)
    end
  end
end
