# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../../tools/build_score_report_template"
require_relative "../../tools/template_lint"

# 成绩分析报告脚手架 ↔ 契约 ↔ 样例数据 三方一致性回归。
# 这组测试不依赖私有金样本,CI 里能完整跑通 lint + render 全链路。
RSpec.describe "成绩分析报告脚手架" do
  examples_dir = File.expand_path("../../examples/score_report", __dir__)
  contract_path = File.join(examples_dir, "template_contract.toml")
  sample_path = File.join(examples_dir, "sample.toml")

  around do |example|
    Dir.mktmpdir("powertom_scaffold_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_template
    PowerTomDev::ScoreReportScaffold.build(File.join(@dir, "template.pptx"))
  end

  it "按契约生成:结构自检与数据对账均 0 error / 0 warning" do
    result = PowerTomDev::TemplateLint.run(
      template: build_template, contract: contract_path, data: sample_path
    )
    aggregate_failures do
      expect(result.errors.map(&:message)).to be_empty
      expect(result.warnings.map(&:message)).to be_empty
      expect(result.ok?).to be(true)
    end
  end

  it "样例数据渲染:10 页,封面与四个班级页内容正确" do
    out = File.join(@dir, "out.pptx")
    PowerTom.render(build_template, data: sample_path).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(out)
    contexts = adapter.paragraph_contexts(prs)

    texts = lambda do |slide_no, shape|
      contexts.select { |c| c[:slide_no] == slide_no && c[:shape] == shape }
              .map { |c| c[:run_texts].join }
              .first
    end

    aggregate_failures do
      expect(prs.slides.size).to eq(10) # 7 页模板 + 4 个班克隆 - 1 页模板 = 10
      expect(texts.call(1, "封面-标题")).to eq("2026 学年第一学期期末成绩分析")
      expect(texts.call(1, "封面-日期")).to eq("2026年01月20日")
      expect([4, 5, 6, 7].map { |no| texts.call(no, "班级-标题") })
        .to eq(["初二(3)班", "初二(4)班", "初二(5)班", "初二(7)班"])
      expect(texts.call(10, "附录-数据来源")).to eq("教务系统期末统考成绩(2026-01-15 导出)")
    end
  end

  it "附录开关关闭时少一页(条件页生效)" do
    data = PowerTom::DataLoading.coerce(sample_path).merge("show_appendix" => false)
    out = File.join(@dir, "no_appendix.pptx")
    PowerTom.render(build_template, data: data).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    expect(adapter.open(out).slides.size).to eq(9)
  end
end
