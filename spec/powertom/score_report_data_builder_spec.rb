# frozen_string_literal: true

require "date"
require "tmpdir"
require_relative "../../examples/score_report/report_data_builder"
require_relative "../../tools/build_score_report_template_v2"

# v2:分析结果 → 9 页契约数据(4 个表格数组 + totals + 结论)。
RSpec.describe ScoreReport::DataBuilder do
  around do |example|
    Dir.mktmpdir("score_report_builder_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build(analysis = PowerTomDev::ScoreReportAnalysis.full)
    described_class.new(analysis: analysis).build
  end

  describe "指标卡" do
    it "固定 4 个,数值与环比按模板口径格式化" do
      kpis = build[:kpis]
      aggregate_failures do
        expect(kpis.size).to eq(4)
        expect(kpis[0]).to eq(label: "平均分", value: "83.4", delta: "+1.8 分")
        expect(kpis[1]).to eq(label: "优秀率(≥85%)", value: "32.3%", delta: "+2.3pt")
        expect(kpis[2]).to eq(label: "及格率(≥60%)", value: "91.7%", delta: "+1.2pt")
        expect(kpis[3]).to eq(label: "参考人数", value: "121", delta: "+6 人")
      end
    end

    it "没有上次考试数据时环比留空" do
      analysis = PowerTomDev::ScoreReportAnalysis.full
      analysis[:overall] = analysis[:overall].reject { |key, _| key == :previous }
      expect(build(analysis)[:kpis].map { |k| k[:delta] }).to eq(["", "", "", ""])
    end

    it "缺必要指标时给出可读错误" do
      analysis = PowerTomDev::ScoreReportAnalysis.full
      analysis[:overall] = analysis[:overall].reject { |key, _| key == :average }
      expect { build(analysis) }
        .to raise_error(ScoreReport::DataBuilder::Error, /缺少必要数据:average/)
    end
  end

  describe "表格行数据" do
    it "班级行:均分、比率、环比、排名" do
      classes = build[:classes]
      aggregate_failures do
        expect(classes.size).to eq(2)
        expect(classes[0]).to include(name: "初二(1)班", count: 61, avg: "81.5",
                                      excellent: "27.9%", pass: "93.4%",
                                      delta: "+1.2", rank: 1)
        expect(classes[1][:delta]).to eq("+2.4")
      end
    end

    it "学科行:得分率按平均分/满分计算" do
      subjects = build[:subjects]
      aggregate_failures do
        expect(subjects[0]).to include(name: "语文", full: 120, avg: "100.9", rate: "84.1%")
        expect(subjects[1]).to include(name: "物理", rate: "73.8%")
      end
    end

    it "关注学生:薄弱学科合并,超过 10 人截断并提示" do
      analysis = PowerTomDev::ScoreReportAnalysis.full(
        students: PowerTomDev::ScoreReportAnalysis.many_students(12)
      )
      data = build(analysis)
      aggregate_failures do
        expect(data[:students].size).to eq(10)
        expect(data[:student_note]).to include("节选前 10 人", "共 12 人")
        expect(data[:students][0][:weak]).to eq("物理")
      end

      few = build[:students]
      expect(few[1][:weak]).to eq("物理、数学")
    end

    it "分布与人数不一致 → 拒绝出图" do
      analysis = PowerTomDev::ScoreReportAnalysis.full
      # 单行自洽(17+26+15+4=62),但分布合计 122 与班级合计 121 不等
      analysis[:distribution][0][:count] = 62
      analysis[:distribution][0][:good] = 26
      expect { build(analysis) }
        .to raise_error(ScoreReport::DataBuilder::Error, /分数段与班级人数不一致/)
    end

    it "单行分数段合计与参考人数不一致 → 拒绝出图" do
      analysis = PowerTomDev::ScoreReportAnalysis.full
      analysis[:distribution][0][:excellent] = 18
      expect { build(analysis) }
        .to raise_error(ScoreReport::DataBuilder::Error, /四段合计 62 人,参考人数 61 人/)
    end
  end

  describe "合计行" do
    it "由明细汇总:人数、各分数段人数、满分" do
      totals = build[:totals]
      aggregate_failures do
        expect(totals[:class_count]).to eq(121)
        expect(totals[:excellent_count]).to eq(39)
        expect(totals[:good_count]).to eq(45)
        expect(totals[:pass_count]).to eq(27)
        expect(totals[:fail_count]).to eq(10)
        expect(totals[:full_score]).to eq(220)
        expect(totals[:avg]).to eq("83.4")
      end
    end
  end

  describe "结论文案" do
    it "缺省按数据自动生成" do
      data = build
      aggregate_failures do
        expect(data[:class_comparison_note]).to include("初二(2)班", "初二(1)班")
        expect(data[:subject_note]).to include("物理", "73.8%")
        expect(data[:distribution_note]).to include("未及格 10 人")
        expect(data[:student_note]).to include("共 2 人")
      end
    end

    it "分析服务提供 notes 时优先使用" do
      analysis = PowerTomDev::ScoreReportAnalysis.full
      analysis[:notes] = { kpi: "自定义总评", distribution: "自定义分布结论" }
      data = build(analysis)
      aggregate_failures do
        expect(data[:kpi_note]).to eq("自定义总评")
        expect(data[:distribution_note]).to eq("自定义分布结论")
      end
    end
  end

  describe "改进措施" do
    it "不足 3 条补「暂无」" do
      analysis = PowerTomDev::ScoreReportAnalysis.full(measures: ["只给一条"])
      measures = build(analysis)[:measures]
      aggregate_failures do
        expect(measures.size).to eq(3)
        expect(measures[0][:text]).to eq("只给一条")
        expect(measures[2][:text]).to eq("暂无")
      end
    end

    it "超过 3 条报错(模板固定 3 条)" do
      analysis = PowerTomDev::ScoreReportAnalysis.full(measures: Array.new(4) { "建议" })
      expect { build(analysis) }
        .to raise_error(ScoreReport::DataBuilder::Error, /最多 3 条/)
    end
  end

  describe "必填校验" do
    it "班级为空 → 拒绝出图" do
      analysis = PowerTomDev::ScoreReportAnalysis.full
      analysis[:class_stats] = []
      expect { build(analysis) }
        .to raise_error(ScoreReport::DataBuilder::Error, /缺少班级成绩数据/)
    end
  end

  describe "端到端:契约数据直接渲染 v2 脚手架" do
    it "9 页,四张表行数随数组长度展开" do
      template = PowerTomDev::ScoreReportScaffoldV2.build(File.join(@dir, "template.pptx"))
      out = File.join(@dir, "out.pptx")
      PowerTom.render(template, data: build).save(out)

      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(out)
      table = lambda do |index|
        frame = prs.slides[index].shapes.to_a.find { |s| s.respond_to?(:table?) && s.table? }
        frame.table
      end

      aggregate_failures do
        expect(prs.slides.size).to eq(9)
        expect(table.call(3).rows.size).to eq(4)  # 表头 + 2 班 + 合计
        expect(table.call(4).rows.size).to eq(4)  # 表头 + 2 学科 + 合计
        expect(table.call(5).rows.size).to eq(4)  # 表头 + 2 班 + 合计
        expect(table.call(6).rows.size).to eq(3)  # 表头 + 2 学生
        expect(table.call(3).cell(1, 0).text).to eq("初二(1)班")
        expect(table.call(6).cell(2, 0).text).to eq("学生B")
      end
    end
  end
end
