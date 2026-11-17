# frozen_string_literal: true

require "date"
require "tmpdir"

# 数据装载:TOML 默认格式 + 日期归一化。
RSpec.describe PowerTom::DataLoading do
  around do |example|
    Dir.mktmpdir("powertom_data") do |dir|
      @dir = dir
      example.run
    end
  end

  def write_toml(name, body)
    path = File.join(@dir, name)
    File.write(path, body)
    path
  end

  it "Hash 原样返回" do
    data = { title: "x" }
    expect(described_class.coerce(data)).to equal(data)
  end

  it "TOML 本地日期归一化为 Date,可与 date formatter 配合" do
    path = write_toml("d.toml", "report_date = 2026-01-20\n")
    data = described_class.coerce(path)
    aggregate_failures do
      expect(data["report_date"]).to be_a(Date)
      expect(data["report_date"]).to eq(Date.new(2026, 1, 20))
    end
  end

  it "嵌套结构(表数组)里的日期同样归一化" do
    path = write_toml("nested.toml", <<~TOML)
      [[classes]]
      name = "A"
      exam_date = 2026-01-20

      [[classes]]
      name = "B"
      exam_date = 2026-02-01
    TOML
    data = described_class.coerce(path)
    expect(data["classes"].map { |c| c["exam_date"] })
      .to eq([Date.new(2026, 1, 20), Date.new(2026, 2, 1)])
  end

  it "本地日期时间归一化为 Time" do
    path = write_toml("dt.toml", "generated_at = 2026-01-20T09:30:00\n")
    value = described_class.coerce(path)["generated_at"]
    aggregate_failures do
      expect(value).to be_a(Time)
      expect(value.strftime("%Y-%m-%d %H:%M")).to eq("2026-01-20 09:30")
    end
  end

  it "日期经 Binder + date formatter 端到端输出中文日期" do
    path = write_toml("fmt.toml", "report_date = 2026-01-20\n")
    data = described_class.coerce(path)
    binder = PowerTom::Binder.new(data, strict: true, warnings: [])
    ctx = { slide_no: 1, shape: "封面-日期" }
    expect(binder.render_label("report_date", ctx, spec: "date.cn")).to eq("2026年01月20日")
  end

  it "非 .toml 文件明确报错" do
    path = write_toml("data.yml", "title: x")
    expect { described_class.coerce(path) }
      .to raise_error(PowerTom::InvalidTemplateError, /\.toml/)
  end

  it "数据文件不存在时报错" do
    expect { described_class.coerce(File.join(@dir, "nope.toml")) }
      .to raise_error(PowerTom::InvalidTemplateError, /data file not found/)
  end

  it "TOML 语法错误包装为 InvalidTemplateError" do
    path = write_toml("bad.toml", "title = [unclosed\n")
    expect { described_class.coerce(path) }
      .to raise_error(PowerTom::InvalidTemplateError, /failed to parse/)
  end
end
