# frozen_string_literal: true

require "date"
require "fileutils"
require "tmpdir"
require_relative "../../examples/score_report/report_data_builder"
require_relative "../../examples/score_report/deck_exporter"
require_relative "../../tools/build_score_report_template_v2"

# 阶段 1 导出编排:预检 → 渲染 → 上传 → 错误映射(v2 契约)。
RSpec.describe ScoreReport::DeckExporter do
  around do |example|
    Dir.mktmpdir("deck_exporter_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:analysis) { PowerTomDev::ScoreReportAnalysis.full }

  define_method(:data) do
    @data ||= ScoreReport::DataBuilder.new(analysis: analysis).build
  end

  define_method(:template) do
    @template ||= PowerTomDev::ScoreReportScaffoldV2.build(File.join(@dir, "template.pptx"))
  end

  # 本地文件上传器:复制到目标目录并返回 file:// URL;记录收到的路径
  def local_uploader
    calls = []
    uploader = lambda do |path, key|
      calls << { path: path, key: key }
      dest = File.join(@dir, "uploaded", File.basename(key))
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(path, dest)
      "file://#{dest}"
    end
    [uploader, calls]
  end

  def exporter(uploader:, **options)
    described_class.new(template_path: template, uploader: uploader, **options)
  end

  it "正常导出:返回 URL/页数/耗时,产物可被重新打开,临时文件已清理" do
    uploader, calls = local_uploader
    result = exporter(uploader: uploader, template_version: "v1").call(data: data)

    uploaded = result.url.delete_prefix("file://")
    aggregate_failures do
      expect(result.slide_count).to eq(9) # v2: 固定 9 页,表格行数随数据
      expect(result.template_version).to eq("v1")
      expect(result.warnings).to be_empty
      expect(result.duration_ms).to be_a(Integer)
      expect(result.duration_ms).to be >= 0
      expect(result.key).to start_with("score-report/")
      expect(result.key).to end_with(".pptx")
      expect(File.file?(uploaded)).to be(true)
      expect(Pptx::Presentation.open(uploaded).slides.size).to eq(9)
      expect(File.exist?(calls.first[:path])).to be(false)
    end
  end

  it "check 的 warning 不阻断,透出到结果里" do
    uploader, = local_uploader
    result = exporter(uploader: uploader).call(data: data.merge(unused_note: "x"))

    expect(result.warnings.join).to include("'unused_note'")
    expect(result.slide_count).to eq(9)
  end

  it "数据不完整 → DataError,给老师可读消息,不调用上传" do
    uploader, calls = local_uploader
    broken = data.except(:classes)

    expect { exporter(uploader: uploader).call(data: broken) }.to raise_error(described_class::DataError) do |error|
      expect(error.user_message).to include("数据不完整")
      expect(error.message).to include("classes")
    end
    expect(calls).to be_empty
  end

  it "模板语法错误 → TemplateError(先区分模板问题,而不是当成数据问题)" do
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(template)
    adapter.find_shape(prs, 1, "封面-标题").text_frame.text = "{{bad tag}}"
    broken = File.join(@dir, "broken.pptx")
    adapter.save(prs, broken)

    uploader, calls = local_uploader
    exporter = described_class.new(template_path: broken, uploader: uploader)

    expect { exporter.call(data: data) }.to raise_error(described_class::TemplateError) do |error|
      expect(error.user_message).to include("模板异常")
      expect(error.message).to include("bad tag")
    end
    expect(calls).to be_empty
  end

  it "上传失败 → UploadError,保留底层原因供日志" do
    uploader = ->(_path, _key) { raise IOError, "disk full" }

    expect { exporter(uploader: uploader).call(data: data) }.to raise_error(described_class::UploadError) do |error|
      expect(error.user_message).to include("保存失败")
      expect(error.message).to include("disk full")
    end
  end

  it "关闭预检时仍能把渲染阶段的缺数据映射成 DataError" do
    uploader, = local_uploader
    broken = data.except(:classes)
    exporter = described_class.new(template_path: template, uploader: uploader, preflight: false)

    expect { exporter.call(data: broken) }
      .to raise_error(described_class::DataError, /classes|class/)
  end
end
