# frozen_string_literal: true

# 图表绑定预研 spike(设计文档 §5.4 / docs/chart-binding-design.md):
# 用 ruby_pptx 0.2.0 自带的 add_chart / Chart#replace_data 实测
#   1. 程序化创建带图表的 pptx;
#   2. 读取 categories / series;
#   3. replace_data 整体换数据(系列数变多 / 变少 / 分类数变化);
#   4. LibreOffice 转 PDF 验证渲染;
#   5. 重读断言图表 XML 缓存已更新。
#
#   bundle exec ruby tools/chart_binding_spike.rb [输出目录]
require "tmpdir"
require "fileutils"
require "powertom"

module PowerTomDev
  module ChartBindingSpike
    module_function

    TYPE = Pptx::Enum::XL_CHART_TYPE::COLUMN_CLUSTERED

    def original_data
      data = Pptx::ChartData.new
      data.categories = %w[Q1 Q2 Q3 Q4]
      data.add_series("2025", [12, 20, 15, 22])
      data.add_series("2026", [14, 24, 18, 26])
      data
    end

    def build_template(path)
      prs = Pptx::Presentation.new_default
      prs.slide_width = Pptx.inches(13.333)
      prs.slide_height = Pptx.inches(7.5)
      slide = prs.slides.add(prs.slide_layouts["Blank"])
      frame = slide.shapes.add_chart(TYPE, original_data,
                                     at: [Pptx.inches(1), Pptx.inches(1)],
                                     size: [Pptx.inches(10), Pptx.inches(5)])
      frame.name = "powertom:chart:sales" # 占位命名约定(与图片一致)
      prs.save(path)
      path
    end

    def rebind_data(extra: false, fewer: false)
      data = Pptx::ChartData.new(number_format: "0.0")
      data.categories = %w[Q1 Q2 Q3] # 分类数变化:4 → 3
      data.add_series("2026", [14.5, 24.0, 18.5]) # fewer 时是唯一系列(2 → 1)
      data.add_series("2027", [16.0, 21.0, 20.0]) unless fewer
      data.add_series("2028", [18.0, 23.5, 25.0]) if extra # 系列数变多:克隆末尾格式
      data
    end

    def read_chart(path)
      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(path)
      shape = adapter.find_shape(prs, 1, "powertom:chart:sales")
      chart = shape.chart
      {
        plot_type: chart.plot_type,
        categories: chart.categories.map { |c| c.respond_to?(:label) ? c.label : c },
        series: chart.series.map { |s| [s.respond_to?(:name) ? s.name : "?", s.respond_to?(:values) ? s.values : s] }
      }
    end

    def run(out_dir)
      FileUtils.mkdir_p(out_dir)
      template = File.join(out_dir, "chart_template.pptx")
      build_template(template)
      puts "== build: #{read_chart(template).inspect}"

      same = File.join(out_dir, "rebind_same.pptx")
      result_same = rebind_into(template, same, extra: false)
      puts "== rebind(same count+fewer cats): #{result_same.inspect}"

      more = File.join(out_dir, "rebind_more.pptx")
      result_more = rebind_into(template, more, extra: true)
      puts "== rebind(more series): #{result_more.inspect}"

      fewer = File.join(out_dir, "rebind_fewer.pptx")
      result_fewer = rebind_into(template, fewer, fewer: true)
      puts "== rebind(fewer series): #{result_fewer.inspect}"

      [same, more, fewer].each do |pptx|
        pdf_dir = File.join(out_dir, "pdf")
        FileUtils.mkdir_p(pdf_dir)
        profile = File.join(out_dir, "lo_profile")
        ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                    "--convert-to", "pdf", "--outdir", pdf_dir, pptx)
        puts "== soffice #{File.basename(pptx)}: #{ok ? 'OK' : 'FAILED'}"
      end
      [template, same, more]
    end

    def rebind_into(src, dst, extra: false, fewer: false)
      prs = Pptx::Presentation.open(src)
      shape = prs.slides[0].shapes.to_a.find { |s| s.name == "powertom:chart:sales" }
      chart = shape.chart
      chart.replace_data(rebind_data(extra: extra, fewer: fewer))
      prs.save(dst)
      read_chart(dst)
    end

    # PageSurgery 克隆含图表的页后,两页的 chart part 是否共享同一部件?
    # 共享则 replace_data 会同时影响所有克隆页,绑定阶段必须先深拷贝 chart part。
    def clone_sharing_check(template, out_dir)
      require "zip"
      require_relative "../lib/powertom/adapter/page_surgery"
      cloned = File.join(out_dir, "cloned_page.pptx")
      PowerTom::Adapter::PageSurgery.execute(template, cloned, [{ source: 1, iteration: nil },
                                                                { source: 1, iteration: nil }])
      rels_for = lambda do |path, slide_no|
        Zip::File.open(path) do |zip|
          xml = zip.get_input_stream("ppt/slides/_rels/slide#{slide_no}.xml.rels").read
          xml[%r{charts/(chart\d+\.xml)}, 1]
        end
      end
      shared = rels_for.call(cloned, 1) == rels_for.call(cloned, 2)
      puts "== clone: slide1->#{rels_for.call(cloned, 1)} slide2->#{rels_for.call(cloned, 2)} shared=#{shared}"
      shared
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || File.join(Dir.mktmpdir("chart_spike"))
  PowerTomDev::ChartBindingSpike.run(out)
  PowerTomDev::ChartBindingSpike.clone_sharing_check(File.join(out, "chart_template.pptx"), out)
end
