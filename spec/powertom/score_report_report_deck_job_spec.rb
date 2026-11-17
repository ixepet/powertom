# frozen_string_literal: true

require "date"
require "fileutils"
require "tmpdir"
require_relative "../../examples/score_report/report_deck_job"
require_relative "../../examples/score_report/report_data_builder"
require_relative "../../examples/score_report/deck_exporter"
require_relative "../../tools/build_score_report_template_v2"

# 异步任务:重试策略、终态判定、通知协议(v2 契约)。
RSpec.describe ScoreReport::ReportDeckJob do
  FakeResult = Struct.new(:url, :slide_count, :warnings)

  # 按剧本依次抛错或返回结果的假导出器(模拟队列的多次 attempt)
  class ScriptedExporter
    def initialize(*steps)
      @steps = steps
    end

    def call(data:)
      step = @steps.shift
      raise step if step.is_a?(Exception)

      step
    end
  end

  around do |example|
    Dir.mktmpdir("report_deck_job_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:events) { [] }
  let(:notifier) { ->(event, payload) { events << [event, payload] } }
  let(:builder) { ->(_analysis) { { report_title: "x" } } }
  let(:result) { FakeResult.new("https://oss.example/report.pptx", 8, []) }

  def job(exporter, max_attempts: 3)
    described_class.new(builder: builder, exporter: exporter,
                        notifier: notifier, max_attempts: max_attempts)
  end

  def upload_error
    ScoreReport::DeckExporter::UploadError.new(
      "报告已生成但保存失败,请稍后重试", detail: "IOError: disk full"
    )
  end

  def data_error
    ScoreReport::DeckExporter::DataError.new(
      "本次分析数据不完整,暂时无法生成报告", detail: "缺少 classes"
    )
  end

  it "成功:返回 :succeeded,通知带 URL 与页数" do
    outcome = job(ScriptedExporter.new(result)).perform(analysis: {})

    aggregate_failures do
      expect(outcome.succeeded?).to be(true)
      expect(outcome.result.url).to eq("https://oss.example/report.pptx")
      expect(outcome.attempt).to eq(1)
      expect(events.map(&:first)).to eq([:succeeded])
      expect(events.last.last).to include(url: "https://oss.example/report.pptx",
                                         slide_count: 8)
    end
  end

  it "上传失败:第 1 次可重试,退避 10s;第 2 次成功" do
    exporter = ScriptedExporter.new(upload_error, result)
    service = job(exporter)

    first = service.perform(analysis: {}, attempt: 1)
    aggregate_failures do
      expect(first.retry_scheduled?).to be(true)
      expect(first.retry_in).to eq(10)
      expect(first.error).to be_a(ScoreReport::DeckExporter::UploadError)
      expect(events.map(&:first)).to eq([:retrying])
      expect(events.last.last).to include(attempt: 1, next_attempt: 2, retry_in: 10)
    end

    second = service.perform(analysis: {}, attempt: 2)
    aggregate_failures do
      expect(second.succeeded?).to be(true)
      expect(events.map(&:first)).to eq(%i[retrying succeeded])
    end
  end

  it "上传持续失败:指数退避 10s → 20s,到上限转终态失败" do
    service = job(ScriptedExporter.new(upload_error, upload_error, upload_error),
                  max_attempts: 3)

    waits = (1..3).map { |attempt| service.perform(analysis: {}, attempt: attempt).retry_in }
    aggregate_failures do
      expect(waits).to eq([10, 20, nil])
      expect(events.map(&:first)).to eq(%i[retrying retrying failed])
      expect(events.last.last[:user_message]).to include("保存失败")
    end
  end

  it "数据不完整:立即终态失败,不浪费重试" do
    outcome = job(ScriptedExporter.new(data_error)).perform(analysis: {}, attempt: 1)

    aggregate_failures do
      expect(outcome.failed?).to be(true)
      expect(outcome.retry_in).to be_nil
      expect(events.map(&:first)).to eq([:failed])
      expect(events.last.last[:user_message]).to include("数据不完整")
    end
  end

  it "模板异常:立即终态失败" do
    template_error = ScoreReport::DeckExporter::TemplateError.new(
      "报告模板异常,请联系管理员", detail: "TemplateSyntaxError"
    )
    outcome = job(ScriptedExporter.new(template_error)).perform(analysis: {}, attempt: 1)

    aggregate_failures do
      expect(outcome.failed?).to be(true)
      expect(outcome.retry_in).to be_nil
    end
  end

  it "数据组装失败(未预期异常):终态失败,消息透传" do
    bad_builder = ->(_analysis) { raise ScoreReport::DataBuilder::Error, "本次分析缺少班级成绩数据" }
    service = described_class.new(builder: bad_builder, exporter: ScriptedExporter.new(result),
                                  notifier: notifier)

    outcome = service.perform(analysis: {})
    aggregate_failures do
      expect(outcome.failed?).to be(true)
      expect(outcome.user_message).to include("缺少班级成绩数据")
      expect(events.last.first).to eq(:failed)
    end
  end

  it "端到端:真实 Builder + Exporter 跑通,页数与 URL 正确" do
    template = PowerTomDev::ScoreReportScaffoldV2.build(File.join(@dir, "template.pptx"))
    uploader = lambda do |path, key|
      dest = File.join(@dir, "uploaded", File.basename(key))
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(path, dest)
      "file://#{dest}"
    end
    exporter = ScoreReport::DeckExporter.new(template_path: template, uploader: uploader)

    analysis = PowerTomDev::ScoreReportAnalysis.full
    service = described_class.new(
      builder: ->(payload) { ScoreReport::DataBuilder.new(analysis: payload).build },
      exporter: exporter, notifier: notifier
    )

    outcome = service.perform(analysis: analysis)
    aggregate_failures do
      expect(outcome.succeeded?).to be(true)
      expect(outcome.result.slide_count).to eq(9) # v2 固定 9 页
      expect(File.file?(outcome.result.url.delete_prefix("file://"))).to be(true)
    end
  end
end
