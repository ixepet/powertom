# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "spec_helper"
require "powertom/cli"

RSpec.describe PowerTom::CLI do
  around do |example|
    Dir.mktmpdir("powertom_cli_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    code = described_class.run(argv, out: out, err: err)
    [code, out.string, err.string]
  end

  def build_broken_template
    prs = Pptx::Presentation.new_default
    prs.slides.add(prs.slide_layouts["Blank"])
    footer = prs.slide_masters.first.placeholders
                .by_type(Pptx::Enum::PP_PLACEHOLDER_TYPE::FOOTER)
    footer.text = "{{company}}"
    path = File.join(@dir, "broken.pptx")
    prs.save(path)
    path
  end

  def build_text_template(text = "{{name}}")
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(0.5)],
                                   size: [Pptx.inches(4), Pptx.inches(1)])
    box.text_frame.text = text
    path = File.join(@dir, "text.pptx")
    prs.save(path)
    path
  end

  def slide_texts(pptx)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    adapter.paragraph_contexts(adapter.open(pptx)).map { |c| c[:run_texts].join }
  end

  it "check 通过时返回 0 并打印报告" do
    code, out, = run_cli("check", "spec/fixtures/mini/template.pptx")

    expect(code).to eq(0)
    expect(out).to include("PowerTom template check")
    expect(out).to include("0 error(s)")
  end

  it "check 发现 error 时返回 1" do
    code, out, = run_cli("check", build_broken_template)

    expect(code).to eq(1)
    expect(out).to include("[error")
  end

  it "模板打不开时返回 2 并写 stderr" do
    code, out, err = run_cli("check", File.join(@dir, "missing.pptx"))

    expect(code).to eq(2)
    expect(out).to be_empty
    expect(err).to include("powertom: cannot open template")
  end

  it "缺少 TEMPLATE 时返回 2" do
    code, _out, err = run_cli("check")

    expect(code).to eq(2)
    expect(err).to include("missing TEMPLATE")
  end

  it "未知命令返回 2" do
    code, _out, err = run_cli("deploy")

    expect(code).to eq(2)
    expect(err).to include("unknown command: deploy")
  end

  it "version 打印版本" do
    code, out, = run_cli("version")

    expect(code).to eq(0)
    expect(out.strip).to eq("powertom #{PowerTom::VERSION}")
  end

  it "exe/powertom 可以直接执行" do
    root = File.expand_path("../..", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{root}/lib",
                                      File.join(root, "exe/powertom"), "version")

    expect(status.exitstatus).to eq(0)
    expect(out.strip).to eq("powertom #{PowerTom::VERSION}")
    expect(err).to be_empty
  end

  it "render 用 JSON 数据生成 deck" do
    template = build_text_template
    data = File.join(@dir, "data.json")
    File.write(data, JSON.generate({ name: "Ada" }))
    out = File.join(@dir, "out.pptx")

    code, stdout, stderr = run_cli("render", template, "--data", data, "--out", out)

    expect(code).to eq(0)
    expect(stdout).to include("wrote")
    expect(stderr).to be_empty
    expect(slide_texts(out)).to eq(["Ada"])
  end

  it "render 用 TOML 数据生成 deck" do
    template = build_text_template
    data = File.join(@dir, "data.toml")
    File.write(data, "name = \"Grace\"\n")
    out = File.join(@dir, "out_toml.pptx")

    code, = run_cli("render", template, "--data", data, "--out", out)

    expect(code).to eq(0)
    expect(slide_texts(out)).to eq(["Grace"])
  end

  it "render 缺少 --out 时返回 2" do
    code, _out, err = run_cli("render", build_text_template, "--data", "x.json")

    expect(code).to eq(2)
    expect(err).to include("missing --out PATH")
  end

  it "render 的 JSON 损坏时返回 2" do
    template = build_text_template
    data = File.join(@dir, "bad.json")
    File.write(data, "{")
    out = File.join(@dir, "out.pptx")

    code, _stdout, err = run_cli("render", template, "--data", data, "--out", out)

    expect(code).to eq(2)
    expect(err).to include("failed to parse JSON")
  end

  it "check 支持 JSON 样例数据" do
    template = build_text_template
    data = File.join(@dir, "check.json")
    File.write(data, JSON.generate({ name: "Ada" }))

    code, out, = run_cli("check", template, "--data", data)
    expect(code).to eq(0)
    expect(out).to include("0 error")

    File.write(data, JSON.generate({}))
    code, out, = run_cli("check", template, "--data", data)
    expect(code).to eq(1)
    expect(out).to include("data has no field 'name'")
  end

  it "render 缺字段时返回 1,--no-strict 时返回 0 并告警" do
    template = build_text_template
    out = File.join(@dir, "out.pptx")

    code, = run_cli("render", template, "--out", out)
    expect(code).to eq(1)

    code, _stdout, err = run_cli("render", template, "--out", out, "--no-strict")
    expect(code).to eq(0)
    expect(err).to include("warning:")
    expect(slide_texts(out)).to eq([""])
  end
end
