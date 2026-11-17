# frozen_string_literal: true

# L3 official validation layer: renders the deck set that the OpenXmlValidator
# (tools/openxml_validator) checks on Windows runners. Deliberately covers every
# supported chart family plus the riskiest paths — #each-cloned chart pages
# (per-page deep copy), category count changes and the mini golden surgery
# paths (§5.1-§5.4).
#
#   bundle exec ruby tools/build_l3_decks.rb <output-dir>
#
# Emits: charts_template.pptx (unbound template), charts_all.pptx (bound),
# mini_golden.pptx (bound mini golden render).
require "fileutils"
require "powertom"
require_relative File.expand_path("../spec/support/image_factory", __dir__)

module PowerTomDev
  # L3 deck set generator
  module L3Decks
    module_function

    def column_data
      { categories: %w[Q1 Q2 Q3 Q4],
        series: [{ name: "2025", values: [12, 20, 15, 22] }, { name: "2026", values: [14, 24, 18, 26] }] }
    end

    def pie_data
      { categories: %w[North South East], series: [{ name: "Share", values: [40, 35, 25] }] }
    end

    def combo_data
      { categories: %w[Q1 Q2 Q3],
        series: [{ name: "Revenue", values: [120, 150, 180] }, { name: "Margin", values: [0.18, 0.22, 0.25] }] }
    end

    # 渲染的全家族图表模板:每个受支持家族一页,#each 组合页在最后
    def build_charts_template(path)
      prs = Pptx::Presentation.new_default
      prs.slide_width = Pptx.inches(13.333)
      prs.slide_height = Pptx.inches(7.5)
      layout = prs.slide_layouts["Blank"]

      add_chart_slide(prs, layout, "column", Pptx::Enum::XL_CHART_TYPE::COLUMN_CLUSTERED, column_data)
      add_chart_slide(prs, layout, "line", Pptx::Enum::XL_CHART_TYPE::LINE, column_data)
      add_chart_slide(prs, layout, "area", Pptx::Enum::XL_CHART_TYPE::AREA, column_data)
      add_chart_slide(prs, layout, "pie", Pptx::Enum::XL_CHART_TYPE::PIE, pie_data)
      add_chart_slide(prs, layout, "doughnut", Pptx::Enum::XL_CHART_TYPE::DOUGHNUT, pie_data)
      add_chart_slide(prs, layout, "radar", Pptx::Enum::XL_CHART_TYPE::RADAR_MARKERS,
                      { categories: %w[Q1 Q2 Q3],
                        series: [{ name: "Team A", values: [80, 90, 85] }, { name: "Team B", values: [70, 85, 88] }] })
      add_chart_slide(prs, layout, "radar_filled", Pptx::Enum::XL_CHART_TYPE::RADAR_FILLED,
                      { categories: %w[Q1 Q2 Q3], series: [{ name: "Only", values: [65, 75, 70] }] })
      add_combo_slide(prs, layout, "combo", combo_data)

      scatter_slide = prs.slides.add(layout)
      xy = Pptx::XyChartData.new
      xy.add_series("Group A", points: [[1, 10], [2, 20], [3, 15]])
      xy.add_series("Group B", points: [[4, 30]])
      frame = scatter_slide.shapes.add_chart(Pptx::Enum::XL_CHART_TYPE::XY_SCATTER, xy,
                                             at: [Pptx.inches(1), Pptx.inches(1)],
                                             size: [Pptx.inches(8), Pptx.inches(5)])
      frame.name = "powertom:chart:scatter"

      bubble_slide = prs.slides.add(layout)
      bubble = Pptx::BubbleChartData.new
      bubble.add_series("B1", points: [[1, 10, 5], [2, 20, 8]])
      frame = bubble_slide.shapes.add_chart(Pptx::Enum::XL_CHART_TYPE::BUBBLE, bubble,
                                            at: [Pptx.inches(1), Pptx.inches(1)],
                                            size: [Pptx.inches(8), Pptx.inches(5)])
      frame.name = "powertom:chart:bubble"

      # #each 克隆的组合页:每项恰好 2 系列(与模板 ser 总数一致)
      run_slide = prs.slides.add(layout)
      run_slide.notes = "{{#each runs}}"
      run_data = Pptx::ChartData.new
      run_data.categories = %w[Q1 Q2 Q3]
      run_data.add_series("Rev", [1, 2, 3])
      run_data.add_series("Mgn", [0.1, 0.2, 0.3])
      frame = run_slide.shapes.add_combo_chart(run_data,
                                               at: [Pptx.inches(1), Pptx.inches(1)],
                                               size: [Pptx.inches(8), Pptx.inches(5)]) do |combo|
        combo.plot :column_clustered, series: "Rev"
        combo.plot :line, series: "Mgn", secondary_axis: true
      end
      frame.name = "powertom:chart:combo_run"

      # 走 adapter.save:保存前做图表 schema 归一化(负 axId / radar smooth)
      PowerTom::Adapter::RubyPptxAdapter.new.save(prs, path)
      path
    end

    def add_chart_slide(prs, layout, field, chart_type, data)
      slide = prs.slides.add(layout)
      chart_data = Pptx::ChartData.new
      chart_data.categories = data[:categories]
      data[:series].each { |s| chart_data.add_series(s[:name], s[:values]) }
      frame = slide.shapes.add_chart(chart_type, chart_data,
                                     at: [Pptx.inches(1), Pptx.inches(1)],
                                     size: [Pptx.inches(8), Pptx.inches(5)])
      frame.name = "powertom:chart:#{field}"
      frame
    end

    def add_combo_slide(prs, layout, field, data)
      slide = prs.slides.add(layout)
      chart_data = Pptx::ChartData.new
      chart_data.categories = data[:categories]
      data[:series].each { |s| chart_data.add_series(s[:name], s[:values]) }
      frame = slide.shapes.add_combo_chart(chart_data,
                                           at: [Pptx.inches(1), Pptx.inches(1)],
                                           size: [Pptx.inches(8), Pptx.inches(5)]) do |combo|
        combo.plot :column_clustered, series: data[:series][0][:name]
        combo.plot :line, series: data[:series][1][:name], secondary_axis: true
      end
      frame.name = "powertom:chart:#{field}"
      frame
    end

    def build(out_dir)
      FileUtils.mkdir_p(out_dir)

      # 全家族图表 deck:先存未绑定模板(模板本身也进 L3 验证),再渲染绑定
      charts_template = File.join(out_dir, "charts_template.pptx")
      build_charts_template(charts_template)
      charts_data = {
        column: column_data,
        line: column_data,
        area: column_data,
        pie: pie_data,
        doughnut: pie_data,
        radar: { categories: %w[Jan Feb Mar],
                 series: [{ name: "A2", values: [60, 70, 80] }, { name: "B2", values: [50, 60, 70] }] },
        radar_filled: { categories: %w[Jan Feb Mar], series: [{ name: "C2", values: [55, 65, 60] }] },
        combo: combo_data,
        scatter: { series: [{ name: "G1", points: [{ x: 1, y: 10 }, { x: 2, y: 20 }] },
                            { name: "G2", points: [{ x: 3, y: 15 }] }] },
        bubble: { series: [{ name: "B2", points: [{ x: 1, y: 12, size: 6 }, { x: 2, y: 22, size: 9 }] }] },
        runs: [
          { combo_run: { categories: %w[Jan Feb Mar],
                         series: [{ name: "Rev1", values: [10, 20, 30] },
                                  { name: "Mgn1", values: [0.11, 0.12, 0.13] }] } },
          { combo_run: { categories: %w[Apr May Jun],
                         series: [{ name: "Rev2", values: [40, 50, 60] },
                                  { name: "Mgn2", values: [0.21, 0.22, 0.23] }] } }
        ]
      }
      PowerTom.render(charts_template, data: charts_data).save(File.join(out_dir, "charts_all.pptx"))

      # mini golden 渲染产物(手术 + 图片 + 图表的端到端路径)
      mini_template = File.expand_path("../spec/fixtures/mini/template.pptx", __dir__)
      if File.file?(mini_template)
        cover = PowerTomDev::ImageFactory.write_png(File.join(out_dir, "cover.png"), 450, 300)
        mini_data = {
          title: "L3 Validation", split_title: "Merged", first: "A", second: "B", caption: "caption",
          items: [{ headline: "One", detail: "Detail One" }, { headline: "Two", detail: "Detail Two" }],
          show_extra: true, extra_note: "extra visible",
          sales: { categories: %w[Jan Feb],
                   series: [{ name: "2025", values: [10, 20] }, { name: "2026", values: [30, 40] }] },
          cover: cover
        }
        PowerTom.render(mini_template, data: mini_data).save(File.join(out_dir, "mini_golden.pptx"))
      end

      Dir[File.join(out_dir, "*.pptx")].each { |deck| puts "deck: #{deck}" }
      out_dir
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || "decks"
  puts "L3 decks generated: #{PowerTomDev::L3Decks.build(out)}"
end
