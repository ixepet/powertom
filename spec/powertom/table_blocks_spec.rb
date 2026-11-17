# frozen_string_literal: true

require "securerandom"
require "tmpdir"

# v0.2.0 区块语法:配对 {{#rows}} ... {{/rows}},列带 {{#cols}} ... {{/cols}} 可写在区块内。
RSpec.describe "表格区块语法(#rows / #cols)" do
  around do |example|
    Dir.mktmpdir("table_blocks_spec") do |dir|
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

  # 两级:年级 → 班级,父区块用一条记录一行
  def nested_rows
    [
      ["年级", "班级", "均分"],
      ["{{#rows grades}}", "", ""],
      ["{{grades[].name}}", "", ""],
      ["{{#rows grades[].classes}}", "", ""],
      ["{{grades[].name}}", "{{grades[].classes[].name}}", "{{grades[].classes[].avg}}"],
      ["{{/rows}}", "", ""],
      ["{{/rows}}", "", ""],
      ["合计", "", "{{total}}"]
    ]
  end

  def nested_data
    {
      grades: [
        { name: "初一", classes: [{ name: "一班", avg: "90" }, { name: "二班", avg: "88" }] },
        { name: "初二", classes: [{ name: "三班", avg: "85" }] }
      ],
      total: "263"
    }
  end

  def multi_band_rows
    [
      ["班级", "{{#cols subjects value: scores,rates}}{{col.label}}", "{{col.rate_label}}{{/cols}}"],
      ["{{#rows classes}}", "", ""],
      ["{{classes[].name}}", "{{cell}}", "{{cell}}"],
      ["{{/rows}}", "", ""]
    ]
  end

  def multi_band_data
    {
      classes: [
        { name: "一班", scores: { chinese: 100, physics: 80 },
          rates: { chinese: 0.83, physics: 0.67 } },
        { name: "二班", scores: { chinese: 95, physics: 85 },
          rates: { chinese: 0.79, physics: 0.71 } }
      ],
      subjects: [
        { key: "chinese", label: "语文", rate_label: "得分率" },
        { key: "physics", label: "物理", rate_label: "得分率" }
      ]
    }
  end

  it "配对行区块:多行记录按数组整体克隆" do
    rows = [
      ["{{#rows classes}}", ""],
      ["{{classes[].name}}", ""],
      ["备注:{{classes[].note}}", ""],
      ["{{/rows}}", ""]
    ]
    data = { classes: [{ name: "一班", note: "稳" }, { name: "二班", note: "进" }] }

    expect(read_table(render(build_template(rows), data))).to eq([
                                                                   ["一班", ""],
                                                                   ["备注:稳", ""],
                                                                   ["二班", ""],
                                                                   ["备注:进", ""]
                                                                 ])
  end

  it "两级区块:父行 + 子行,静态合计行保留" do
    expect(read_table(render(build_template(nested_rows), nested_data))).to eq([
                                                                                 ["年级", "班级", "均分"],
                                                                                 ["初一", "", ""],
                                                                                 ["初一", "一班", "90"],
                                                                                 ["初一", "二班", "88"],
                                                                                 ["初二", "", ""],
                                                                                 ["初二", "三班", "85"],
                                                                                 ["合计", "", "263"]
                                                                               ])
  end

  it "三级区块 + 空子数组" do
    rows = [
      ["{{#rows grades}}", ""],
      ["{{grades[].name}}", ""],
      ["{{#rows grades[].classes}}", ""],
      ["{{grades[].classes[].name}}", "{{grades[].classes[].avg}}"],
      ["{{#rows grades[].classes[].students}}", ""],
      ["{{grades[].classes[].students[].name}}", "{{grades[].classes[].students[].total}}"],
      ["{{/rows}}", ""],
      ["{{/rows}}", ""],
      ["{{/rows}}", ""]
    ]
    data = {
      grades: [
        { name: "初一", classes: [
          { name: "一班", avg: "90", students: [{ name: "甲", total: 400 }, { name: "乙", total: 390 }] },
          { name: "二班", avg: "88", students: [] }
        ] }
      ]
    }

    expect(read_table(render(build_template(rows), data))).to eq([
                                                                   ["初一", ""],
                                                                   ["一班", "90"],
                                                                   ["甲", "400"],
                                                                   ["乙", "390"],
                                                                   ["二班", "88"]
                                                                 ])
  end

  it "同一张表多个顶层区块:按顺序展开,静态行保留" do
    rows = [
      ["{{#rows a}}", ""],
      ["{{a[].x}}", ""],
      ["{{/rows}}", ""],
      ["中间", ""],
      ["{{#rows b}}", ""],
      ["{{b[].y}}", ""],
      ["{{/rows}}", ""]
    ]
    data = { a: [{ x: "a1" }, { x: "a2" }], b: [{ y: "b1" }] }

    expect(read_table(render(build_template(rows), data))).to eq([
                                                                   ["a1", ""],
                                                                   ["a2", ""],
                                                                   ["中间", ""],
                                                                   ["b1", ""]
                                                                 ])
  end

  it "行区块里的 {{row.字段}} 等价于当前记录" do
    rows = [
      ["{{#rows classes}}", ""],
      ["{{row.name}}", "{{row.avg}}"],
      ["{{/rows}}", ""]
    ]
    data = { classes: [{ name: "一班", avg: "90" }] }
    expect(read_table(render(build_template(rows), data))).to eq([%w[一班 90]])
  end

  describe "列带" do
    def band_outside_block_rows
      [
        ["班级", "{{#cols subjects value: scores}}{{col.label}}{{/cols}}"],
        ["{{#rows classes}}", ""],
        ["{{classes[].name}}", "{{cell}}"],
        ["{{/rows}}", ""]
      ]
    end

    def band_inside_block_rows
      [
        ["班级", ""],
        ["{{#rows classes}}", ""],
        ["{{classes[].name}}", "{{#cols subjects value: scores}}{{col.label}}{{/cols}}"],
        ["{{classes[].name}}", "{{cell}}"],
        ["{{/rows}}", ""]
      ]
    end

    def band_data
      {
        classes: [
          { name: "一班", scores: { chinese: 100, physics: 80 } },
          { name: "二班", scores: { chinese: 95, physics: 85 } }
        ],
        subjects: [{ key: "chinese", label: "语文" }, { key: "physics", label: "物理" }]
      }
    end

    it "列带写在表头行:行区块 × 动态列" do
      expect(read_table(render(build_template(band_outside_block_rows), band_data))).to eq([
                                                                                             %w[班级 语文 物理],
                                                                                             %w[一班 100 80],
                                                                                             %w[二班 95 85]
                                                                                           ])
    end

    it "列带直接写在行区块内:声明行随区块克隆" do
      expect(read_table(render(build_template(band_inside_block_rows), band_data))).to eq([
                                                                                            ["班级", "", ""],
                                                                                            ["一班", "语文", "物理"],
                                                                                            ["一班", "100", "80"],
                                                                                            ["二班", "语文", "物理"],
                                                                                            ["二班", "95", "85"]
                                                                                          ])
    end

    it "多列模板:value: 与模板列一一对应" do
      expect(read_table(render(build_template(multi_band_rows), multi_band_data))).to eq([
                                                                                           ["班级", "语文", "得分率", "物理",
                                                                                            "得分率"],
                                                                                           ["一班", "100", "0.83", "80",
                                                                                            "0.67"],
                                                                                           ["二班", "95", "0.79", "85",
                                                                                            "0.71"]
                                                                                         ])
    end

    it "多列模板 + 列带写在区块内" do
      rows = [
        ["{{#rows classes}}", "", ""],
        ["{{classes[].name}}", "{{#cols subjects value: scores,rates}}{{col.label}}",
         "{{col.rate_label}}{{/cols}}"],
        ["{{classes[].name}}", "{{cell}}", "{{cell}}"],
        ["{{/rows}}", "", ""]
      ]
      expect(read_table(render(build_template(rows), multi_band_data))).to eq([
                                                                                ["一班", "语文", "得分率", "物理", "得分率"],
                                                                                ["一班", "100", "0.83", "80", "0.67"],
                                                                                ["二班", "语文", "得分率", "物理", "得分率"],
                                                                                ["二班", "95", "0.79", "85", "0.71"]
                                                                              ])
    end

    it "多列模板的 cell 支持 formatter" do
      rows = multi_band_rows
      rows[2][2] = "{{cell:percent.1}}"
      out = render(build_template(rows), multi_band_data)
      expect(read_table(out)[1]).to eq(["一班", "100", "83.0%", "80", "67.0%"])
    end

    it "空 cols → 只保留固定列" do
      data = band_data.merge(subjects: [])
      expect(read_table(render(build_template(band_outside_block_rows), data))).to eq([
                                                                                        ["班级"],
                                                                                        ["一班"],
                                                                                        ["二班"]
                                                                                      ])
    end
  end

  describe "#if 条件区块" do
    def conditional_rows(path = "classes[].has_data")
      [
        ["班级", "均分"],
        ["{{#rows classes}}", ""],
        ["{{#if #{path}}}", ""],
        ["{{classes[].name}}", "{{classes[].avg}}"],
        ["{{/if}}", ""],
        ["{{/rows}}", ""]
      ]
    end

    def conditional_data
      {
        classes: [
          { name: "一班", avg: "90", has_data: true },
          { name: "二班", avg: "88", has_data: false },
          { name: "三班", avg: "85", has_data: true }
        ]
      }
    end

    it "条件为假时删除区块内所有行,标记行不输出" do
      expect(read_table(render(build_template(conditional_rows), conditional_data))).to eq([
                                                                                             %w[班级 均分],
                                                                                             %w[一班 90],
                                                                                             %w[三班 85]
                                                                                           ])
    end

    it "条件路径不含 [] 时取当前记录字段" do
      out = render(build_template(conditional_rows("has_data")), conditional_data)
      expect(read_table(out).map(&:first)).to eq(%w[班级 一班 三班])
    end

    it "条件路径不含 [] 且记录没有该字段时回退到整页数据" do
      rows = [
        ["班级", "均分"],
        ["{{#rows classes}}", ""],
        ["{{#if show_note}}", ""],
        ["{{classes[].name}}", "{{classes[].avg}}"],
        ["{{/if}}", ""],
        ["{{/rows}}", ""]
      ]
      data = { classes: [{ name: "一班", avg: "90" }], show_note: false }
      expect(read_table(render(build_template(rows), data))).to eq([%w[班级 均分]])

      data[:show_note] = true
      expect(read_table(render(build_template(rows), data))).to eq([
                                                                     %w[班级 均分], %w[一班 90]
                                                                   ])
    end

    it "嵌套区块里的条件按子项求值" do
      rows = [
        ["{{#rows grades}}", ""],
        ["{{grades[].name}}", ""],
        ["{{#rows grades[].classes}}", ""],
        ["{{#if grades[].classes[].has_data}}", ""],
        ["{{grades[].classes[].name}}", "{{grades[].classes[].avg}}"],
        ["{{/if}}", ""],
        ["{{/rows}}", ""],
        ["{{/rows}}", ""]
      ]
      data = {
        grades: [
          { name: "初一", classes: [
            { name: "一班", avg: "90", has_data: true },
            { name: "二班", avg: "88", has_data: false }
          ] }
        ]
      }
      expect(read_table(render(build_template(rows), data))).to eq([
                                                                     ["初一", ""], ["一班", "90"]
                                                                   ])
    end

    it "同一区块内多个条件互不影响" do
      rows = [
        ["{{#rows classes}}", ""],
        ["{{#if classes[].show_header}}", ""],
        ["头部:{{classes[].name}}", ""],
        ["{{/if}}", ""],
        ["{{classes[].name}}", "{{classes[].avg}}"],
        ["{{/rows}}", ""]
      ]
      data = {
        classes: [
          { name: "一班", avg: "90", show_header: true },
          { name: "二班", avg: "88", show_header: false }
        ]
      }
      expect(read_table(render(build_template(rows), data))).to eq([
                                                                     ["头部:一班", ""],
                                                                     ["一班", "90"],
                                                                     ["二班", "88"]
                                                                   ])
    end

    describe "结构校验" do
      it "条件写在行区块外 → 报错" do
        rows = [["{{#if show}}", ""], ["内容", ""], ["{{/if}}", ""]]
        expect { render(build_template(rows), { show: true }) }
          .to raise_error(PowerTom::TemplateSyntaxError, /conditional blocks must be written inside a row block/)
      end

      it "缺少 {{/if}} → 报错" do
        rows = [
          ["{{#rows classes}}", ""],
          ["{{#if classes[].has_data}}", ""],
          ["{{classes[].name}}", ""]
        ]
        expect { render(build_template(rows), conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, %r{missing \{\{/if\}\}})
      end

      it "多余的 {{/if}} → 报错" do
        rows = [["{{#rows classes}}", ""], ["{{/if}}", ""], ["{{/rows}}", ""]]
        expect { render(build_template(rows), conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, /has no matching \{\{#if\}\}/)
      end

      it "条件区块嵌套 → 报错" do
        rows = [
          ["{{#rows classes}}", ""],
          ["{{#if classes[].a}}", ""],
          ["{{#if classes[].b}}", ""],
          ["{{classes[].name}}", ""],
          ["{{/if}}", ""],
          ["{{/if}}", ""],
          ["{{/rows}}", ""]
        ]
        expect { render(build_template(rows), conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, /conditional blocks cannot nest/)
      end

      it "条件区块内没有内容 → 报错" do
        rows = [
          ["{{#rows classes}}", ""],
          ["{{#if classes[].has_data}}", ""],
          ["{{/if}}", ""],
          ["{{/rows}}", ""]
        ]
        expect { render(build_template(rows), conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, /needs at least one content row/)
      end

      it "条件区块内放行区块 → 报错" do
        rows = [
          ["{{#rows classes}}", ""],
          ["{{#if classes[].has_data}}", ""],
          ["{{#rows classes[].items}}", ""],
          ["{{classes[].items[].name}}", ""],
          ["{{/rows}}", ""],
          ["{{/if}}", ""],
          ["{{/rows}}", ""]
        ]
        expect { render(build_template(rows), conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, /conditional block cannot contain a row block/)
      end

      it "条件区块内放列带 → 报错" do
        rows = [
          ["班级", "科目"],
          ["{{#rows classes}}", ""],
          ["{{#if classes[].has_data}}", ""],
          ["{{classes[].name}}", "{{#cols subjects}}{{col.label}}{{/cols}}"],
          ["{{/if}}", ""],
          ["{{/rows}}", ""]
        ]
        expect { render(build_template(rows), conditional_data.merge(subjects: [])) }
          .to raise_error(PowerTom::TemplateSyntaxError, /column band cannot be written inside a conditional block/)
      end

      it "条件路径不在作用域内 → 报错" do
        rows = conditional_rows("other[].flag")
        expect { render(build_template(rows), conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, /is not inside the current row block scope/)
      end

      it "条件字段缺失 → 渲染报错" do
        data = conditional_data
        data[:classes][0].delete(:has_data)
        expect { render(build_template(conditional_rows), data) }
          .to raise_error(PowerTom::MissingDataError, /has_data/)
      end
    end

    describe "PowerTom.check" do
      it "数据齐全 → 无 error" do
        result = PowerTom.check(build_template(conditional_rows), data: conditional_data)
        expect(result.errors).to be_empty
      end

      it "条件字段缺失 → error 指向条件路径" do
        data = conditional_data
        data[:classes][1].delete(:has_data)
        result = PowerTom.check(build_template(conditional_rows), data: data)

        error = result.errors.find { |e| e.label == "classes[].has_data" }
        expect(error.message).to include("block classes item 2", "has_data")
      end

      it "条件为假的内容行不再对账" do
        rows = [
          ["班级", "均分"],
          ["{{#rows classes}}", ""],
          ["{{#if classes[].never}}", ""],
          ["{{classes[].name}}", "{{classes[].missing_field}}"],
          ["{{/if}}", ""],
          ["{{/rows}}", ""]
        ]
        data = { classes: [{ name: "一班", never: false }, { name: "二班", never: false }] }
        result = PowerTom.check(build_template(rows), data: data)
        expect(result.errors.map(&:label)).not_to include("classes[].missing_field")
      end
    end
  end

  describe "#if 列级条件" do
    def column_conditional_data
      {
        classes: [
          { name: "一班", scores: { chinese: 100, physics: 80 } },
          { name: "二班", scores: { chinese: 95, physics: 85 } }
        ],
        subjects: [
          { key: "chinese", label: "语文", show: true },
          { key: "physics", label: "物理", show: false }
        ]
      }
    end

    def column_conditional_rows
      [
        ["班级", "{{#cols subjects value: scores}}{{#if subjects[].show}}{{col.label}}{{/if}}{{/cols}}"],
        ["{{#rows classes}}", ""],
        ["{{classes[].name}}", "{{cell}}"],
        ["{{/rows}}", ""]
      ]
    end

    it "按列项求值:为假的列整列删除" do
      expect(read_table(render(build_template(column_conditional_rows), column_conditional_data))).to eq([
                                                                                                           %w[班级 语文],
                                                                                                           %w[一班 100],
                                                                                                           %w[二班 95]
                                                                                                         ])
    end

    it "条件不含 [] 时回退整页数据" do
      rows = [
        ["班级", "{{#cols subjects value: scores}}{{#if show_extra}}{{col.label}}{{/if}}{{/cols}}"],
        ["{{#rows classes}}", ""],
        ["{{classes[].name}}", "{{cell}}"],
        ["{{/rows}}", ""]
      ]
      data = column_conditional_data.merge(show_extra: false)
      expect(read_table(render(build_template(rows), data))).to eq([
                                                                     ["班级"], ["一班"], ["二班"]
                                                                   ])

      data[:show_extra] = true
      expect(read_table(render(build_template(rows), data))).to eq([
                                                                     %w[班级 语文 物理],
                                                                     %w[一班 100 80],
                                                                     %w[二班 95 85]
                                                                   ])
    end

    it "多列模板:条件为假时整组模板列删除" do
      rows = [
        ["班级", "{{#cols subjects value: scores,rates}}{{#if subjects[].show}}{{col.label}}",
         "{{col.rate_label}}{{/if}}{{/cols}}"],
        ["{{#rows classes}}", "", ""],
        ["{{classes[].name}}", "{{cell}}", "{{cell}}"],
        ["{{/rows}}", "", ""]
      ]
      data = {
        classes: [{ name: "一班", scores: { chinese: 100, physics: 80 },
                    rates: { chinese: 0.83, physics: 0.67 } }],
        subjects: [
          { key: "chinese", label: "语文", rate_label: "得分率", show: true },
          { key: "physics", label: "物理", rate_label: "得分率", show: false }
        ]
      }
      expect(read_table(render(build_template(rows), data))).to eq([
                                                                     ["班级", "语文", "得分率"],
                                                                     ["一班", "100", "0.83"]
                                                                   ])
    end

    describe "结构校验" do
      it "缺少 {{/if}} → 报错" do
        rows = [
          ["班级", "{{#cols subjects}}{{#if subjects[].show}}{{col.label}}{{/cols}}"],
          ["{{#rows classes}}", ""],
          ["{{classes[].name}}", "{{cell}}"],
          ["{{/rows}}", ""]
        ]
        expect { render(build_template(rows), column_conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, %r{missing \{\{/if\}\}})
      end

      it "列条件嵌套 → 报错" do
        rows = [
          ["班级", "{{#cols subjects}}{{#if a}}{{#if b}}{{col.label}}{{/if}}{{/if}}{{/cols}}"],
          ["{{#rows classes}}", ""],
          ["{{classes[].name}}", "{{cell}}"],
          ["{{/rows}}", ""]
        ]
        expect { render(build_template(rows), column_conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, /column conditions cannot nest/)
      end

      it "引用其他数组 → 报错" do
        rows = [
          ["班级", "{{#cols subjects}}{{#if other[].show}}{{col.label}}{{/if}}{{/cols}}"],
          ["{{#rows classes}}", ""],
          ["{{classes[].name}}", "{{cell}}"],
          ["{{/rows}}", ""]
        ]
        expect { render(build_template(rows), column_conditional_data) }
          .to raise_error(PowerTom::TemplateSyntaxError, /can only reference the current column array/)
      end

      it "条件字段缺失 → 渲染报错" do
        data = column_conditional_data
        data[:subjects][1].delete(:show)
        expect { render(build_template(column_conditional_rows), data) }
          .to raise_error(PowerTom::MissingDataError, /show/)
      end
    end

    describe "PowerTom.check" do
      it "数据齐全 → 无 error" do
        result = PowerTom.check(build_template(column_conditional_rows), data: column_conditional_data)
        expect(result.errors).to be_empty
      end

      it "列条件字段缺失 → error 指向第几个列项" do
        data = column_conditional_data
        data[:subjects][1].delete(:show)
        result = PowerTom.check(build_template(column_conditional_rows), data: data)
        error = result.errors.find { |e| e.label == "subjects[].show" }
        expect(error.message).to include("column condition item 2", "show")
      end
    end
  end

  describe "结构校验" do
    it "缺少 {{/rows}} → 报错" do
      rows = [
        ["{{#rows classes}}", ""],
        ["{{classes[].name}}", "{{#cols subjects}}{{col.label}}{{/cols}}"]
      ]
      expect { render(build_template(rows), { classes: [], subjects: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, %r{missing \{\{/rows\}\}})
    end

    it "多余的 {{/rows}} → 报错" do
      rows = [["{{/rows}}", ""]]
      expect { render(build_template(rows), {}) }
        .to raise_error(PowerTom::TemplateSyntaxError, /has no matching \{\{#rows\}\}/)
    end

    it "区块内没有内容行 → 报错" do
      rows = [["{{#rows classes}}", ""], ["{{/rows}}", ""]]
      expect { render(build_template(rows), { classes: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /needs at least one content row/)
    end

    it "超过 3 级 → 报错" do
      rows = [
        ["{{#rows a}}", ""], ["{{a[].name}}", ""],
        ["{{#rows a[].b}}", ""], ["{{a[].b[].name}}", ""],
        ["{{#rows a[].b[].c}}", ""], ["{{a[].b[].c[].name}}", ""],
        ["{{#rows a[].b[].c[].d}}", ""], ["{{a[].b[].c[].d[].name}}", ""],
        ["{{/rows}}", ""], ["{{/rows}}", ""], ["{{/rows}}", ""], ["{{/rows}}", ""]
      ]
      expect { render(build_template(rows), { a: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /nesting exceeds 3 levels/)
    end

    it "子区块路径不挂在父区块下 → 报错" do
      rows = [
        ["{{#rows grades}}", ""],
        ["{{#rows other.classes}}", ""],
        ["{{grades[].name}}", ""],
        ["{{/rows}}", ""],
        ["{{/rows}}", ""]
      ]
      expect { render(build_template(rows), nested_data) }
        .to raise_error(PowerTom::TemplateSyntaxError, /must start with grades\[\]/)
    end

    it "标记不独占整行 → 报错" do
      rows = [["{{#rows classes}}", "备注"], ["{{classes[].name}}", ""], ["{{/rows}}", ""]]
      expect { render(build_template(rows), { classes: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /must occupy the whole row/)
    end

    it "列带标记不在同一行 → 报错" do
      rows = [
        ["班级", "{{#cols subjects}}{{col.label}}"],
        ["{{#rows classes}}", ""],
        ["{{classes[].name}}", "{{/cols}}"],
        ["{{/rows}}", ""]
      ]
      expect { render(build_template(rows), { classes: [], subjects: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /must be written in the same row/)
    end

    it "列带写在首列 → 报错" do
      rows = [["{{#cols subjects}}{{col.label}}{{/cols}}", ""]]
      expect { render(build_template(rows), { subjects: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /must start in a data column/)
    end

    it "value: 数量与列带宽度不匹配 → 报错" do
      rows = [
        ["班级", "{{#cols subjects value: scores,rates,extra}}{{col.label}}",
         "{{col.rate_label}}{{/cols}}"],
        ["{{#rows classes}}", "", ""],
        ["{{classes[].name}}", "{{cell}}", "{{cell}}"],
        ["{{/rows}}", "", ""]
      ]
      expect { render(build_template(rows), { classes: [], subjects: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError,
                        /value: must contain 1 field or match the column band width \(2\)/)
    end

    it "{{cell}} 写在列带外 → 报错" do
      rows = [["{{#rows classes}}", "", ""],
              ["{{classes[].name}}", "{{classes[].avg}}", "{{cell}}"],
              ["{{/rows}}", "", ""]]
      expect { render(build_template(rows), { classes: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /cell.*only be written in a column band cell inside a row block/)
    end

    it "{{col.字段}} 写在列带外 → 报错" do
      rows = [["{{#rows classes}}", ""],
              ["{{classes[].name}}", "{{col.label}}"],
              ["{{/rows}}", ""]]
      expect { render(build_template(rows), { classes: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /col\.label.*can only be written in a column band cell/)
    end

    it "{{row.字段}} 写在区块外 → 报错" do
      rows = [["{{row.name}}", ""]]
      expect { render(build_template(rows), {}) }
        .to raise_error(PowerTom::TemplateSyntaxError, /row\.name.*can only be used in tables with/)
    end

    it "[] 标签写在区块外 → 报错" do
      rows = [
        ["{{#rows groups}}", ""],
        ["{{groups[].name}}", "{{classes[].name}}"],
        ["{{/rows}}", ""]
      ]
      expect { render(build_template(rows), { groups: [], classes: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /is not inside the current row block scope/)
    end

    it "区块内合并单元格 → 报错" do
      rows = [["{{#rows classes}}", ""], ["{{classes[].name}}", ""], ["{{/rows}}", ""]]
      expect { render(build_template(rows, merge: [[1, 0, 1]]), { classes: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /row blocks do not support merged cells/)
    end

    it "区块模式混用 #grid → 报错" do
      rows = [
        ["{{#grid rows: distribution cols: bands}}", ""],
        ["{{row.name}}", "{{cell}}"],
        ["{{/rows}}", ""]
      ]
      expect { render(build_template(rows), { distribution: [], bands: [] }) }
        .to raise_error(PowerTom::TemplateSyntaxError, /block mode does not support/)
    end
  end

  describe "PowerTom.check" do
    it "数据齐全 → 无 error / 无未使用字段" do
      result = PowerTom.check(build_template(nested_rows), data: nested_data)
      aggregate_failures do
        expect(result.errors).to be_empty
        expect(result.warnings).to be_empty
      end
    end

    it "父级缺字段 → error 指向区块第几项" do
      data = nested_data
      data[:grades][1][:classes][0].delete(:avg)
      result = PowerTom.check(build_template(nested_rows), data: data)

      error = result.errors.find { |e| e.label == "grades[].classes[].avg" }
      expect(error.message).to include("block grades[].classes item 1", "avg")
    end

    it "缺子数组 → error 指出父项缺少字段" do
      data = { grades: [{ name: "初一" }] }
      result = PowerTom.check(build_template(nested_rows), data: data)
      error = result.errors.find { |e| e.label == "grades[].classes" }
      expect(error.message).to include("parent item is missing 'classes'")
    end

    it "列带交叉值缺失 → error 指向第几列" do
      rows = [
        ["班级", "{{#cols subjects value: scores}}{{col.label}}{{/cols}}"],
        ["{{#rows classes}}", ""],
        ["{{classes[].name}}", "{{cell}}"],
        ["{{/rows}}", ""]
      ]
      data = {
        classes: [{ name: "一班", scores: { chinese: 100 } }],
        subjects: [{ key: "chinese", label: "语文" }, { key: "physics", label: "物理" }]
      }
      result = PowerTom.check(build_template(rows), data: data)
      error = result.errors.find { |e| e.label == "cell" }
      expect(error.message).to include("column 2", "physics")
    end

    it "多列模板缺第二个取值字段 → error 指向列项与模板列" do
      data = multi_band_data
      data[:classes][0][:rates].delete(:physics)
      result = PowerTom.check(build_template(multi_band_rows), data: data)

      error = result.errors.find { |e| e.label == "cell" }
      expect(error.message).to include("column item 2, template column 2", "physics")
    end

    it "空区块数组 → warning" do
      result = PowerTom.check(build_template(nested_rows), data: nested_data.merge(grades: []))
      expect(result.warnings.map(&:message).join).to include("array 'grades' is empty")
    end
  end

  context "保真验收" do
    it "区块展开后的 deck 经 LibreOffice 转换成功" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      out = render(build_template(nested_rows), nested_data)
      pdf_dir = Dir.mktmpdir("blocks_pdf")
      profile = Dir.mktmpdir("blocks_lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, out)
      expect(ok).to be(true)
      expect(File.binread(File.join(pdf_dir, "#{File.basename(out, '.pptx')}.pdf"))
                 .scan(%r{/Type\s*/Page[^s]}).size).to eq(1)
    end
  end
end
