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

  # 指定页的 chart part、其内嵌 workbook part 名及 workbook 字节(spike2 深拷贝断言)
  def chart_and_workbook_ref(pptx, slide_no)
    Zip::File.open(pptx) do |zip|
      slide_rels = zip.get_input_stream("ppt/slides/_rels/slide#{slide_no}.xml.rels").read
      chart = slide_rels[%r{charts/(chart\d+\.xml)}, 1]
      chart_rels = zip.get_input_stream("ppt/charts/_rels/#{chart}.rels").read
      workbook = chart_rels[%r{embeddings/([^"]+\.xlsx)}, 1]
      {
        chart: chart,
        workbook: workbook,
        workbook_blob: zip.get_input_stream("ppt/embeddings/#{workbook}").read
      }
    end
  end

  def build_xy_chart_template
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    xy = Pptx::XyChartData.new
    series = xy.add_series("s1")
    series.add_point(1, 10)
    series.add_point(2, 20)
    frame = slide.shapes.add_chart(Pptx::Enum::XL_CHART_TYPE::XY_SCATTER, xy,
                                   at: [Pptx.inches(1), Pptx.inches(1)],
                                   size: [Pptx.inches(10), Pptx.inches(5)])
    frame.name = "powertom:chart:sales"

    path = File.join(@dir, "xy_template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def build_combo_template(notes: nil)
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    data = Pptx::ChartData.new
    data.categories = %w[Q1 Q2 Q3]
    data.add_series("Revenue", [120, 150, 180])
    data.add_series("Margin", [0.18, 0.22, 0.25])
    frame = slide.shapes.add_combo_chart(data,
                                         at: [Pptx.inches(1), Pptx.inches(1)],
                                         size: [Pptx.inches(10), Pptx.inches(5)]) do |combo|
      combo.plot :column_clustered, series: "Revenue"
      combo.plot :line, series: "Margin", secondary_axis: true
    end
    frame.name = "powertom:chart:combo"
    slide.notes = notes if notes

    path = File.join(@dir, "combo_template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  # 组合图逐 plot 读回:[[plot1 系列...], [plot2 系列...]],每个系列 [name, values]
  def read_combo(pptx, slide_no, shape_name = "powertom:chart:combo")
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    chart = adapter.find_shape(adapter.open(pptx), slide_no, shape_name).chart
    chart.plots.map { |plot| plot.series.map { |s| [s.name, s.values.map(&:to_f)] } }
  end

  def build_bubble_template
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    bubble_data = Pptx::BubbleChartData.new
    series = bubble_data.add_series("s1")
    series.add_point(1, 10, 5)
    series.add_point(2, 20, 8)
    frame = slide.shapes.add_chart(Pptx::Enum::XL_CHART_TYPE::BUBBLE, bubble_data,
                                   at: [Pptx.inches(1), Pptx.inches(1)],
                                   size: [Pptx.inches(10), Pptx.inches(5)])
    frame.name = "powertom:chart:bubble"

    path = File.join(@dir, "bubble_template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def xy_ser_xml(pptx, shape_name = "powertom:chart:sales")
    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    chart = adapter.find_shape(adapter.open(pptx), 1, shape_name).chart
    chart.element.chart.plotArea.series_elements.first.to_xml
  end

  def xy_val_pts(pptx, tag, shape_name = "powertom:chart:sales")
    xy_ser_xml(pptx, shape_name)[%r{<c:#{tag}>.*?</c:#{tag}>}m]
      .scan(%r{<c:pt idx="\d+"[^>]*><c:v>([^<]*)</c:v>}).flatten
  end

  def build_radar_template(chart_type)
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    data = Pptx::ChartData.new
    data.categories = %w[Q1 Q2 Q3]
    data.add_series("Team A", [80, 90, 85])
    data.add_series("Team B", [70, 85, 88])
    frame = slide.shapes.add_chart(chart_type, data,
                                   at: [Pptx.inches(1), Pptx.inches(1)],
                                   size: [Pptx.inches(8), Pptx.inches(5)])
    frame.name = "powertom:chart:radar"

    path = File.join(@dir, "radar_template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def build_pie_template(chart_type = Pptx::Enum::XL_CHART_TYPE::PIE)
    prs = Pptx::Presentation.new_default
    prs.slide_width = Pptx.inches(13.333)
    prs.slide_height = Pptx.inches(7.5)
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    data = Pptx::ChartData.new
    data.categories = %w[A B C]
    data.add_series("One", [1, 2, 3])
    frame = slide.shapes.add_chart(chart_type, data,
                                   at: [Pptx.inches(1), Pptx.inches(1)],
                                   size: [Pptx.inches(8), Pptx.inches(5)])
    frame.name = "powertom:chart:share"

    path = File.join(@dir, "pie_template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
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

  # spike2:同一页克隆两次,分别绑定不同数据后,chart part 与内嵌 workbook
  # 都必须各自独立;否则第二次 replace_data 会改到第一页的 workbook。
  it "spike2:克隆页深拷贝后 chart part 与内嵌 workbook 均独立" do
    template = build_chart_template(notes: "{{#each regions}}")
    out = File.join(@dir, "out_deep_copy.pptx")
    data = {
      regions: [
        { sales: { categories: %w[Jan Feb],
                   series: [{ name: "East", values: [1, 2] }] } },
        { sales: { categories: %w[Oct Nov Dec],
                   series: [{ name: "West", values: [3, 4, 5] }] } }
      ]
    }
    PowerTom.render(template, data: data).save(out)

    first = chart_and_workbook_ref(out, 1)
    second = chart_and_workbook_ref(out, 2)

    aggregate_failures do
      expect(slide_count(out)).to eq(2)
      expect(first[:chart]).not_to eq(second[:chart])
      expect(first[:workbook]).not_to eq(second[:workbook])
      expect(first[:workbook_blob]).not_to eq(second[:workbook_blob])
      expect(read_chart(out, 1)).to eq(plot_type: :BAR, categories: %w[Jan Feb],
                                       series: [["East", [1.0, 2.0]]])
      expect(read_chart(out, 2)).to eq(plot_type: :BAR, categories: %w[Oct Nov Dec],
                                       series: [["West", [3.0, 4.0, 5.0]]])
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    end
  end

  COMBO_SALES = {
    categories: %w[Jan Feb Mar],
    series: [{ name: "Rev", values: [100, 110, 120] }, { name: "Mgn", values: [0.3, 0.28, 0.26] }]
  }.freeze

  it "组合图按文档顺序整体重绑定:柱状与折线两个 plot 各自独立" do
    template = build_combo_template
    out = File.join(@dir, "out_combo.pptx")
    PowerTom.render(template, data: { combo: COMBO_SALES }).save(out)

    expect(read_combo(out, 1)).to eq(
      [[["Rev", [100.0, 110.0, 120.0]]], [["Mgn", [0.3, 0.28, 0.26]]]]
    )
    expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
  end

  it "组合图系列数不匹配 → 报错说明模板分布与文档顺序要求" do
    template = build_combo_template
    too_many = { categories: %w[Jan Feb Mar],
                 series: COMBO_SALES[:series] + [{ name: "Extra", values: [1, 2, 3] }] }
    expect { PowerTom.render(template, data: { combo: too_many }) }
      .to raise_error(
        PowerTom::Error,
        /chart template draws column×1 \+ line×1 \(2 series in total\).*exactly 2 series.*got 3/
      )
  end

  it "组合图 #each 克隆页各自持有独立 chart part 并绑定本项数据" do
    template = build_combo_template(notes: "{{#each regions}}")
    out = File.join(@dir, "out_combo_each.pptx")
    data = {
      regions: [
        { combo: COMBO_SALES },
        { combo: { categories: %w[X Y],
                   series: [{ name: "Rev", values: [1, 2] }, { name: "Mgn", values: [0.1, 0.2] }] } }
      ]
    }
    PowerTom.render(template, data: data).save(out)

    aggregate_failures do
      expect(slide_count(out)).to eq(2)
      expect(read_combo(out, 1)).to eq([[["Rev", [100.0, 110.0, 120.0]]], [["Mgn", [0.3, 0.28, 0.26]]]])
      expect(read_combo(out, 2)).to eq([[["Rev", [1.0, 2.0]]], [["Mgn", [0.1, 0.2]]]])
      expect(chart_part_ref(out, 1)).not_to eq(chart_part_ref(out, 2))
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

  # 主题 minor 字体改成指定值(模拟中文环境演示文稿,如等线),供 workbook
  # 字体断言用
  def rewrite_theme_latin(path, typeface)
    tmp = "#{path}.tmp"
    Zip::File.open(path) do |src|
      Zip::OutputStream.open(tmp) do |out|
        src.entries.each do |entry|
          next if entry.directory?

          out.put_next_entry(entry.name)
          content = entry.get_input_stream.read
          if entry.name == "ppt/theme/theme1.xml"
            content = content.sub(%r{<a:minorFont>.*?</a:minorFont>}m) do |minor|
              minor.sub(/(<a:latin typeface=")[^"]*(")/, "\\1#{typeface}\\2")
            end
          end
          out.write(content)
        end
      end
    end
    FileUtils.mv(tmp, path)
  end

  # 绑定产物内嵌 workbook 的基础字体名(xl/styles.xml 唯一的 font 节点)
  # 注意:rubyzip 的 open_buffer 返回 zip 对象而非块值,须在块内取值
  def workbook_base_font(pptx)
    Zip::File.open(pptx) do |zip|
      xlsx = zip.entries.map(&:name).find { |n| n.match?(%r{ppt/embeddings/.*\.xlsx\z}) }
      font = nil
      Zip::File.open_buffer(zip.get_input_stream(xlsx).read) do |inner|
        font = inner.get_input_stream("xl/styles.xml").read[/<name val="([^"]*)"/, 1]
      end
      font
    end
  end

  it "重建的内嵌 workbook 基础字体跟随演示文稿主题(编辑数据不再突兀)" do
    template = build_chart_template
    rewrite_theme_latin(template, "DengXian")
    out = File.join(@dir, "out_font.pptx")
    PowerTom.render(template, data: { sales: SALES }).save(out)

    expect(workbook_base_font(out)).to eq("DengXian")
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

  it "散点图绑定:按 points 重写 xVal/yVal,系列名与坐标逐点落入缓存" do
    template = build_xy_chart_template
    out = File.join(@dir, "out_xy.pptx")
    PowerTom.render(template, data: { sales: { series: [{ name: "G1", points: [{ x: 1, y: 10 }, { x: 2, y: 20 }] }] } })
            .save(out)

    ser = xy_ser_xml(out)
    aggregate_failures do
      expect(ser).to include(">G1<")
      expect(xy_val_pts(out, "xVal")).to eq(%w[1 2])
      expect(xy_val_pts(out, "yVal")).to eq(%w[10 20])
      expect(ser).not_to include("<c:val>")
      expect(ser).not_to include("<c:cat>")
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    end
  end

  it "散点图系列数不匹配 → 报错说明模板分布" do
    template = build_xy_chart_template
    data = { sales: { series: [
      { name: "A", points: [{ x: 1, y: 1 }] },
      { name: "B", points: [{ x: 2, y: 2 }] }
    ] } }
    expect { PowerTom.render(template, data: data) }
      .to raise_error(PowerTom::Error,
                      /chart template draws scatter×1 \(1 series in total\).*exactly 1 series.*got 2/)
  end

  it "散点图误传 categories → 明确报错指向 points" do
    template = build_xy_chart_template
    data = { sales: { categories: %w[A B], series: [{ name: "G1", points: [{ x: 1, y: 10 }] }] } }
    expect { PowerTom.render(template, data: data) }
      .to raise_error(PowerTom::Error, %r{scatter/bubble data has no 'categories'})
  end

  it "气泡图绑定:size 进入 bubbleSize 缓存" do
    template = build_bubble_template
    out = File.join(@dir, "out_bubble.pptx")
    PowerTom.render(template,
                    data: { bubble: { series: [{ name: "B1",
                                                 points: [{ x: 1, y: 10, size: 5 }, { x: 2, y: 20, size: 8 }] }] } })
            .save(out)

    ser = xy_ser_xml(out, "powertom:chart:bubble")
    aggregate_failures do
      expect(ser).to include(">B1<")
      expect(xy_val_pts(out, "bubbleSize", "powertom:chart:bubble")).to eq(%w[5 8])
      expect(xy_val_pts(out, "xVal", "powertom:chart:bubble")).to eq(%w[1 2])
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    end
  end

  it "check:散点图数据齐全 → 无 error;缺 points → error" do
    template = build_xy_chart_template
    aggregate_failures do
      ok = PowerTom.check(template, data: { sales: { series: [{ name: "G1", points: [{ x: 1, y: 10 }] }] } })
      expect(ok.ok?).to be(true)

      bad = PowerTom.check(template, data: { sales: { series: [{ name: "G1" }] } })
      expect(bad.errors.first.message).to include("'points' must be a non-empty array")
    end
  end

  it "雷达图绑定:cat/val 模型直接可用,radarStyle 与数据更新并存" do
    template = build_radar_template(Pptx::Enum::XL_CHART_TYPE::RADAR_FILLED)
    out = File.join(@dir, "out_radar.pptx")
    PowerTom.render(template,
                    data: { radar: { categories: %w[Jan Feb Mar],
                                     series: [{ name: "Team C", values: [60, 70, 80] }] } })
            .save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    chart = adapter.find_shape(adapter.open(out), 1, "powertom:chart:radar").chart
    aggregate_failures do
      expect(chart.plot_type).to eq(:RADAR)
      expect(chart.series.map { |s| [s.name, s.values.map(&:to_f)] })
        .to eq([["Team C", [60.0, 70.0, 80.0]]])
      expect(chart.element.chart.plotArea.xpath(".//c:radarStyle").first.get("val")).to eq("filled")
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    end
  end

  it "雷达图系列增减:与柱/折线同语义(克隆/裁剪,plot 保留)" do
    template = build_radar_template(Pptx::Enum::XL_CHART_TYPE::RADAR_MARKERS)
    out = File.join(@dir, "out_radar_count.pptx")
    data = { radar: { categories: %w[Jan Feb Mar],
                      series: %w[A B C].each_with_index.map do |n, i|
                        { name: n, values: [10 + i, 20 + i, 30 + i] }
                      end } }
    PowerTom.render(template, data: data).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    chart = adapter.find_shape(adapter.open(out), 1, "powertom:chart:radar").chart
    aggregate_failures do
      expect(chart.series.map(&:name)).to eq(%w[A B C])
      expect(chart.plots.map { |p| [p.element.nsptag, p.series.size] }).to eq([["c:radarChart", 3]])
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    end
  end

  it "保存时图表 schema 归一化:无负数 axId,radar ser 无非法 smooth(L3 取证)" do
    template = build_radar_template(Pptx::Enum::XL_CHART_TYPE::RADAR_MARKERS)
    out = File.join(@dir, "out_normalize.pptx")
    PowerTom.render(template, data: { radar: { categories: %w[Jan Feb Mar],
                                               series: [{ name: "T", values: [1, 2, 3] }] } }).save(out)

    adapter = PowerTom::Adapter::RubyPptxAdapter.new
    xml = adapter.find_shape(adapter.open(out), 1, "powertom:chart:radar").chart.element.to_xml
    aggregate_failures do
      expect(xml.scan(/val="-\d+"/)).to be_empty
      expect(xml).not_to include("<c:smooth")
      expect(PowerTomDev::OoxmlLint.lint(out)).to be_empty
    end
  end

  it "check:雷达图数据齐全 → 无 error" do
    template = build_radar_template(Pptx::Enum::XL_CHART_TYPE::RADAR_MARKERS)
    result = PowerTom.check(template, data: { radar: { categories: %w[Jan Feb Mar],
                                                       series: [{ name: "Team C", values: [60, 70, 80] }] } })
    expect(result.ok?).to be(true)
  end

  PIE_SALES = {
    categories: %w[A B C],
    series: [{ name: "One", values: [1, 2, 3] }]
  }.freeze

  it "饼图单系列 → 正常绑定" do
    template = build_pie_template
    out = File.join(@dir, "out_pie.pptx")
    PowerTom.render(template, data: { share: PIE_SALES }).save(out)

    expect(read_chart(out, 1, "powertom:chart:share")).to eq(
      plot_type: :PIE, categories: %w[A B C], series: [["One", [1.0, 2.0, 3.0]]]
    )
  end

  it "饼图多系列 → 渲染前报错,避免静默丢弃" do
    template = build_pie_template
    data = { share: { categories: %w[A B C],
                      series: [{ name: "One", values: [1, 2, 3] },
                               { name: "Two", values: [3, 2, 1] }] } }

    expect { PowerTom.render(template, data: data) }
      .to raise_error(
        PowerTom::Error,
        /chart 'powertom:chart:share' field 'share'.*exactly 1 series, got 2.*doughnut/
      )
  end

  it "check:饼图多系列 → error;单系列 → 无 error" do
    template = build_pie_template
    bad = PowerTom.check(template, data: { share: { categories: %w[A B C],
                                                    series: [{ name: "One", values: [1, 2, 3] },
                                                             { name: "Two", values: [3, 2, 1] }] } })
    ok = PowerTom.check(template, data: { share: PIE_SALES })

    aggregate_failures do
      expect(bad.errors.first.message).to include("a pie chart plots exactly 1 series, got 2")
      expect(ok.ok?).to be(true)
    end
  end

  it "饼图 0 系列 → 由空系列校验拒绝,不触发饼图守卫" do
    template = build_pie_template
    empty = { categories: %w[A B C], series: [] }

    aggregate_failures do
      expect { PowerTom.render(template, data: { share: empty }) }
        .to raise_error(PowerTom::Error, /'series' must be a non-empty array/)

      result = PowerTom.check(template, data: { share: empty })
      messages = result.errors.map(&:message).join("\n")
      expect(messages).to include("'series' must be a non-empty array")
      expect(messages).not_to include("exactly 1 series")
    end
  end

  it "圆环图多系列仍可用(饼图守卫不外溢)" do
    template = build_pie_template(Pptx::Enum::XL_CHART_TYPE::DOUGHNUT)
    out = File.join(@dir, "out_doughnut.pptx")
    data = { share: { categories: %w[A B C],
                      series: [{ name: "One", values: [1, 2, 3] },
                               { name: "Two", values: [3, 2, 1] }] } }
    PowerTom.render(template, data: data).save(out)

    expect(read_chart(out, 1, "powertom:chart:share")[:series].map(&:first)).to eq(%w[One Two])
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

    it "组合图 check:数量匹配 → 无 error,数量不匹配 → error 带分布" do
      template = build_combo_template
      aggregate_failures do
        ok = PowerTom.check(template, data: { combo: COMBO_SALES })
        expect(ok.ok?).to be(true)

        bad = PowerTom.check(template,
                             data: { combo: { categories: %w[Jan Feb Mar],
                                              series: [{ name: "Rev", values: [1, 2, 3] }] } })
        expect(bad.errors.first.message).to include("column×1 + line×1")
        expect(bad.errors.first.message).to include("exactly 2 series")
      end
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
