# frozen_string_literal: true

require "tomlrb"
require "tmpdir"
require "fileutils"

# M1 端到端:金样本 hai_mate 上注入标签 → PowerTom.render → 重读断言 + LibreOffice 保真。
# 金样本 1(单页多标签)+ 标签跨 run 也能替换(设计文档 §6 M1 验收)。
RSpec.describe PowerTom, ".render" do
  fixture_dir = File.expand_path("../fixtures/hai_mate", __dir__)
  template_path = File.join(fixture_dir, "template.pptx")
  manifest_path = File.join(fixture_dir, "manifest.toml")

  # 注入目标以 manifest 记录的段落原文精确定位(含真实空格与 run 结构)。
  # run 数与 manifest 不一致时注入器会抛错——deck 更新后需重新生成 fixture 并同步此表。
  INJECTIONS = [
    { slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{page_title}}"] },
    { slide_no: 2, shape: "圆角矩形 4", old_text: "    工作复杂", runs: ["    {{wor", "kload}}"] },
    { slide_no: 2, shape: "文本框 5",
      old_text: "备课、分析、反思、档案和日常办公，每件事都在不同的入口、不同的工具里",
      runs: ["{{first}} 与 {{second}} 双标签"] },
    { slide_no: 5, shape: "文本框 18", old_text: "亮点一｜任务驱动的高效工作",
      runs: ["{{highlight_title}}", "", ""] },
    { slide_no: 9, shape: "圆角矩形 7", old_text: "“以前每周四处找晨读材料，现在周日晚自动备好等你”",
      runs: ["“", "{{quote}}", "”"] }
  ].freeze

  DATA = {
    page_title: "学生工作台",
    workload: "教学负担",
    first: "备课",
    second: "批改",
    highlight_title: "亮点一｜效率翻倍",
    quote: "周五的课，周日就备好"
  }.freeze

  # ---- 测试产物(每套件一次性准备)----

  tmp_root = nil
  labeled_path = nil
  out_path = nil
  rendered_warnings = nil

  before(:all) do
    skip "缺少 fixture — 放好原始 pptx 后运行 rake fixtures:generate" unless
      File.file?(template_path) && File.file?(manifest_path)

    tmp_root = Dir.mktmpdir("powertom_render_spec")
    labeled_path = File.join(tmp_root, "labeled.pptx")
    out_path = File.join(tmp_root, "out.pptx")

    # 守卫:注入表的 run 数必须与 manifest 快照一致
    manifest = Tomlrb.load_file(manifest_path)
    INJECTIONS.each do |rep|
      para = manifest["slides"][rep[:slide_no] - 1]["paragraphs"]
             .find { |p| p["text"] == rep[:old_text] }
      raise "manifest 中找不到注入目标 P#{rep[:slide_no]} #{rep[:old_text].inspect}" unless para
      expected = para["runs"] || 1
      raise "manifest run 数变化(P#{rep[:slide_no]} #{rep[:old_text].inspect}: #{expected})" if
        expected != rep[:runs].size
    end

    PowerTomDev::LabelInjector.inject(template_path, labeled_path, INJECTIONS)

    result = PowerTom.render(labeled_path, data: DATA.merge(extra_field: "未使用"))
    rendered_warnings = result.warnings
    result.save(out_path)
  end

  after(:all) do
    FileUtils.remove_entry(tmp_root) if tmp_root && File.exist?(tmp_root)
  end

  # ---- 断言工具 ----

  def paragraph_texts(pptx, slide_no)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    adapter.paragraph_contexts(prs)
           .select { |c| c[:slide_no] == slide_no }
           .map { |c| [c[:shape], c[:run_texts]] }
  end

  it "单 run 标签被替换,run 结构保持不变" do
    p2 = paragraph_texts(out_path, 2)
    title = p2.find { |shape, _| shape == "文本框 18" && !shape.start_with?("文本框 92") }
    expect(title).to eq(["文本框 18", ["学生工作台"]])
  end

  it "跨 run 标签被替换:整段并入首个 run,其余 run 清空(§5.1)" do
    p2 = paragraph_texts(out_path, 2)
    workload = p2.find { |shape, runs| shape == "圆角矩形 4" && runs.any? }
    expect(workload).to eq(["圆角矩形 4", ["    教学负担", ""]])
  end

  it "一个段落里的多个标签全部替换" do
    p2 = paragraph_texts(out_path, 2)
    pair = p2.find { |shape, runs| shape == "文本框 5" && runs.join.include?("双标签") }
    expect(pair).to eq(["文本框 5", ["备课 与 批改 双标签"]])
  end

  it "多 run 段落整体替换后首个 run 持有全文,末尾 run 保留占位" do
    p5 = paragraph_texts(out_path, 5)
    title = p5.find { |shape, _| shape == "文本框 18" }
    expect(title).to eq(["文本框 18", ["亮点一｜效率翻倍", "", ""]])
  end

  it "标签位于中间 run 时,首尾静态文本并入替换结果" do
    p9 = paragraph_texts(out_path, 9)
    quote = p9.find { |shape, runs| shape == "圆角矩形 7" && runs.any? }
    expect(quote).to eq(["圆角矩形 7", ["“周五的课，周日就备好”", "", ""]])
  end

  it "未注入的段落原样保留(对照 manifest 快照)" do
    manifest = Tomlrb.load_file(manifest_path)
    injected_old = INJECTIONS.map { |rep| rep[:old_text] }
    untouched = manifest["slides"][1]["paragraphs"]
                .map { |p| p["text"] } - injected_old
    out_texts = paragraph_texts(out_path, 2).map { |_, runs| runs.join }
    missing = untouched - out_texts
    expect(missing).to be_empty, "未注入段落丢失: #{missing.inspect}"
  end

  it "数据未使用字段记 warning(§2.3)" do
    expect(rendered_warnings).to include("数据字段 'extra_field' 未被模板使用")
  end

  context "strict 模式缺失字段" do
    it "抛 MissingDataError,信息定位到页码与标签" do
      incomplete = DATA.reject { |k, _| k == :highlight_title }
      expect { PowerTom.render(labeled_path, data: incomplete) }
        .to raise_error(PowerTom::MissingDataError, /第 5 页.*highlight_title/)
    end
  end

  context "strict: false 缺失字段" do
    it "填空字符串并记 warning" do
      incomplete = DATA.reject { |k, _| k == :highlight_title }
      result = PowerTom.render(labeled_path, data: incomplete, strict: false)
      expect(result.warnings.join).to include("第 5 页", "已填空字符串")
      saved = File.join(tmp_root || Dir.tmpdir, "strict_false_out.pptx")
      result.save(saved)
      p5 = paragraph_texts(saved, 5)
      title = p5.find { |shape, _| shape == "文本框 18" }
      expect(title).to eq(["文本框 18", ["", "", ""]])
    end
  end

  context "正文里的页级指令" do
    it "扫描阶段抛 TemplateSyntaxError,提示指令应写在备注" do
      bad = File.join(Dir.tmpdir, "bad_instruction.pptx")
      PowerTomDev::LabelInjector.inject(
        template_path, bad,
        [{ slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{#each kpis}}"] }]
      )
      expect { PowerTom.render(bad, data: {}) }
        .to raise_error(PowerTom::TemplateSyntaxError, /页级指令.*备注/)
    end

    it "formatter 语法合法且渲染生效(§3.4)" do
      labeled = File.join(Dir.tmpdir, "formatter_ok.pptx")
      PowerTomDev::LabelInjector.inject(
        template_path, labeled,
        [{ slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{price:currency}}"] }]
      )
      out = File.join(Dir.tmpdir, "formatter_out.pptx")
      PowerTom.render(labeled, data: { price: 1234567.891 }).save(out)

      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(out)
      text = adapter.paragraph_contexts(prs)
                    .find { |c| c[:slide_no] == 2 && c[:shape] == "文本框 18" }
                    .then { |c| c[:run_texts].join }
      expect(text).to eq("¥1,234,567.89")
    end

    it "未注册的 formatter 渲染时报错" do
      bad = File.join(Dir.tmpdir, "bad_formatter.pptx")
      PowerTomDev::LabelInjector.inject(
        template_path, bad,
        [{ slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{price:nope}}"] }]
      )
      expect { PowerTom.render(bad, data: { price: 1 }) }
        .to raise_error(PowerTom::Error, /未注册的 formatter 'nope'/)
    end

    it "非法路径报语法错误" do
      bad = File.join(Dir.tmpdir, "bad_path.pptx")
      PowerTomDev::LabelInjector.inject(
        template_path, bad,
        [{ slide_no: 2, shape: "文本框 18", old_text: "现状痛点", runs: ["{{foo bar}}"] }]
      )
      expect { PowerTom.render(bad, data: {}) }
        .to raise_error(PowerTom::TemplateSyntaxError, /只支持点路径与下标/)
    end
  end

  context "备注里的标签" do
    it "不渲染,记 warning" do
      noted = File.join(Dir.tmpdir, "with_notes.pptx")
      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(labeled_path)
      prs.slides[1].notes = "备注含 {{hidden_note}} 标签"
      adapter.save(prs, noted)

      result = PowerTom.render(noted, data: DATA)
      expect(result.warnings.join).to include("备注", "{{hidden_note}}")
    end
  end

  context "无效模板" do
    it "包装为 InvalidTemplateError" do
      expect { PowerTom.render(manifest_path, data: {}) }
        .to raise_error(PowerTom::InvalidTemplateError)
    end
  end

  context "保真验收(§5.5)" do
    it "LibreOffice headless 转换成功且页数正确" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      pdf_dir = Dir.mktmpdir("powertom_pdf")
      # 独立 profile,避免与用户正在使用的 LibreOffice 实例/profile 锁相互干扰(CI 标准做法)
      profile_dir = Dir.mktmpdir("powertom_lo_profile")
      ok = system(
        "soffice", "--headless",
        "-env:UserInstallation=file://#{profile_dir}",
        "--convert-to", "pdf", "--outdir", pdf_dir, out_path
      )
      pdf = File.join(pdf_dir, "out.pdf")
      expect(ok).to be(true), "LibreOffice 转换失败"
      expect(File.exist?(pdf)).to be(true)

      page_count = File.binread(pdf).scan(/\/Type\s*\/Page[^s]/).size
      expect(page_count).to eq(18)
    end
  end
end
