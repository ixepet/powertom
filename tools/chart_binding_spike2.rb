# frozen_string_literal: true

# 图表绑定 v0.4.x 预研 spike(设计文档 §9):实测 ruby_pptx 0.2.0 的
# replace_data 在三类扩展图表上的真实行为,为"组合图绑定 + XY 结论"取证:
#   C1 组合图(bar1+line1 次轴)同形重绑定 → 逐 plot 读回断言
#   C2 组合图系列变多(2→3)→ 克隆自最后一个 plot 的最后一个系列
#   C3 组合图系列变少(2→1)→ 空 plot 被移除(结构改变,取证用)
#   C4 组合图产物 LibreOffice 转 PDF(未装 soffice 时 SKIP)
#   X1 散点图 replace_data(XyChartData) → 预期报错(SeriesFragments 不产 xy 片段)
#   X2 散点图 replace_data(ChartData) → 预期产出 schema 非法 ser(c:val 注入
#      且残留 xVal/yVal),取证后即"XY 不能走上游 replace_data"的结论
#
#   bundle exec ruby tools/chart_binding_spike2.rb [输出目录]
require "tmpdir"
require "fileutils"
require "zip"
require "powertom"

module PowerTomDev
  module ChartBindingSpike2
    module_function

    SHAPE = "powertom:chart:combo"
    XY_SHAPE = "powertom:chart:xy"

    def combo_data
      data = Pptx::ChartData.new
      data.categories = %w[Q1 Q2 Q3]
      data.add_series("Revenue", [120, 150, 180])
      data.add_series("Margin", [0.18, 0.22, 0.25])
      data
    end

    def build_combo(path)
      prs = Pptx::Presentation.new_default
      prs.slide_width = Pptx.inches(13.333)
      prs.slide_height = Pptx.inches(7.5)
      slide = prs.slides.add(prs.slide_layouts["Blank"])
      frame = slide.shapes.add_combo_chart(combo_data,
                                           at: [Pptx.inches(1), Pptx.inches(1)],
                                           size: [Pptx.inches(10), Pptx.inches(5)]) do |combo|
        combo.plot :column_clustered, series: "Revenue"
        combo.plot :line, series: "Margin", secondary_axis: true
      end
      frame.name = SHAPE
      prs.save(path)
      path
    end

    def build_xy(path)
      prs = Pptx::Presentation.new_default
      slide = prs.slides.add(prs.slide_layouts["Blank"])
      xy = Pptx::XyChartData.new
      series = xy.add_series("s1")
      series.add_point(1, 10)
      series.add_point(2, 20)
      frame = slide.shapes.add_chart(Pptx::Enum::XL_CHART_TYPE::XY_SCATTER, xy,
                                     at: [Pptx.inches(1), Pptx.inches(1)],
                                     size: [Pptx.inches(10), Pptx.inches(5)])
      frame.name = XY_SHAPE
      prs.save(path)
      path
    end

    def adapter = @adapter ||= PowerTom::Adapter::RubyPptxAdapter.new

    def chart_of(path, shape_name, slide_no = 1)
      prs = adapter.open(path)
      adapter.find_shape(prs, slide_no, shape_name).chart
    rescue StandardError
      raise "shape #{shape_name} not found in #{path}"
    end

    # 逐 plot 读回:[[plot1 系列...], [plot2 系列...]],每个系列 [name, values]。
    # 值做精度截断(4 位小数),避免浮点噪声干扰断言
    def read_plots(path, shape_name)
      chart = chart_of(path, shape_name)
      chart.plots.map { |plot| plot.series.map { |s| [s.name, s.values.map { |v| v.to_f.round(4) }] } }
    end

    def rebind(src, dst, data)
      chart = chart_of(src, SHAPE)
      chart.replace_data(data)
      chart.part.package.save(dst)
    end

    def run(out_dir)
      FileUtils.mkdir_p(out_dir)
      template = File.join(out_dir, "combo_template.pptx")
      build_combo(template)
      puts "== combo template built (bar1 + line1 secondary axis)"

      # C1 同形重绑定
      same = File.join(out_dir, "combo_same.pptx")
      data = Pptx::ChartData.new
      data.categories = %w[Jan Feb Mar]
      data.add_series("Rev2", [100, 110, 120])
      data.add_series("Mgn2", [0.30, 0.28, 0.26])
      rebind(template, same, data)
      plots = read_plots(same, SHAPE)
      expected = [[["Rev2", [100.0, 110.0, 120.0]]], [["Mgn2", [0.30, 0.28, 0.26]]]]
      raise "C1 FAILED: plots mismatch: #{plots.inspect}" unless plots == expected

      puts "== C1 rebind same shape: plot1=#{plots[0].size} ser, plot2=#{plots[1].size} ser OK"

      # C2 系列变多 2→3:克隆自最后 plot 的最后系列(line)
      more = File.join(out_dir, "combo_more.pptx")
      data3 = Pptx::ChartData.new
      data3.categories = %w[Jan Feb Mar]
      data3.add_series("Rev2", [100, 110, 120])
      data3.add_series("Mgn2", [0.30, 0.28, 0.26])
      data3.add_series("Mgn3", [0.31, 0.29, 0.27])
      rebind(template, more, data3)
      plots3 = read_plots(more, SHAPE)
      unless plots3.map(&:size) == [1, 2]
        raise "C2 FAILED: expected plot sizes [1, 2], got #{plots3.map(&:size).inspect}"
      end

      puts "== C2 rebind 2->3: bar keeps 1, line clones to 2 OK"

      # C3 系列变少 2→1:空 plot 被移除(组合图退化为纯柱状图)
      fewer = File.join(out_dir, "combo_fewer.pptx")
      data1 = Pptx::ChartData.new
      data1.categories = %w[Jan Feb Mar]
      data1.add_series("Rev2", [100, 110, 120])
      rebind(template, fewer, data1)
      plots1 = read_plots(fewer, SHAPE)
      raise "C3 unexpected: line plot should be removed, plots=#{plots1.inspect}" unless plots1.size == 1

      puts "== C3 rebind 2->1: line plot REMOVED (chart degraded to bar) — evidence for exact-count rule"

      # X1 散点图 + XyChartData:预期上游不支持
      xy = File.join(out_dir, "xy_template.pptx")
      build_xy(xy)
      xy_data = Pptx::XyChartData.new
      s = xy_data.add_series("s2")
      s.add_point(3, 30)
      s.add_point(4, 40)
      begin
        chart = chart_of(xy, XY_SHAPE)
        chart.replace_data(xy_data)
        puts "== X1 replace_data(XyChartData) unexpectedly SUCCEEDED — investigate"
      rescue StandardError => e
        puts "== X1 replace_data(XyChartData) raises #{e.class}: #{e.message.to_s[0, 120]}"
      end

      # X2 散点图 + ChartData:取证 ser 的非法结构(c:val 注入 + xVal/yVal 残留)
      broken = File.join(out_dir, "xy_broken.pptx")
      cat_data = Pptx::ChartData.new
      cat_data.categories = %w[A B]
      cat_data.add_series("s2", [30, 40])
      begin
        chart = chart_of(xy, XY_SHAPE)
        chart.replace_data(cat_data)
        chart.part.package.save(broken)
        ser_xml = Zip::File.open(broken) do |z|
          z.get_input_stream("ppt/charts/chart1.xml").read[%r{<c:ser>.*?</c:ser>}m]
        end
        has_val = ser_xml.include?("<c:val>")
        keeps_xy = ser_xml.include?("<c:xVal>")
        puts "== X2 replace_data(ChartData) on scatter: ser has c:val=#{has_val}, stale c:xVal=#{keeps_xy}"
        puts "   (xVal=true & val=true ⇒ schema-invalid ser; upstream replace_data unusable for XY)"
      rescue StandardError => e
        puts "== X2 replace_data(ChartData) raises #{e.class}: #{e.message.to_s[0, 120]}"
      end

      # C4 LibreOffice 保真(未装 soffice 时 SKIP)
      if system("sh", "-c", "command -v soffice > /dev/null")
        profile = File.join(out_dir, "lo_profile")
        pdf_dir = File.join(out_dir, "pdf")
        FileUtils.mkdir_p(pdf_dir)
        ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                    "--convert-to", "pdf", "--outdir", pdf_dir, same)
        puts ok ? "== C4 soffice convert combo_same: OK" : "== C4 soffice convert combo_same: FAILED"
      else
        puts "== C4 soffice not found in PATH: SKIP"
      end

      [template, same, more, fewer]
    end

    RADAR_SHAPE = "powertom:chart:radar"

    def build_radar(path, chart_type, one_series: false)
      prs = Pptx::Presentation.new_default
      slide = prs.slides.add(prs.slide_layouts["Blank"])
      data = Pptx::ChartData.new
      data.categories = %w[Q1 Q2 Q3]
      data.add_series("Team A", [80, 90, 85])
      data.add_series("Team B", [70, 85, 88]) unless one_series
      frame = slide.shapes.add_chart(chart_type, data,
                                     at: [Pptx.inches(1), Pptx.inches(1)],
                                     size: [Pptx.inches(8), Pptx.inches(5)])
      frame.name = RADAR_SHAPE
      prs.save(path)
      path
    end

    def radar_chart(path)
      chart_of(path, RADAR_SHAPE)
    end

    def read_radar(path)
      chart = radar_chart(path)
      chart.series.map { |s| [s.name, s.values.map { |v| v.to_f.round(4) }] }
    end

    # 雷达图评估(R1-R4,用户评审场景):radar 本质是折线变种,单 plot + cat/val
    # 模型,预期 replace_data 直接可用且无组合图的结构性风险
    def run_radar(out_dir)
      FileUtils.mkdir_p(out_dir)

      # R1 filled 同形重绑:radarStyle 必须保留,数据更新
      filled = File.join(out_dir, "radar_filled.pptx")
      build_radar(filled, Pptx::Enum::XL_CHART_TYPE::RADAR_FILLED, one_series: true)
      chart = radar_chart(filled)
      data = Pptx::ChartData.new
      data.categories = %w[Jan Feb Mar]
      data.add_series("Team C", [60, 70, 80])
      chart.replace_data(data)
      prs = chart.part.package
      prs.save(filled)
      style = radar_chart(filled).element.chart.plotArea
                                 .xpath(".//c:radarChart/c:radarStyle").first&.get("val")
      read = read_radar(filled)
      raise "R1 FAILED: radarStyle=#{style.inspect}, read=#{read.inspect}" unless
        style == "filled" && read == [["Team C", [60.0, 70.0, 80.0]]]

      puts "== R1 filled same-shape rebind: radarStyle=filled kept, data updated OK"

      # R2 系列增减:纯 c:ser 增删,单 plot 不受影响
      markers = File.join(out_dir, "radar_markers.pptx")
      build_radar(markers, Pptx::Enum::XL_CHART_TYPE::RADAR_MARKERS)
      chart = radar_chart(markers)
      more = Pptx::ChartData.new
      more.categories = %w[Jan Feb Mar]
      %w[A B C].each_with_index { |n, i| more.add_series(n, [10 + i, 20 + i, 30 + i]) }
      chart.replace_data(more)
      chart.part.package.save(markers)
      more_read = read_radar(markers)
      raise "R2 more FAILED: #{more_read.inspect}" unless more_read.size == 3

      one = Pptx::ChartData.new
      one.categories = %w[Jan Feb Mar]
      one.add_series("Only", [90, 95, 92])
      chart.replace_data(one)
      chart.part.package.save(markers)
      plots = radar_chart(markers).plots.map { |p| [p.element.nsptag, p.series.size] }
      raise "R2 fewer FAILED: plot changed: #{plots.inspect}" unless plots == [["c:radarChart", 1]]

      puts "== R2 series 2->3 clone / 2->1 trim: c:radarChart plot stays, pure ser add/remove OK"

      # R3 径向轴最大值:replace_data 只动 cat/val,valAx scaling 必须原样继承
      scaled = File.join(out_dir, "radar_scaled.pptx")
      build_radar(scaled, Pptx::Enum::XL_CHART_TYPE::RADAR_MARKERS)
      chart = radar_chart(scaled)
      chart.value_axis.maximum_scale = 100
      chart.part.package.save(scaled)
      small = Pptx::ChartData.new
      small.categories = %w[Jan Feb Mar]
      small.add_series("Tiny", [5, 12, 20])
      radar_chart(scaled).replace_data(small)
      prs2 = radar_chart(scaled).part.package
      prs2.save(scaled)
      max = radar_chart(scaled).value_axis.maximum_scale
      raise "R3 FAILED: maximum_scale reset to #{max.inspect}" unless (max.to_f - 100.0).abs < 1e-9

      puts "== R3 radial axis max=100 preserved after rebinding data max=20 OK"

      # R4 nil 值取证:上游跳过 pt 但保留 ptCount(空档语义);
      # powertom 的数据形状校验(values 全 Numeric)本来就拒绝 nil,与柱/折线一致
      nils = File.join(out_dir, "radar_nil.pptx")
      build_radar(nils, Pptx::Enum::XL_CHART_TYPE::RADAR_MARKERS)
      chart = radar_chart(nils)
      nil_data = Pptx::ChartData.new
      nil_data.categories = %w[Jan Feb Mar]
      nil_data.add_series("Gap", [1, nil, 3])
      chart.replace_data(nil_data)
      chart.part.package.save(nils)
      ser_xml = radar_chart(nils).element.chart.plotArea.series_elements.first.to_xml
      pts = ser_xml[%r{<c:val>.*?</c:val>}m]
      kept = pts.include?('<c:pt idx="0">') && !pts.include?('<c:pt idx="1">') && pts.include?('<c:pt idx="2">')
      puts "== R4 nil value: pt idx=1 omitted, idx=0/2 kept, ptCount intact=#{kept ? 'OK' : 'CHECK'} (gap semantics)"

      # C5 LibreOffice 保真(未装 soffice 时 SKIP)
      if system("sh", "-c", "command -v soffice > /dev/null")
        profile = File.join(out_dir, "lo_profile")
        pdf_dir = File.join(out_dir, "pdf_radar")
        FileUtils.mkdir_p(pdf_dir)
        ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                    "--convert-to", "pdf", "--outdir", pdf_dir, markers)
        puts ok ? "== C5 soffice convert radar_markers: OK" : "== C5 soffice convert radar_markers: FAILED"
      else
        puts "== C5 soffice not found in PATH: SKIP"
      end
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || File.join(Dir.mktmpdir("chart_binding_spike2"))
  PowerTomDev::ChartBindingSpike2.run(out)
  PowerTomDev::ChartBindingSpike2.run_radar(out)
end
