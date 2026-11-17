# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# L2 动态列:{{#grid rows: .. cols: .. [value: ..]}} 声明表头首格,
# 首列固定为行标题,第二列为列模板,按 cols 克隆列。
RSpec.describe "表格动态列(#grid)" do
  around do |example|
    Dir.mktmpdir("table_grid_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template(rows, merge: nil)
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
    rows.each_with_index do |cells, r|
      cells.each_with_index { |text, c| table.cell(r, c).text = text }
    end
    Array(merge).each { |r, c1, c2| table.cell(r, c1).merge(table.cell(r, c2)) }

    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  # 首列行标题 + 第二列列模板;标记与"班级"同格,验证只移除标记
  def grid_rows(marker: "班级 {{#grid rows: distribution cols: bands value: counts}}")
    [
      [marker, "{{col.label}}"],
      ["{{row.name}}", "{{cell}}"]
    ]
  end

  def bands
    [
      { key: "excellent", label: "≥85 优秀" },
      { key: "good", label: "70–84" },
      { key: "pass", label: "60–69" }
    ]
  end

  def distribution
    [
      { name: "初二(1)班", counts: { excellent: 17, good: 25, pass: 15, fail: 4 } },
      { name: "初二(2)班", counts: { excellent: 22, good: 20, pass: 12, fail: 6 } }
    ]
  end

  def full_data
    { distribution: distribution, bands: bands }
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

  it "按 cols 克隆列、按 rows 克隆行,标记只移除自身" do
    out = render(build_template(grid_rows), full_data)

    expect(read_table(out)).to eq([
      ["班级", "≥85 优秀", "70–84", "60–69"],
      ["初二(1)班", "17", "25", "15"],
      ["初二(2)班", "22", "20", "12"]
    ])
  end

  it "{{cell}} 支持 formatter" do
    rows = grid_rows
    rows[1][1] = "{{cell:number}}"
    data = {
      distribution: [{ name: "一班", counts: { a: 1234, b: 56 } }],
      bands: [{ key: "a", label: "A" }, { key: "b", label: "B" }]
    }
    out = render(build_template(rows), data)

    expect(read_table(out)[1]).to eq(["一班", "1,234", "56"])
  end

  it "省略 value: 时直接从行数据按列 key 取值" do
    rows = [
      ["{{#grid rows: distribution cols: bands}}", "{{col.label}}"],
      ["{{row.name}}", "{{cell}}"]
    ]
    data = {
      distribution: [{ name: "一班", excellent: 17, good: 25 }],
      bands: [{ key: "excellent", label: "优秀" }, { key: "good", label: "良好" }]
    }
    expect(read_table(render(build_template(rows), data))).to eq([
      ["", "优秀", "良好"],
      ["一班", "17", "25"]
    ])
  end

  it "标量列项:{{col}} 直接渲染列名" do
    rows = [
      ["{{#grid rows: distribution cols: bands}}", "{{col}}"],
      ["{{row.name}}", "{{cell}}"]
    ]
    data = {
      distribution: [{ name: "一班", 优秀: 17, 良好: 25 }],
      bands: %w[优秀 良好]
    }
    expect(read_table(render(build_template(rows), data))).to eq([
      ["", "优秀", "良好"],
      ["一班", "17", "25"]
    ])
  end

  it "空 rows → 只保留表头" do
    data = full_data.merge(distribution: [])
    expect(read_table(render(build_template(grid_rows), data))).to eq([
      ["班级", "≥85 优秀", "70–84", "60–69"]
    ])
  end

  it "空 cols → 只保留首列(行标题)" do
    data = full_data.merge(bands: [])
    expect(read_table(render(build_template(grid_rows), data))).to eq([
      ["班级"],
      ["初二(1)班"],
      ["初二(2)班"]
    ])
  end

  describe "结构校验" do
    it "标记不在首列 → 语法错误" do
      rows = [["班级", "{{#grid rows: distribution cols: bands}}"],
              ["{{row.name}}", "{{cell}}"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /grid 标记必须放在表头行首列/)
    end

    it "表格不是两列 → 语法错误" do
      rows = [["{{#grid rows: distribution cols: bands}}", "{{col.label}}", "备注"],
              ["{{row.name}}", "{{cell}}", "x"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /只支持两列模板/)
    end

    it "缺少 cols: 参数 → 语法错误" do
      rows = [["{{#grid rows: distribution}}", "{{col.label}}"],
              ["{{row.name}}", "{{cell}}"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /缺少 cols: 参数/)
    end

    it "参数重复 → 语法错误" do
      rows = [["{{#grid rows: distribution rows: bands cols: bands}}", "{{col.label}}"],
              ["{{row.name}}", "{{cell}}"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /参数重复/)
    end

    it "表头用了非 col 作用域标签 → 语法错误" do
      rows = [["{{#grid rows: distribution cols: bands}}", "{{title}}"],
              ["{{row.name}}", "{{cell}}"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /不属于 grid 表头作用域/)
    end

    it "内容行用了未知作用域标签 → 语法错误" do
      rows = [["{{#grid rows: distribution cols: bands}}", "{{col.label}}"],
              ["{{row.name}}", "{{other}}"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /不属于 grid 内容行作用域/)
    end

    it "与 #rows 混用 → 语法错误" do
      rows = [["{{#grid rows: distribution cols: bands}}", "{{col.label}}"],
              ["{{#rows groups}}", ""],
              ["{{groups[].name}}", ""]]
      expect { render(build_template(rows), full_data.merge(groups: [])) }
        .to raise_error(PowerTom::TemplateSyntaxError, /不能混用 {{#grid}} 与 {{#rows}}/)
    end

    it "与 [] 行循环混用 → 语法错误" do
      rows = grid_rows + [["{{classes[].name}}", ""]]
      expect { render(build_template(rows), full_data.merge(classes: [])) }
        .to raise_error(PowerTom::TemplateSyntaxError, /不能混用 {{#grid}} 与/)
    end

    it "合并单元格 → 拒绝并提示先拆分" do
      expect { render(build_template(grid_rows, merge: [[0, 0, 1]]), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /grid 循环不支持合并单元格.*先拆分/)
    end

    it "标记后没有内容行 → 语法错误" do
      rows = [["{{#grid rows: distribution cols: bands}}", "{{col.label}}"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /grid 标记后缺少内容行/)
    end

    it "列数据缺 key → 报错定位到第几列" do
      data = { distribution: distribution, bands: [{ label: "优秀" }] }
      expect { render(build_template(grid_rows), data) }
        .to raise_error(PowerTom::MissingDataError, /列数据第 1 项缺少 'key' 字段/)
    end

    it "value: 指向的字段不是 Hash → 报错" do
      data = { distribution: [{ name: "一班", counts: 5 }], bands: bands }
      expect { render(build_template(grid_rows), data) }
        .to raise_error(PowerTom::MissingDataError, /行数据的 'counts' 需要 Hash/)
    end

    it "行数据缺少列 key → 报错" do
      data = {
        distribution: [{ name: "一班", counts: { excellent: 17 } }],
        bands: [{ key: "good", label: "良好" }]
      }
      expect { render(build_template(grid_rows), data) }
        .to raise_error(PowerTom::MissingDataError, /数据里没有字段 'good'/)
    end
  end

  describe "PowerTom.check" do
    it "数据齐全 → 无 error,行列数组都算已使用" do
      result = PowerTom.check(build_template(grid_rows), data: full_data)
      aggregate_failures do
        expect(result.errors).to be_empty
        expect(result.warnings).to be_empty
      end
    end

    it "行缺字段 → error 指向第几行与期望路径" do
      data = full_data
      data[:distribution][1].delete(:name)
      result = PowerTom.check(build_template(grid_rows), data: data)

      error = result.errors.find { |e| e.label == "row.name" }
      expect(error.message).to include("第 2 项", "期望:distribution[1].name")
    end

    it "列缺字段 → error 指向第几列与期望路径" do
      data = full_data
      data[:bands][1].delete(:label)
      result = PowerTom.check(build_template(grid_rows), data: data)

      error = result.errors.find { |e| e.label == "col.label" }
      expect(error.message).to include("第 2 项", "期望:bands[1].label")
    end

    it "{{cell}} 缺交叉值 → error 指向行列坐标" do
      data = full_data
      data[:distribution][0][:counts].delete(:good)
      result = PowerTom.check(build_template(grid_rows), data: data)

      error = result.errors.find { |e| e.label == "cell" }
      expect(error.message).to include("第 1 行 × 第 2 列", "good")
    end

    it "空 cols → warning 提示列会被移除" do
      result = PowerTom.check(build_template(grid_rows), data: full_data.merge(bands: []))
      expect(result.warnings.map(&:message).join).to include("数组 'bands' 为空")
    end

    it "结构错误(三列)→ error 带页码与形状" do
      rows = [["{{#grid rows: distribution cols: bands}}", "{{col.label}}", "备注"],
              ["{{row.name}}", "{{cell}}", "x"]]
      result = PowerTom.check(build_template(rows), data: full_data)
      error = result.errors.first
      aggregate_failures do
        expect(error.slide_no).to eq(1)
        expect(error.message).to include("只支持两列模板")
      end
    end
  end

  context "保真验收" do
    it "动态列展开后的 deck 经 LibreOffice 转换成功" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      out = render(build_template(grid_rows), full_data)
      pdf_dir = Dir.mktmpdir("grid_table_pdf")
      profile = Dir.mktmpdir("grid_table_lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, out)
      expect(ok).to be(true)
      expect(File.binread(File.join(pdf_dir, File.basename(out, ".pptx") + ".pdf"))
                 .scan(/\/Type\s*\/Page[^s]/).size).to eq(1)
    end
  end
end
