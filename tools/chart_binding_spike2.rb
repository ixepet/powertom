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

    # 逐 plot 读回:[[plot1 系列...], [plot2 系列...]],每个系列 [name, values]
    def read_plots(path, shape_name)
      chart = chart_of(path, shape_name)
      chart.plots.map { |plot| plot.series.map { |s| [s.name, s.values.map(&:to_f)] } }
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
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || File.join(Dir.mktmpdir("chart_binding_spike2"))
  PowerTomDev::ChartBindingSpike2.run(out)
end
