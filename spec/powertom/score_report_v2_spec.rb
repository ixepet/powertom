# frozen_string_literal: true

require "tmpdir"
require_relative "../../tools/build_score_report_template_v2"
require_relative "../../tools/template_lint"

# v2:对齐真实 9 页 deck 的契约、脚手架与样例数据一致性。
RSpec.describe "成绩分析报告 v2" do
  examples_dir = File.expand_path("../../examples/score_report", __dir__)
  contract_path = File.join(examples_dir, "template_contract_v2.toml")
  sample_path = File.join(examples_dir, "sample_v2.toml")

  around do |example|
    Dir.mktmpdir("score_report_v2_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  define_method(:template) do
    @template ||= PowerTomDev::ScoreReportScaffoldV2.build(File.join(@dir, "template.pptx"))
  end

  def tables(pptx)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    [3, 4, 5, 6].map do |index|
      frame = prs.slides[index].shapes.to_a.find { |s| s.respond_to?(:table?) && s.table? }
      frame.table
    end
  end

  it "结构自检与数据对账均 0 error / 0 warning" do
    result = PowerTomDev::TemplateLint.run(
      template: template, contract: contract_path, data: sample_path
    )
    aggregate_failures do
      expect(result.errors.map(&:message)).to be_empty
      expect(result.warnings.map(&:message)).to be_empty
      expect(result.ok?).to be(true)
    end
  end

  it "渲染:9 页,四张表按数组展开,合计行与末行正确" do
    out = File.join(@dir, "out.pptx")
    PowerTom.render(template, data: sample_path).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(out)
    p4, p5, p6, p7 = tables(out)

    aggregate_failures do
      expect(prs.slides.size).to eq(9)
      expect(p4.rows.size).to eq(10) # 表头 + 8 班 + 合计
      expect(p5.rows.size).to eq(10)
      expect(p6.rows.size).to eq(10)
      expect(p7.rows.size).to eq(11) # 表头 + 10 名学生
      expect(p4.cell(1, 0).text).to eq("初二(1)班")
      expect(p4.cell(9, 1).text).to eq("486")
      expect(p7.cell(10, 0).text).to eq("学生J")
      expect(adapter.paragraph_contexts(prs).select { |c| c[:slide_no] == 1 }
                    .map { |c| c[:run_texts].join })
        .to include("2026年01月20日")
    end
  end

  it "附录关闭 → 8 页(条件页生效)" do
    data = PowerTom::DataLoading.coerce(sample_path).merge("show_appendix" => false)
    out = File.join(@dir, "no_appendix.pptx")
    PowerTom.render(template, data: data).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    expect(adapter.open(out).slides.size).to eq(8)
  end
end
