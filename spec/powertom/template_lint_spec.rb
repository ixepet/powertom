# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "fileutils"
require_relative "../../tools/template_lint"

# 模板结构自检:按契约核对页数/形状/标签/指令/图片占位。
# 契约驱动的意义:换场景只换 TOML,不改代码。
RSpec.describe PowerTomDev::TemplateLint do
  fixture_dir = File.expand_path("../fixtures/hai_mate", __dir__)
  template_path = File.join(fixture_dir, "template.pptx")

  @tmp_root = nil
  before(:all) do
    skip "缺少 fixture — 放好原始 pptx 后运行 rake fixtures:generate" unless File.file?(template_path)
    @tmp_root = Dir.mktmpdir("powertom_lint_spec")
    @labeled = File.join(@tmp_root, "labeled.pptx")
    PowerTomDev::LabelInjector.inject(
      template_path, @labeled,
      [
        { slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{page_title}}"] },
        { slide_no: 2, shape: "圆角矩形 4", old_text: "    工作复杂", runs: ["    {{wor", "kload}}"] },
        { slide_no: 9, shape: "文本框 30", old_text: "每周日晚自动生成下周晨读材料包",
          runs: ["{{headline}}"] }
      ],
      notes_assignments: { 9 => "{{#each scenarios}}" }
    )
  end
  after(:all) do
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  def contract(body)
    path = File.join(@tmp_root, "contract_#{SecureRandom.hex(4)}.toml")
    File.write(path, body)
    path
  end

  # 覆盖 P2(普通页)与 P9(循环页)的最小契约
  def base_contract
    contract(<<~TOML)
      [[pages]]
      index = 2
      shapes = ["文本框 18", "圆角矩形 4"]
      labels = ["page_title", "workload"]

      [[pages]]
      index = 9
      directive = "each scenarios"
      labels = ["headline"]
    TOML
  end

  def messages(result)
    result.errors.map(&:message).join("\n")
  end

  it "完全匹配:无 error,ok?" do
    result = described_class.run(template: @labeled, contract: base_contract)
    aggregate_failures do
      expect(result.errors).to be_empty
      expect(result.ok?).to be(true)
      expect(result.exit_code).to eq(0)
    end
  end

  it "页数不符 → error" do
    c = contract("slide_count = 3\n\n[[pages]]\nindex = 2\n")
    result = described_class.run(template: @labeled, contract: c)
    expect(messages(result)).to include("页数不符", "契约 3 页", "实际 18 页")
  end

  it "缺少形状 → error 带页码与形状名" do
    c = contract("[[pages]]\nindex = 2\nshapes = [\"不存在的形状\"]\n")
    result = described_class.run(template: @labeled, contract: c)
    e = result.errors.find { |x| x.message.include?("缺少形状") }
    aggregate_failures do
      expect(e.page).to eq(2)
      expect(e.message).to include("不存在的形状")
    end
  end

  it "缺少标签 → error;带 formatter 的标签要求写全" do
    c = contract(<<~TOML)
      [[pages]]
      index = 2
      labels = ["page_title:number"]
    TOML
    result = described_class.run(template: @labeled, contract: c)
    expect(messages(result)).to include("缺少标签:{{page_title:number}}")
  end

  it "契约外标签 → warning(防止拼错的标签留在页面上)" do
    c = contract("[[pages]]\nindex = 2\nlabels = [\"page_title\"]\n")
    result = described_class.run(template: @labeled, contract: c)
    expect(result.warnings.map(&:message).join).to include("契约外标签:{{workload}}")
    expect(result.ok?).to be(true)
  end

  it "备注指令不符(应有却无 / 不应有却有)→ error" do
    should_have = contract("[[pages]]\nindex = 9\n")
    expect(messages(described_class.run(template: @labeled, contract: should_have)))
      .to include("备注指令不符", "契约 无", "实际 {{#each scenarios}}")

    should_not = contract("[[pages]]\nindex = 2\ndirective = \"if show\"\n")
    expect(messages(described_class.run(template: @labeled, contract: should_not)))
      .to include("契约 {{#if show}}", "实际 无")
  end

  context "图片占位" do
    define_method(:image_template) do
      path = File.join(@tmp_root, "with_image.pptx")
      PowerTomDev::LabelInjector.inject(
        @labeled, path, [],
        renames: [{ slide_no: 5, old_name: "图片 41", new_name: "powertom:image:banner" }]
      )
      path
    end

    it "声明且命名正确 → 通过" do
      c = contract("[[pages]]\nindex = 5\nimages = [\"powertom:image:banner\"]\n")
      result = described_class.run(template: image_template, contract: c)
      expect(result.errors).to be_empty
    end

    it "声明了但缺失 → error;命名拼错但存在同名文本形状 → 不是图片" do
      c = contract("[[pages]]\nindex = 5\nimages = [\"powertom:image:nope\"]\n")
      result = described_class.run(template: image_template, contract: c)
      expect(messages(result)).to include("缺少图片占位:'powertom:image:nope'")

      wrong_kind = File.join(@tmp_root, "wrong_kind.pptx")
      PowerTomDev::LabelInjector.inject(
        @labeled, wrong_kind, [],
        renames: [{ slide_no: 9, old_name: "文本框 30", new_name: "powertom:image:fake" }]
      )
      c2 = contract("[[pages]]\nindex = 9\nimages = [\"powertom:image:fake\"]\n")
      result2 = described_class.run(template: wrong_kind, contract: c2)
      expect(messages(result2)).to include("存在但不是图片")
    end

    it "契约外图片占位 → warning(拼错的占位不会被使用)" do
      c = contract("[[pages]]\nindex = 5\n")
      result = described_class.run(template: image_template, contract: c)
      expect(result.warnings.map(&:message).join).to include("契约外图片占位:'powertom:image:banner'")
    end
  end

  it "母版/版式上写标签 → error(规范禁止,引擎也不会替换)" do
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(@labeled)
    layout = nil
    prs.slide_masters.each do |master|
      next if layout
      master.slide_layouts.each do |candidate|
        layout ||= candidate if candidate.shapes.any?(&:text_frame?)
      end
    end
    shape = layout.shapes.to_a.find(&:text_frame?)
    shape.text_frame.text = "{{oops}}"
    path = File.join(@tmp_root, "layout_tag.pptx")
    adapter.save(prs, path)

    result = described_class.run(template: path, contract: base_contract)
    expect(messages(result)).to include("母版/版式上的标签不会生效", "{{oops}}")
  end

  it "备注里残留普通标签 → warning" do
    path = File.join(@tmp_root, "notes_tag.pptx")
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(@labeled)
    prs.slides[1].notes = "设计说明 {{note_only}}"
    adapter.save(prs, path)

    result = described_class.run(template: path, contract: base_contract)
    expect(result.warnings.map(&:message).join).to include("备注含标签 {{note_only}}", "不会渲染")
  end

  it "传 DATA 时附带数据对账(powertom:check)" do
    result = described_class.run(template: @labeled, contract: base_contract, data: {})
    aggregate_failures do
      expect(result.check).not_to be_nil
      expect(result.check.errors).not_to be_empty
      expect(result.report).to include("数据对账", "powertom:check")
    end
  end

  it "契约缺 [[pages]] → 明确报错" do
    c = contract("slide_count = 1\n")
    expect { described_class.run(template: @labeled, contract: c) }
      .to raise_error(ArgumentError, /pages/)
  end

  it "rake powertom:lint 冒烟:好契约退出码 0" do
    ok = system("bundle", "exec", "rake", "powertom:lint",
                "TEMPLATE=#{@labeled}", "CONTRACT=#{base_contract}",
                out: File::NULL, err: File::NULL)
    expect(ok).to be(true)
  end
end
