# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "fileutils"
require "tomlrb"

# M2:{{#each}} 页面克隆 + {{#if}} 页面删除(§3.3 / §5.2)。金样本 2(循环页)。
# 注入:P9(场景页)写入循环标签 + 备注指令;P17(对比页)写入条件指令。
RSpec.describe PowerTom, ".render 页级指令" do
  fixture_dir = File.expand_path("../fixtures/hai_mate", __dir__)
  template_path = File.join(fixture_dir, "template.pptx")

  SCENARIOS = [
    { headline: "晨读材料包自动生成", detail: "每周日晚 8 点", quote: "周日备好周一用" },
    { headline: "家长会材料一键就绪", detail: "通知、议程、讲稿", quote: "不用再东拼西凑" },
    { headline: "成绩分析照着跑", detail: "上传成绩单即可", quote: "三步出报告" }
  ].freeze

  # P9 场景页正文标签(以 manifest 记录的原文定位,run 数与快照一致)
  CLONE_PAGE_LABELS = [
    { slide_no: 9, shape: "文本框 30", old_text: "每周日晚自动生成下周晨读材料包",
      runs: ["{{headline}}"] },
    { slide_no: 9, shape: "文本框 3", old_text: "放假通知、家长会材料，到点自动备好草稿",
      runs: ["{{detail}}"] },
    { slide_no: 9, shape: "圆角矩形 7", old_text: "“以前每周四处找晨读材料，现在周日晚自动备好等你”",
      runs: ["“", "{{quote}}", "”"] }
  ].freeze

  @tmp_root = nil
  before(:all) do
    skip "缺少 fixture — 放好原始 pptx 后运行 rake fixtures:generate" unless File.file?(template_path)
    @tmp_root = Dir.mktmpdir("powertom_m2")
  end
  after(:all) do
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  # def 方法看不到 describe 体内的局部变量,用 define_method 闭包捕获 template_path
  define_method(:inject) do |labels, notes = {}|
    path = File.join(@tmp_root, "labeled_#{SecureRandom.hex(6)}.pptx")
    PowerTomDev::LabelInjector.inject(template_path, path, labels, notes_assignments: notes)
  end

  def slide_count(pptx)
    PowerTom::Adapter::RubyPptxAdapter.new.open(pptx).slides.size
  end

  def page_texts(pptx, slide_no)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    adapter.paragraph_contexts(prs)
           .select { |c| c[:slide_no] == slide_no }
           .map { |c| c[:run_texts].join }
  end

  def all_texts(pptx)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    adapter.paragraph_contexts(prs).map { |c| c[:run_texts].join }
  end

  describe "{{#each}} 页面克隆" do
    it "3 个数组项克隆成 3 页,后续页顺延,迭代作用域正确" do
      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}")
      out = File.join(@tmp_root, "each_out.pptx")
      PowerTom.render(labeled, data: { scenarios: SCENARIOS }).save(out)

      aggregate_failures do
        expect(slide_count(out)).to eq(20)
        # 引号是静态文本:替换后整段并入首个 run(§5.1),前后引号保留
        expect(page_texts(out, 9)).to include("晨读材料包自动生成", "每周日晚 8 点", "“周日备好周一用”")
        expect(page_texts(out, 10)).to include("家长会材料一键就绪", "“不用再东拼西凑”")
        expect(page_texts(out, 11)).to include("成绩分析照着跑", "“三步出报告”")
        expect(page_texts(out, 12)).to include("场景二  专业备课") # 原 P10 顺延
      end
    end

    it "空数组整组删除(§8 模糊输入:应为 0 页时删掉整组)" do
      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}")
      out = File.join(@tmp_root, "each_empty.pptx")
      PowerTom.render(labeled, data: { scenarios: [] }).save(out)

      expect(slide_count(out)).to eq(17)
      expect(page_texts(out, 9)).to include("场景二  专业备课")
    end

    it "循环路径缺失时任何模式都报错(不允许静默丢页)" do
      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}")
      expect { PowerTom.render(labeled, data: {}) }
        .to raise_error(PowerTom::MissingDataError, /第 9 页.*scenarios/)
      expect { PowerTom.render(labeled, data: {}, strict: false) }
        .to raise_error(PowerTom::MissingDataError, /无法确定循环次数/)
    end

    it "循环路径不是数组时报错" do
      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}")
      expect { PowerTom.render(labeled, data: { scenarios: "老师" }) }
        .to raise_error(PowerTom::Error, /必须为数组/)
    end

    it "迭代作用域内缺失字段报错,定位到克隆后的页码" do
      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}")
      broken = SCENARIOS.dup
      broken[1] = { headline: "缺 detail 的项" }
      expect { PowerTom.render(labeled, data: { scenarios: broken }) }
        .to raise_error(PowerTom::MissingDataError, /第 10 页.*detail/)
    end

    it "作用域内字段不进未使用字段统计" do
      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}")
      items = SCENARIOS.map { |s| s.merge(only_for_others: "x") }
      result = PowerTom.render(labeled, data: { scenarios: items })
      expect(result.warnings.grep(/未被模板使用/)).to be_empty
    end
  end

  describe "{{#if}} 页面删除" do
    def inject_if
      inject([], 17 => "{{#if show_compare}}")
    end

    it "为假时删除整页" do
      out = File.join(@tmp_root, "if_false.pptx")
      PowerTom.render(inject_if, data: { show_compare: false }).save(out)

      aggregate_failures do
        expect(slide_count(out)).to eq(17)
        expect(all_texts(out)).not_to include("仅内部培训") # P17 独有文本
        expect(page_texts(out, 16)).to include("部署与服务  装就能用，有人陪跑") # 原 P16
        expect(page_texts(out, 17)).to include("更少切换") # 原 P18 顶上
      end
    end

    it "为真时整页保留" do
      out = File.join(@tmp_root, "if_true.pptx")
      PowerTom.render(inject_if, data: { show_compare: true }).save(out)
      expect(slide_count(out)).to eq(18)
    end

    it "nil 视为假(§2.2)" do
      out = File.join(@tmp_root, "if_nil.pptx")
      PowerTom.render(inject_if, data: { show_compare: nil }).save(out)
      expect(slide_count(out)).to eq(17)
    end

    it "strict 下条件路径缺失报错;strict: false 删页并记 warning" do
      expect { PowerTom.render(inject_if, data: {}) }
        .to raise_error(PowerTom::MissingDataError, /第 17 页.*show_compare/)

      result = PowerTom.render(inject_if, data: {}, strict: false)
      expect(result.warnings.join).to include("第 17 页", "show_compare")
      saved = File.join(@tmp_root, "if_missing.pptx")
      result.save(saved)
      expect(slide_count(saved)).to eq(17)
    end
  end

  describe "指令校验" do
    it "一页备注多条指令报语法错误(§3.3)" do
      labeled = inject([], 2 => "{{#each a}}\n{{#if b}}")
      expect { PowerTom.render(labeled, data: {}) }
        .to raise_error(PowerTom::TemplateSyntaxError, /只允许一条/)
    end

    it "指令缺路径报语法错误" do
      labeled = inject([], 2 => "{{#each}}")
      expect { PowerTom.render(labeled, data: {}) }
        .to raise_error(PowerTom::TemplateSyntaxError, /只支持 \{\{#each 路径\}\}/)
    end
  end

  describe "TOML 数据文件(gem 默认数据格式)" do
    it "data 传 .toml 路径即按 TOML 装载,#each 与 #if 同时生效" do
      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}", 17 => "{{#if show_compare}}")
      data_path = File.join(@tmp_root, "data.toml")
      File.write(data_path, <<~TOML)
        show_compare = false
        [[scenarios]]
        headline = "晨读材料包自动生成"
        detail = "每周日晚 8 点"
        quote = "周日备好周一用"
        [[scenarios]]
        headline = "家长会材料一键就绪"
        detail = "通知、议程、讲稿"
        quote = "不用再东拼西凑"
        [[scenarios]]
        headline = "成绩分析照着跑"
        detail = "上传成绩单即可"
        quote = "三步出报告"
      TOML

      out = File.join(@tmp_root, "toml_out.pptx")
      PowerTom.render(labeled, data: data_path).save(out)

      # 18 页 - 1(#each 克隆成 3 页 +2)- 1(#if 删 P17)= 19
      expect(slide_count(out)).to eq(19)
      expect(page_texts(out, 9)).to include("晨读材料包自动生成")
      expect(all_texts(out)).not_to include("仅内部培训")
    end

    it "非 .toml 数据文件明确报错" do
      yaml_like = File.join(@tmp_root, "data.yml")
      File.write(yaml_like, "scenarios: []")
      expect { PowerTom.render(template_path, data: yaml_like) }
        .to raise_error(PowerTom::InvalidTemplateError, /\.toml/)
    end

    it "数据文件不存在时报错" do
      expect { PowerTom.render(template_path, data: File.join(@tmp_root, "nope.toml")) }
        .to raise_error(PowerTom::InvalidTemplateError, /数据文件不存在/)
    end
  end

  context "保真验收(§5.5)" do
    it "克隆后的 deck 经 LibreOffice 转换成功且页数正确" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      labeled = inject(CLONE_PAGE_LABELS, 9 => "{{#each scenarios}}")
      out = File.join(@tmp_root, "each_out.pptx")
      PowerTom.render(labeled, data: { scenarios: SCENARIOS }).save(out)

      pdf_dir = Dir.mktmpdir("powertom_pdf")
      profile_dir = Dir.mktmpdir("powertom_lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile_dir}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, out)
      expect(ok).to be(true), "LibreOffice 转换失败"
      pdf = File.join(pdf_dir, "each_out.pdf")
      expect(File.exist?(pdf)).to be(true)
      expect(File.binread(pdf).scan(/\/Type\s*\/Page[^s]/).size).to eq(20)
    end
  end
end
