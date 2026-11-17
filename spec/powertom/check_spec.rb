# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "fileutils"
require "tomlrb"

# M3:Validator 对账 + warnings 体系(§7)。check 报告问题而不抛异常。
RSpec.describe PowerTom, ".check" do
  fixture_dir = File.expand_path("../fixtures/hai_mate", __dir__)
  template_path = File.join(fixture_dir, "template.pptx")

  # P2/P5/P9 注入正文标签;P9 备注写 #each;P17 备注写 #if
  LABELS = [
    { slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{page_title}}"] },
    { slide_no: 2, shape: "圆角矩形 4", old_text: "    工作复杂", runs: ["    {{wor", "kload}}"] },
    { slide_no: 5, shape: "文本框 18", old_text: "亮点一｜任务驱动的高效工作",
      runs: ["{{highlight_title}}", "", ""] },
    { slide_no: 9, shape: "文本框 30", old_text: "每周日晚自动生成下周晨读材料包",
      runs: ["{{headline}}"] }
  ].freeze

  COMPLETE_DATA = {
    page_title: "学生工作台",
    workload: "教学负担",
    highlight_title: "亮点一｜效率翻倍",
    scenarios: [
      { headline: "晨读材料包" },
      { headline: "家长会材料" }
    ],
    show_compare: true
  }.freeze

  @tmp_root = nil
  before(:all) do
    skip "缺少 fixture — 放好原始 pptx 后运行 rake fixtures:generate" unless File.file?(template_path)
    @tmp_root = Dir.mktmpdir("powertom_check_spec")
  end
  after(:all) do
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  define_method(:inject) do |labels, notes = {}, renames = []|
    path = File.join(@tmp_root, "labeled_#{SecureRandom.hex(6)}.pptx")
    PowerTomDev::LabelInjector.inject(template_path, path, labels,
                                      notes_assignments: notes, renames: renames)
  end

  def labeled_with_directives
    inject(LABELS, 9 => "{{#each scenarios}}", 17 => "{{#if show_compare}}")
  end

  def check(template, data: nil)
    PowerTom.check(template, data: data)
  end

  it "数据齐全:无 error,ok?,报告含模板名与汇总行" do
    result = check(labeled_with_directives, data: COMPLETE_DATA)
    aggregate_failures do
      expect(result.ok?).to be(true)
      expect(result.exit_code).to eq(0)
      expect(result.report).to include("模板校验")
      expect(result.report).to match(/\.pptx/)
      expect(result.report).to include("0 个 error")
    end
  end

  it "普通页缺失字段 → error 定位页码/形状/标签" do
    broken = COMPLETE_DATA.except(:workload)
    result = check(labeled_with_directives, data: broken)
    e = result.errors.find { |x| x.label == "workload" }
    aggregate_failures do
      expect(e).not_to be_nil
      expect(e.slide_no).to eq(2)
      expect(e.shape).to eq("圆角矩形 4")
      expect(e.message).to include("workload")
    end
  end

  it "#each 页逐项对账:缺哪项报哪项,附期望路径" do
    data = { scenarios: [{ headline: "齐" }, { headline: "齐" }, {}] }
    result = check(labeled_with_directives, data: data)
    e = result.errors.find { |x| x.message.include?("第 3 项") }
    expect(e.message).to include("scenarios", "headline", "期望:scenarios[2].headline")
  end

  it "#each 路径缺失/非数组 → error;空数组 → 删组 warning" do
    aggregate_failures do
      result = check(labeled_with_directives, data: COMPLETE_DATA.except(:scenarios))
      expect(result.errors).to include(an_object_having_message(/没有字段 'scenarios'/))

      result2 = check(labeled_with_directives, data: COMPLETE_DATA.merge(scenarios: "老师"))
      expect(result2.errors).to include(an_object_having_message(/必须为数组/))

      result3 = check(labeled_with_directives, data: COMPLETE_DATA.merge(scenarios: []))
      expect(result3.warnings).to include(an_object_having_message(/整组删除/))
    end
  end

  it "#if 为假 → 删页 warning;为真 → 无" do
    result = check(labeled_with_directives, data: COMPLETE_DATA.merge(show_compare: false))
    expect(result.warnings.map(&:message).join).to include("show_compare", "将被删除")

    result2 = check(labeled_with_directives, data: COMPLETE_DATA)
    expect(result2.warnings.map(&:message).join).not_to include("将被删除")
  end

  it "占位文本溢出预警:绑定值显著长于占位标签时 warning" do
    labeled = inject(
      LABELS + [{ slide_no: 2, shape: "文本框 92", old_text: "教师的工作被\"切开了\"",
                  runs: ["{{long_text}}"] }]
    )
    long = "这是一段非常非常非常非常非常非常长的标题文本,用来触发占位文本溢出预警检查"
    result = check(labeled, data: COMPLETE_DATA.merge(long_text: long))
    e = result.warnings.find { |x| x.label == "long_text" }
    aggregate_failures do
      expect(e).not_to be_nil
      expect(e.slide_no).to eq(2)
      expect(e.message).to include("溢出")
    end
  end

  it "语法坏标签 → error 条目而非异常(check 不抛 TemplateSyntaxError)" do
    labeled = inject([{ slide_no: 2, shape: "文本框 18", old_text: "现状痛点",
                        runs: ["{{foo bar}}"] }])
    result = check(labeled, data: COMPLETE_DATA)
    aggregate_failures do
      expect(result.errors.size).to eq(1)
      expect(result.errors.first.message).to include("只支持点路径与下标")
      expect(result.errors.first.slide_no).to eq(2)
    end
  end

  it "备注多条指令 → error 条目" do
    labeled = inject([], 2 => "{{#each a}}\n{{#if b}}")
    result = check(labeled, data: COMPLETE_DATA)
    expect(result.errors.first.message).to include("只允许一条")
  end

  it "备注残留普通标签 → warning(§3.3)" do
    labeled = inject([], 2 => "设计说明 {{note_only}}")
    result = check(labeled, data: COMPLETE_DATA)
    expect(result.warnings.map(&:message).join).to include("{{note_only}}", "不渲染备注")
  end

  it "未使用字段 → warning" do
    result = check(labeled_with_directives, data: COMPLETE_DATA.merge(extra_field: "x"))
    expect(result.warnings.map(&:message).join).to include("'extra_field' 未被模板使用")
  end

  it "未提供样例数据 → 跳过对账的 warning,语法错误仍会报告" do
    result = check(labeled_with_directives)
    aggregate_failures do
      expect(result.ok?).to be(true)
      expect(result.warnings.map(&:message).join).to include("未提供样例数据")
    end

    bad = inject([{ slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{#each x}}"] }])
    result2 = check(bad)
    expect(result2.errors.map(&:message).join).to include("页级指令")
  end

  it "data 传 .toml 路径直接装载(TOML 默认格式)" do
    data_path = File.join(@tmp_root, "check_data.toml")
    File.write(data_path, <<~TOML)
      page_title = "学生工作台"
      workload = "教学负担"
      highlight_title = "亮点一｜效率翻倍"
      show_compare = true
      [[scenarios]]
      headline = "晨读材料包"
      [[scenarios]]
      headline = "家长会材料"
    TOML
    result = check(labeled_with_directives, data: data_path)
    expect(result.ok?).to be(true)
  end

  describe "图片占位对账(M4 §5.3)" do
    define_method(:labeled_image) do |with_each: false|
      inject(
        LABELS,
        with_each ? { 9 => "{{#each scenarios}}" } : {},
        [{ slide_no: 5, old_name: "图片 41", new_name: "powertom:image:banner" },
         { slide_no: 9, old_name: "图片 18", new_name: "powertom:image:cover" }]
      )
    end

    it "图片字段缺失 → error 定位页码/形状" do
      result = check(labeled_image, data: COMPLETE_DATA)
      e = result.errors.find { |x| x.label == "banner" }
      aggregate_failures do
        expect(e).not_to be_nil
        expect(e.slide_no).to eq(5)
        expect(e.shape).to eq("powertom:image:banner")
      end
    end

    it "图片文件不存在 → error" do
      result = check(labeled_image, data: COMPLETE_DATA.merge(banner: "/no/such.png"))
      expect(result.errors.map(&:message).join).to include("图片文件不存在")
    end

    it "#each 页图片字段逐项对账:缺哪项报哪项" do
      data = COMPLETE_DATA.merge(
        scenarios: [{ headline: "x", cover: "/tmp/a.png" }, { headline: "y" }]
      )
      result = check(labeled_image(with_each: true), data: data)
      expect(result.errors.find { |x| x.label == "cover" && x.message.include?("第 2 项") })
        .not_to be_nil
    end
  end

  describe "formatter 对账(M4 §3.4)" do
    define_method(:inject_formatter) do |spec|
      inject([{ slide_no: 2, shape: "文本框 5",
                old_text: "备课、分析、反思、档案和日常办公，每件事都在不同的入口、不同的工具里",
                runs: ["{{ratio:#{spec}}}"] }])
    end

    it "已注册 formatter 无 error;未注册报 error 并列出可用名" do
      result = check(inject_formatter("percent.1"), data: COMPLETE_DATA.merge(ratio: 0.1))
      expect(result.errors.map(&:message).join).not_to include("formatter")

      result2 = check(inject_formatter("nope.2"), data: COMPLETE_DATA.merge(ratio: 0.1))
      expect(result2.errors.map(&:message).join).to include("未注册的 formatter 'nope'")
    end
  end

  context "rake powertom:check(§4 公共 API 层)" do
    it "好模板 + 完整数据:退出码 0" do
      data_path = File.join(@tmp_root, "rake_ok.toml")
      File.write(data_path, <<~TOML)
        page_title = "学生工作台"
        workload = "教学负担"
        highlight_title = "亮点一｜效率翻倍"
        show_compare = true
        [[scenarios]]
        headline = "晨读材料包"
        [[scenarios]]
        headline = "家长会材料"
      TOML
      ok = system("bundle", "exec", "rake", "powertom:check",
                  "TEMPLATE=#{labeled_with_directives}", "DATA=#{data_path}",
                  out: File::NULL, err: File::NULL)
      expect(ok).to be(true)
    end

    it "缺字段模板:退出码 1(坏模板在 CI 阶段报错)" do
      data_path = File.join(@tmp_root, "rake_bad.toml")
      File.write(data_path, "page_title = \"学生工作台\"\n")
      ok = system("bundle", "exec", "rake", "powertom:check",
                  "TEMPLATE=#{labeled_with_directives}", "DATA=#{data_path}",
                  out: File::NULL, err: File::NULL)
      expect(ok).to be(false)
    end
  end
end

# 辅助 matcher:error/warning 条目的 message 断言
# (include 会把每个元素传给 matcher,actual 即单个 CheckEntry)
RSpec::Matchers.define :an_object_having_message do |expected|
  match do |actual|
    expected.match?(actual.message)
  end
end
