# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "tomlrb"

# 第二金样本:真实成绩分析 deck(已脱敏:学校名与学生姓名替换为占位)。
# 用途:真实表格结构的行循环回归、manifest 快照对账。
RSpec.describe "金样本 fixture: score_report" do
  fixture_dir = File.expand_path("../fixtures/score_report", __dir__)
  template_path = File.join(fixture_dir, "template.pptx")
  manifest_path = File.join(fixture_dir, "manifest.toml")

  before(:all) do
    unless File.file?(template_path) && File.file?(manifest_path)
      skip "缺少 fixture — 放好脱敏 deck 后运行: " \
           "rake fixtures:generate TEMPLATE=<路径> OUT=#{fixture_dir}"
    end
    @tmp_root = Dir.mktmpdir("score_report_fixture_spec")
  end
  after(:all) do
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  it "manifest 自洽:9 页、4 张表,逐页记录与页数一致" do
    manifest = Tomlrb.load_file(manifest_path)
    aggregate_failures do
      expect(manifest["template"]["slide_count"]).to eq(9)
      expect(manifest["slides"].size).to eq(9)
      expect(manifest["slides"].count { |s| s["table_count"].to_i.positive? }).to eq(4)
    end
  end

  it "回归:manifest 与 template.pptx 的解剖结果一致" do
    manifest = Tomlrb.load_file(manifest_path)
    live = PowerTomDev::Anatomy.manifest(
      PowerTomDev::Anatomy.analyze(template_path),
      source_name: manifest["source"], generated_at: nil
    )
    aggregate_failures do
      %w[template stats slides].each do |section|
        expect(live[section]).to eq(manifest[section]),
                                 "#{section} 与 manifest.toml 不一致 — 请重跑 fixtures:generate"
      end
    end
  end

  # def 看不到 describe 体内的局部变量,用 define_method 闭包捕获 template_path
  define_method(:build_table_template) do
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(template_path)
    slide = prs.slides[3] # P4 班级成绩明细
    frame = slide.shapes.to_a.find { |s| s.respond_to?(:table?) && s.table? }
    tbl_el = frame.element.xpath("./a:graphic/a:graphicData/a:tbl").first

    # 只保留 表头 + 1 行数据 + 合计,其余班级行删除
    tbl_el.tr_list[2..8].each { |tr| tbl_el.remove(tr) }

    table = frame.table
    tags = %w[name count avg excellent pass delta rank]
    tags.each_with_index { |field, c| table.cell(1, c).text = "{{classes[].#{field}}}" }
    table.cell(2, 1).text = "{{total_students}}"

    path = File.join(@tmp_root, "table_#{SecureRandom.hex(4)}.pptx")
    adapter.save(prs, path)
    path
  end

  def read_table(pptx, slide_index)
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    frame = prs.slides[slide_index].shapes.to_a.find { |s| s.respond_to?(:table?) && s.table? }
    table = frame.table
    (0...table.rows.size).map do |r|
      (0...table.columns.size).map { |c| table.cell(r, c).text }
    end
  end

  it "真实表格上行循环:3 个班克隆 3 行,其余表不受影响" do
    template = build_table_template
    data = {
      total_students: 180,
      classes: [
        { name: "初二(1)班", count: 60, avg: "85.1", excellent: "31.2%",
          pass: "93.4%", delta: "+1.2", rank: 1 },
        { name: "初二(2)班", count: 61, avg: "80.0", excellent: "24.6%",
          pass: "88.5%", delta: "-0.5", rank: 2 },
        { name: "初二(3)班", count: 59, avg: "82.9", excellent: "28.8%",
          pass: "91.5%", delta: "+1.5", rank: 3 }
      ]
    }
    out = File.join(@tmp_root, "out.pptx")
    PowerTom.render(template, data: data).save(out)

    rows = read_table(out, 3)
    aggregate_failures do
      expect(rows.size).to eq(5) # 表头 + 3 班 + 合计
      expect(rows[0]).to eq(%w[班级 参考人数 平均分 优秀率 及格率 环比上次 排名])
      expect(rows[1][0]).to eq("初二(1)班")
      expect(rows[1][5]).to eq("+1.2")
      expect(rows[3][0]).to eq("初二(3)班")
      expect(rows[4][0]).to eq("年级合计 / 平均")
      expect(rows[4][1]).to eq("180")
      expect(read_table(out, 4).size).to eq(10) # 学科表未被改动
    end
  end

  it "改造成行循环后可被 check 正常对账" do
    template = build_table_template
    data = {
      total_students: 60,
      classes: [{ name: "初二(1)班", count: 60, avg: "85.1", excellent: "31.2%",
                  pass: "93.4%", delta: "+1.2", rank: 1 }]
    }
    result = PowerTom.check(template, data: data)
    expect(result.errors.map(&:message)).to be_empty
  end
end
