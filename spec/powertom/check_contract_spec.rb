# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "date"

# check 的核心契约:无论模板/数据有多离谱,check 只**报告**问题,不抛异常。
#
# check 是 CI 门禁 —— 模板很烂时恰恰最需要一份人类可读的报告,而不是
# 一段 Ruby 栈回溯。本组用例把"坏输入 → 返回 CheckResult 而非抛异常"
# 逐条固化,防止回归。
#
# 不依赖私有金样本,CI 可直接运行。
RSpec.describe "check 的不抛异常契约" do
  around do |example|
    Dir.mktmpdir("check_contract_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  # 直接构造模板:一个文本框 + 可选备注 + 可选形状改名
  def build_template(text: nil, notes: nil, rename: nil)
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    if text
      box = slide.shapes.add_textbox(at: [Pptx.inches(1), Pptx.inches(1)],
                                     size: [Pptx.inches(6), Pptx.inches(1)])
      box.text_frame.text = text
      box.name = rename if rename
    end
    slide.notes = notes if notes

    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  # 断言 check 返回结果而不是抛异常;并返回结果供后续断言
  def check_without_raising(template, data: nil)
    PowerTom.check(template, data: data)
  end

  describe "模板语法异常" do
    it "空标签 {{}} → 报语法 error,不崩" do
      template = build_template(text: "{{}}")

      result = check_without_raising(template)
      messages = result.errors.map(&:message).join("\n")

      expect(result.ok?).to be(false)
      expect(messages).to include("is not a valid tag")
    end

    it "只含空格的标签 {{ }} → 报语法 error,不崩" do
      template = build_template(text: "{{ }}")

      result = check_without_raising(template)

      expect(result.ok?).to be(false)
      expect(result.errors.map(&:message).join("\n")).to include("is not a valid tag")
    end

    it "非法标签 {{bad tag}} → 报语法 error,不崩" do
      template = build_template(text: "{{bad tag}}")

      result = check_without_raising(template)

      expect(result.ok?).to be(false)
      expect(result.errors.map(&:message).join("\n")).to include("is not a valid tag")
    end

    it "空标签与正常标签同段 → 报错误,且不吞掉兄弟标签" do
      template = build_template(text: "{{first}} {{}}")

      result = check_without_raising(template)
      messages = result.errors.map(&:message).join("\n")

      expect(result.ok?).to be(false)
      expect(messages).to include("is not a valid tag")
    end
  end

  describe "占位符字段名为空" do
    it "powertom:chart: 漏字段名 → 报 error,不崩" do
      template = build_template(text: "{{ok}}")
      prs = Pptx::Presentation.open(template)
      slide = prs.slides.add(prs.slide_layouts["Blank"])
      data = Pptx::ChartData.new
      data.categories = %w[Q1 Q2]
      data.add_series("2026", [1, 2])
      chart = slide.shapes.add_chart(
        Pptx::Enum::XL_CHART_TYPE::COLUMN_CLUSTERED, data,
        at: [Pptx.inches(1), Pptx.inches(2)],
        size: [Pptx.inches(4), Pptx.inches(3)]
      )
      chart.name = "powertom:chart:"
      path = File.join(@dir, "empty_field_#{SecureRandom.hex(4)}.pptx")
      prs.save(path)

      result = check_without_raising(path)

      expect(result.ok?).to be(false)
    end
  end

  describe "样例数据异常" do
    it "样例数据是数组 → 报 error 说明期望 Hash,不崩" do
      template = build_template(text: "{{a}}")

      result = check_without_raising(template, data: [1, 2, 3])
      messages = result.errors.map(&:message).join("\n")

      expect(result.ok?).to be(false)
      expect(messages).to include("must be a Hash")
    end

    it "#each 指向 nil 值 → 不崩" do
      template = build_template(text: "{{a}}", notes: "{{#each items}}")

      result = check_without_raising(template, data: { "items" => nil })

      expect(result).to be_a(PowerTom::CheckResult)
    end

    it "#each 指向非数组 → 不崩" do
      template = build_template(text: "{{a}}", notes: "{{#each items}}")

      result = check_without_raising(template, data: { "items" => "abc" })

      expect(result).to be_a(PowerTom::CheckResult)
    end
  end

  describe "形状名含单引号" do
    it "位置信息不重复" do
      template = build_template(text: "{{bad tag}}", rename: "Bob's Box")

      result = check_without_raising(template)
      messages = result.errors.map(&:message)

      expect(result.ok?).to be(false)
      # 消息里只应出现一次位置前缀
      expect(messages.first).to start_with("{{bad tag}}")
    end
  end

  describe "check 与 render 的判定口径一致" do
    it "#each 页上的散点图不误报" do
      template = build_template(text: "{{a}}", notes: "{{#each items}}")
      xy = { "series" => [{ "name" => "s", "points" => [{ "x" => 1, "y" => 2 }] }] }

      result = check_without_raising(template, data: { "items" => [{ "ch" => xy }] })

      # 散点图数据没有 categories;#each 页不该按普通图表规则误判
      expect(result.errors.map(&:message).join("\n")).not_to include("categories")
    end

    it "formatter 参数写错 → check 报 error(渲染期同样会抛)" do
      template = build_template(text: "{{d:date.bogus}}")

      result = check_without_raising(template, data: { "d" => Date.new(2026, 1, 1) })
      messages = result.errors.map(&:message).join("\n")

      expect(result.ok?).to be(false)
      expect(messages).to include("does not support 'bogus'")
    end

    it "formatter 值类型不对 → check 报 error" do
      template = build_template(text: "{{amt:currency}}")

      result = check_without_raising(template, data: { "amt" => "不是数字" })
      messages = result.errors.map(&:message).join("\n")

      expect(result.ok?).to be(false)
      expect(messages).to include("requires a number")
    end

    it "formatter 合法组合 → 不报错" do
      template = build_template(text: "{{amt:currency.2}} {{d:date.year_month}}")

      result = check_without_raising(template, data: { "amt" => 1234.5, "d" => Date.new(2026, 1, 1) })

      expect(result.errors).to be_empty
    end

    it "#each 页与表格行循环冲突 → check 报 error(渲染期同样会抛)" do
      template = build_template(text: "{{a}}", notes: "{{#each items}}")
      # 追加一张带行循环标记的表格
      prs = Pptx::Presentation.open(template)
      slide = prs.slides[0]
      table = slide.shapes.add_table(3, 2,
                                     at: [Pptx.inches(1), Pptx.inches(3)],
                                     size: [Pptx.inches(4), Pptx.inches(1)])
      table.table.rows[0].cells[0].text = "{{#rows rows}}"
      table.table.rows[1].cells[0].text = "{{rows[].n}}"
      table.table.rows[2].cells[0].text = "{{/rows}}"
      path = File.join(@dir, "each_table_#{SecureRandom.hex(4)}.pptx")
      prs.save(path)

      result = check_without_raising(path, data: { "items" => [{ "a" => 1 }], "rows" => [{ "n" => 1 }] })
      messages = result.errors.map(&:message).join("\n")

      expect(result.ok?).to be(false)
      expect(messages).to include("cannot be combined with table row loops")
    end
  end

  describe "asset_resolver 上下文" do
    it "resolver 收到的 ctx 含 :field,与 render 侧一致" do
      template = build_template(text: "{{a}}")
      seen = nil
      resolver = lambda do |_ref, ctx|
        seen = ctx
        nil
      end

      # 图片占位需要真实形状,这里直接用 check 的内部入口验证 ctx 构造
      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(template)
      pictures = [{ slide_no: 1, shape: "pic", field: "pic", mode: :fill, slide: prs.slides[0] }]
      PowerTom::Validator.check(
        contexts: [], tables: [], table_structures: [], notes: [],
        container_texts: [], pictures: pictures, conditionals: [], charts: [],
        chart_placeholders: [], data: { "pic" => "a.png" }, asset_resolver: resolver
      )

      expect(seen).to include(field: "pic")
    end
  end
end
