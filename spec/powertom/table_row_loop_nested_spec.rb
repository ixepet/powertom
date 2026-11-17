# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# L1 表格嵌套行:{{#rows 父路径}} 标记父行,{{#rows 父[].子}} 标记子行。
RSpec.describe "表格嵌套行(#rows)" do
  around do |example|
    Dir.mktmpdir("table_nested_row_spec") do |dir|
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

  # 父级 2 组(各 2/1 个子项)+ 表头 + 合计
  def nested_rows
    [
      %w[班级 学生 总分],
      ["{{#rows groups}}", "", ""],
      ["{{groups[].name}}", "{{groups[].avg}}", ""],
      ["{{#rows groups[].items}}", "", ""],
      ["{{groups[].name}}", "{{groups[].items[].name}}", "{{groups[].items[].total}}"],
      ["合计", "{{student_count}}", ""]
    ]
  end

  def groups
    [
      { name: "初二(1)班", avg: "81.5",
        items: [{ name: "学生A", total: 398 }, { name: "学生B", total: 405 }] },
      { name: "初二(2)班", avg: "85.4",
        items: [{ name: "学生C", total: 412 }] }
    ]
  end

  def full_data
    { groups: groups, student_count: "3" }
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

  it "父行 + 子行按数组展开,标记行不输出" do
    out = render(build_template(nested_rows), full_data)

    expect(read_table(out)).to eq([
      %w[班级 学生 总分],
      ["初二(1)班", "81.5", ""],
      ["初二(1)班", "学生A", "398"],
      ["初二(1)班", "学生B", "405"],
      ["初二(2)班", "85.4", ""],
      ["初二(2)班", "学生C", "412"],
      ["合计", "3", ""]
    ])
  end

  it "子数组为空 → 只保留父内容行" do
    data = { groups: [{ name: "一班", avg: "90", items: [] }], student_count: "0" }
    out = render(build_template(nested_rows), data)

    expect(read_table(out)).to eq([
      %w[班级 学生 总分],
      ["一班", "90", ""],
      ["合计", "0", ""]
    ])
  end

  it "父数组为空 → 父子行全部删除,表头与合计保留" do
    out = render(build_template(nested_rows), { groups: [], student_count: "0" })
    expect(read_table(out)).to eq([%w[班级 学生 总分], ["合计", "0", ""]])
  end

  it "子行里的 formatter 生效" do
    rows = nested_rows
    rows[4][2] = "{{groups[].items[].total:number}}"
    out = render(build_template(rows), full_data)

    expect(read_table(out)[2]).to eq(["初二(1)班", "学生A", "398"])
    expect(read_table(out)[3][2]).to eq("405")
  end

  describe "结构校验" do
    it "标记不在首列 → 语法错误" do
      rows = [["班级", "{{#rows groups}}"],
              ["{{groups[].name}}", ""]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /行标记必须独占首列单元格/)
    end

    it "标记与正文同格 → 语法错误" do
      rows = [["标题 {{#rows groups}}", ""],
              ["{{groups[].name}}", ""]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /行标记必须独占首列单元格/)
    end

    it "标记行其他单元格有内容 → 语法错误" do
      rows = [["{{#rows groups}}", "备注"],
              ["{{groups[].name}}", ""]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /行标记必须独占一行/)
    end

    it "标记行后没有内容行 → 语法错误" do
      rows = [%w[班级 学生], ["{{#rows groups}}", ""]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /标记后缺少内容行/)
    end

    it "只有父标记没有子标记 → 提示改用单级 []" do
      rows = [%w[班级 学生],
              ["{{#rows groups}}", ""],
              ["{{groups[].name}}", "{{groups[].avg}}"]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /缺少子行标记.*\[\] 行循环|单级循环/)
    end

    it "子标记不挂在父级路径下 → 语法错误" do
      rows = [%w[班级 学生],
              ["{{#rows groups}}", ""],
              ["{{groups[].name}}", ""],
              ["{{#rows other.items}}", ""],
              ["{{groups[].items[].name}}", ""]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /必须以 groups\[\] 开头/)
    end

    it "三级标记 → 堆叠层级超过 2 级" do
      rows = [%w[a b],
              ["{{#rows groups}}", ""],
              ["{{groups[].name}}", ""],
              ["{{#rows groups[].items}}", ""],
              ["{{groups[].items[].name}}", ""],
              ["{{#rows groups[].items[].scores}}", ""],
              ["{{groups[].items[].name}}", ""]]
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /堆叠层级超过 2 级/)
    end

    it "同一张表混用 #rows 与 [] → 语法错误" do
      rows = nested_rows + [["{{classes[].name}}", ""]]
      expect { render(build_template(rows), full_data.merge(classes: [])) }
        .to raise_error(PowerTom::TemplateSyntaxError, /不能混用/)
    end

    it "父行内容引用子级数组 → 与循环数组不匹配" do
      rows = nested_rows
      rows[2][2] = "{{groups[].items[].total}}"
      expect { render(build_template(rows), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /与循环数组不匹配/)
    end

    it "合并单元格参与循环 → 拒绝并提示先拆分" do
      expect { render(build_template(nested_rows, merge: [[4, 0, 1]]), full_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /合并单元格.*先拆分/)
    end

    it "子数组缺失 → 报错定位到父级第几项" do
      data = { groups: [{ name: "一班", avg: "90" }], student_count: "0" }
      expect { render(build_template(nested_rows), data) }
        .to raise_error(PowerTom::MissingDataError, /父级第 1 项.*缺少子数组 'items'/)
    end
  end

  describe "PowerTom.check" do
    it "数据齐全 → 无 error" do
      result = PowerTom.check(build_template(nested_rows), data: full_data)
      expect(result.errors).to be_empty
    end

    it "子级缺字段 → error 指到父级/子级第几项与期望路径" do
      data = full_data
      data[:groups][1][:items][0].delete(:name)
      result = PowerTom.check(build_template(nested_rows), data: data)

      error = result.errors.first
      aggregate_failures do
        expect(error.label).to eq("groups[].items[].name")
        expect(error.message).to include("第 2 项", "第 1 项", "期望:groups[1].items[0].name")
      end
    end

    it "子数组为空 → warning 提示子行会被移除" do
      data = { groups: [{ name: "一班", avg: "90", items: [] }], student_count: "0" }
      result = PowerTom.check(build_template(nested_rows), data: data)
      expect(result.warnings.map(&:message).join).to include("数组 'items' 为空")
    end

    it "标记位置错误 → error 带页码与形状(name 或单元格定位)" do
      rows = [["班级", "{{#rows groups}}"], ["{{groups[].name}}", ""]]
      result = PowerTom.check(build_template(rows), data: full_data)
      error = result.errors.first
      aggregate_failures do
        expect(error.slide_no).to eq(1)
        expect(error.message).to include("行标记必须独占首列单元格")
      end
    end
  end

  context "保真验收" do
    it "嵌套展开后的表格 deck 经 LibreOffice 转换成功" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      out = render(build_template(nested_rows), full_data)
      pdf_dir = Dir.mktmpdir("nested_table_pdf")
      profile = Dir.mktmpdir("nested_table_lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, out)
      expect(ok).to be(true)
      expect(File.binread(File.join(pdf_dir, File.basename(out, ".pptx") + ".pdf"))
                 .scan(/\/Type\s*\/Page[^s]/).size).to eq(1)
    end
  end
end
