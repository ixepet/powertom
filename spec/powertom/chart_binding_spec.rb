# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "fileutils"
require "zip"
require_relative "../../tools/ooxml_lint"

# §5.4 图表数据绑定(powertom:chart:字段名):整体替换 categories/series,
# 克隆页各自持有独立 chart part,错误带定位,check 逐项对账
# (docs/chart-binding-design.md)。不依赖私有金样本。
RSpec.describe PowerTom, ".render 图表绑定" do
  around do |example|
    Dir.mktmpdir("chart_binding_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_chart_template(notes: nil)
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    data = Pptx::ChartData.new
    data.categories = %w[Q1 Q2 Q3 Q4]
    data.add_series("2025", [12, 20, 15, 22])
    data.add_series("2026", [14, 24, 18, 26])
    frame = slide.shapes.add_chart(Pptx::Enum::XL_CHART_TYPE::COLUMN_CLUSTERED, data,
                                   at: [Pptx.inches(1), Pptx.inches(1)],
                                   size: [Pptx.inches(10), Pptx.inches(5)])
    frame.name = "powertom:chart:sales"
    slide.notes = notes if notes

    path = File.join(@dir, "chart_template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def read_chart(pptx, slide_no, shape_name = "powertom:chart:sales")
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    prs = adapter.open(pptx)
    chart = adapter.find_shape(prs, slide_no, shape_name).chart
    {
      plot_type: chart.plot_type,
      categories: chart.categories.map { |c| c.respond_to?(:label) ? c.label : c },
      series: chart.series.map { |s| [s.name, s.values.map(&:to_f)] }
    }
  end

  def slide_count(pptx)
    PowerTom::Adapter::RubyPptxAdapter.new.open(pptx).slides.size
  end

  # 输出文件里指定页 slide rels 指向的 chart part 名(共享判定)
  def chart_part_ref(pptx, slide_no)
    Zip::File.open(pptx) do |zip|
      xml = zip.get_input_stream("ppt/slides/_rels/slide#{slide_no}.xml.rels").read
      xml[%r{charts/(chart\d+\.xml)}, 1]
    end
  end

  SALES = {
    categories: %w[Jan Feb Mar],
    series: [{ name: "2026", values: [10, 20, 30] }]
  }.freeze

  it "静态页整体替换 categories 与 series" do
    template = build_chart_template
    out = File.join(@dir, "out_static.pptx")
    PowerTom.render(template, data: { sales: SALES }).save(out)

    expect(read_chart(out, 1)).to eq(
      plot_type: :BAR, categories: %w[Jan Feb Mar],
      series: [["2026", [10.0, 20.0, 30.0]]]
    )
  end

  it "系列变多与变少:2→3 克隆格式,2→1 移除多余系列" do
    template = build_chart_template
    out_more = File.join(@dir, "out_more.pptx")
    more = { categories: %w[A B], series: [{ name: "a", values: [1, 2] },
                                           { name: "b", values: [3, 4] }, { name: "c", values: [5, 6] }] }
    PowerTom.render(template, data: { sales: more }).save(out_more)
    expect(read_chart(out_more, 1)[:series].map(&:first)).to eq(%w[a b c])

    out_fewer = File.join(@dir, "out_fewer.pptx")
    fewer = { categories: %w[A B], series: [{ name: "only", values: [7, 8] }] }
    PowerTom.render(template, data: { sales: fewer }).save(out_fewer)
    expect(read_chart(out_fewer, 1)[:series]).to eq([["only", [7.0, 8.0]]])
  end

  it "{{#each}} 克隆页各自绑定本项数据,chart part 互不共享" do
    template = build_chart_template(notes: "{{#each regions}}")
    out = File.join(@dir, "out_each.pptx")
    data = {
      regions: [
        { label: "East",
          sales: { categories: %w[A B], series: [{ name: "2026", values: [1, 2] }] } },
        { label: "West",
          sales: { categories: %w[X Y Z],
                   series: [{ name: "2026", values: [3, 4, 5] }, { name: "2027", values: [6, 7, 8] }] } }
      ]
    }
    PowerTom.render(template, data: data).save(out)

    aggregate_failures do
      expect(slide_count(out)).to eq(2)
      expect(read_chart(out, 1)).to eq(plot_type: :BAR, categories: %w[A B],
                                       series: [["2026", [1.0, 2.0]]])
      expect(read_chart(out, 2)).to eq(plot_type: :BAR, categories: %w[X Y Z],
                                       series: [["2026", [3.0, 4.0, 5.0]], ["2027", [6.0, 7.0, 8.0]]])
      # 深拷贝生效:两页 rels 指向不同 chart part,且部件都真实存在
      expect(chart_part_ref(out, 1)).not_to eq(chart_part_ref(out, 2))
      Zip::File.open(out) do |zip|
        [1, 2].each { |n| expect(zip.find_entry("ppt/charts/#{chart_part_ref(out, n)}")).not_to be_nil }
      end
      # 克隆 + 深拷贝 + 绑定后的包结构仍然合法(L1)
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    end
  end

  it "strict 缺失字段 → MissingDataError 带页码与字段" do
    template = build_chart_template
    expect { PowerTom.render(template, data: {}) }
      .to raise_error(PowerTom::MissingDataError, /slide 1.*sales/)
  end

  it "non-strict 缺失字段 → 保留占位图表并记 warning" do
    template = build_chart_template
    result = PowerTom.render(template, data: {}, strict: false)
    out = File.join(@dir, "out_missing.pptx")
    result.save(out)

    aggregate_failures do
      expect(result.warnings.join).to include("sales", "chart placeholder")
      expect(read_chart(out, 1)[:series].map(&:first)).to eq(%w[2025 2026]) # 占位数据原样保留
    end
  end

  it "数据形状错误 → 定位到页/形状/字段" do
    template = build_chart_template
    aggregate_failures do
      expect { PowerTom.render(template, data: { sales: "oops" }) }
        .to raise_error(PowerTom::Error,
                        /slide 1 chart 'powertom:chart:sales' field 'sales'.*'categories' and 'series'/)
      expect { PowerTom.render(template, data: { sales: { categories: [], series: SALES[:series] } }) }
        .to raise_error(PowerTom::Error, /'categories' must be a non-empty array/)
      expect { PowerTom.render(template, data: { sales: { categories: %w[A], series: [] } }) }
        .to raise_error(PowerTom::Error, /'series' must be a non-empty array/)
      expect do
        PowerTom.render(template,
                        data: { sales: { categories: %w[A B C], series: [{ name: "s", values: [1, 2] }] } })
      end.to raise_error(PowerTom::Error, /series 's' 'values' must be an array of 3 numbers/)
      expect do
        PowerTom.render(template,
                        data: { sales: { categories: %w[A], series: [{ name: "s", values: ["x"] }] } })
      end.to raise_error(PowerTom::Error, /series 's' 'values' must be an array of 1 numbers/)
    end
  end

  describe "PowerTom.check" do
    it "数据齐全 → 无 error,字段计入已使用" do
      template = build_chart_template
      result = PowerTom.check(template, data: { sales: SALES })
      aggregate_failures do
        expect(result.ok?).to be(true)
        expect(result.warnings.map(&:message).join).not_to include("'sales'")
      end
    end

    it "缺失/形状错误 → error 带页码与形状" do
      template = build_chart_template
      aggregate_failures do
        result = PowerTom.check(template, data: {})
        expect(result.errors.first.message).to include("sales")

        bad = PowerTom.check(template,
                             data: { sales: { categories: %w[A B C],
                                              series: [{ name: "s", values: [1] }] } })
        expect(bad.errors.first.message).to include("'values' must be an array of 3 numbers")
      end
    end

    it "#each 页逐项对账:缺哪项报哪项" do
      template = build_chart_template(notes: "{{#each regions}}")
      result = PowerTom.check(template, data: { regions: [
                                { sales: SALES }, {}
                              ] })
      e = result.errors.find { |x| x.message.include?("item 2") }
      expect(e.message).to include("regions[1].sales")
    end
  end

  context "保真验收(§5.5)" do
    it "绑定后的图表 deck 经 LibreOffice 转换成功" do
      skip "本机没有 soffice" unless system("sh", "-c", "command -v soffice > /dev/null")

      template = build_chart_template
      out = File.join(@dir, "out_fidelity.pptx")
      PowerTom.render(template, data: { sales: SALES }).save(out)

      pdf_dir = File.join(@dir, "pdf")
      FileUtils.mkdir_p(pdf_dir)
      profile = File.join(@dir, "lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, out)
      expect(ok).to be(true), "LibreOffice 转换失败"
      pdf = File.join(pdf_dir, "out_fidelity.pdf")
      expect(File.exist?(pdf)).to be(true)
      expect(File.binread(pdf).scan(%r{/Type\s*/Page[^s]}).size).to eq(1)
    end
  end
end
