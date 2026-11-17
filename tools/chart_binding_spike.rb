# frozen_string_literal: true

# 图表绑定预研 spike(设计文档 §5.4 / docs/chart-binding-design.md):
# 用 ruby_pptx 0.2.0 自带的 add_chart / Chart#replace_data 实测
#   1. 程序化创建带图表的 pptx;
#   2. 读取 categories / series;
#   3. replace_data 整体换数据(系列数变多 / 变少 / 归零 / 分类数变化);
#   4. LibreOffice 转 PDF 验证渲染(未安装 soffice 时输出 SKIP);
#   5. 重读断言图表 XML 缓存已更新;
#   6. PageSurgery 克隆页后 chart part 仍共享(断言,防止结论静默失效);
#   7. 逐页深拷贝 chart part 后两页分别绑定不同数据,读回断言互不影响。
#
#   bundle exec ruby tools/chart_binding_spike.rb [输出目录]
require "tmpdir"
require "fileutils"
require "zip"
require "powertom"
require_relative "../lib/powertom/adapter/page_surgery"

module PowerTomDev
  module ChartBindingSpike
    module_function

    TYPE = Pptx::Enum::XL_CHART_TYPE::COLUMN_CLUSTERED
    SHAPE_NAME = "powertom:chart:sales"
    CHART_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"

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
      frame.name = SHAPE_NAME # 占位命名约定(与图片一致)
      prs.save(path)
      path
    end

    def rebind_data(extra: false, fewer: false, zero: false)
      data = Pptx::ChartData.new(number_format: "0.0")
      data.categories = %w[Q1 Q2 Q3] # 分类数变化:4 → 3
      return data if zero # 没有任何 series:上游 SeriesRewriter 会连 plot 一起删掉

      data.add_series("2026", [14.5, 24.0, 18.5]) # fewer 时是唯一系列(2 → 1)
      data.add_series("2027", [16.0, 21.0, 20.0]) unless fewer
      data.add_series("2028", [18.0, 23.5, 25.0]) if extra # 系列数变多:克隆末尾格式
      data
    end

    def read_chart(path, slide_no = 1)
      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(path)
      shape = adapter.find_shape(prs, slide_no, SHAPE_NAME)
      raise "chart shape #{SHAPE_NAME} not found on slide #{slide_no} of #{path}" unless shape

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

      zero = File.join(out_dir, "rebind_zero.pptx")
      result_zero = rebind_zero_into(template, zero)
      puts "== rebind(zero series): #{result_zero.inspect}"

      [same, more, fewer, zero].each { |pptx| convert_to_pdf(pptx, out_dir) }

      clone_sharing_check(template, out_dir)
      deep_copy_clone_check(template, out_dir)

      [template, same, more, fewer, zero]
    end

    def rebind_into(src, dst, extra: false, fewer: false, zero: false)
      prs = Pptx::Presentation.open(src)
      shape = prs.slides[0].shapes.to_a.find { |s| s.name == SHAPE_NAME }
      raise "chart shape #{SHAPE_NAME} not found in #{src}" unless shape

      chart = shape.chart
      chart.replace_data(rebind_data(extra: extra, fewer: fewer, zero: zero))
      prs.save(dst)
      read_chart(dst)
    end

    # 归零系列不是"空图表",上游会把 plot 元素整个删掉;绑定层必须把无 series 视为错误。
    def rebind_zero_into(src, dst)
      result = rebind_into(src, dst, zero: true)
      unless result[:plot_type].nil? && result[:series].empty?
        raise "zero-series replace_data kept the plot: #{result.inspect}"
      end

      result
    end

    def convert_to_pdf(pptx, out_dir)
      unless soffice_available?
        puts "== soffice #{File.basename(pptx)}: SKIP (soffice not found in PATH)"
        return
      end

      pdf_dir = File.join(out_dir, "pdf")
      FileUtils.mkdir_p(pdf_dir)
      profile = File.join(out_dir, "lo_profile")
      ok = system("soffice", "--headless", "-env:UserInstallation=file://#{profile}",
                  "--convert-to", "pdf", "--outdir", pdf_dir, pptx)
      puts "== soffice #{File.basename(pptx)}: #{ok ? 'OK' : 'FAILED'}"
    end

    def soffice_available?
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, "soffice"))
      end
    end

    # PageSurgery 克隆含图表的页后,两页的 chart part 是否共享同一部件?
    # 共享则 replace_data 会同时影响所有克隆页,绑定阶段必须先深拷贝 chart part。
    def clone_sharing_check(template, out_dir)
      cloned = File.join(out_dir, "cloned_page.pptx")
      PowerTom::Adapter::PageSurgery.execute(template, cloned, [{ source: 1, iteration: nil },
                                                                { source: 1, iteration: nil }])
      first = chart_partname_in(read_zip_parts(cloned), 1)
      second = chart_partname_in(read_zip_parts(cloned), 2)
      shared = first == second
      puts "== clone: slide1->#{first} slide2->#{second} shared=#{shared}"
      raise "cloned slides no longer share the chart part; spike conclusion is stale" unless shared

      shared
    end

    # spike 2:克隆 → 逐页深拷贝 chart part → 两页分别 replace_data → 读回断言独立。
    # 只有这一步能证明 docs/chart-binding-design.md §3 的深拷贝方案成立。
    def deep_copy_clone_check(template, out_dir)
      shared = File.join(out_dir, "cloned_shared.pptx")
      PowerTom::Adapter::PageSurgery.execute(template, shared, [{ source: 1, iteration: nil },
                                                                { source: 1, iteration: nil }])

      parts = read_zip_parts(shared)
      deep_copy_shared_charts(parts)
      deep = File.join(out_dir, "cloned_deepcopy.pptx")
      write_zip_parts(parts, deep)
      charts = (1..2).map { |slide_no| chart_partname_in(parts, slide_no) }
      puts "== deep copy: slide1->#{charts[0]} slide2->#{charts[1]}"

      bound = File.join(out_dir, "deepcopy_bound.pptx")
      bind_per_page(deep, bound, 1 => page_a_data, 2 => page_b_data)

      first = read_chart(bound, 1)
      second = read_chart(bound, 2)
      puts "== deep copy: slide1=#{first.inspect}"
      puts "== deep copy: slide2=#{second.inspect}"
      assert_independent!(bound, first, second)
      convert_to_pdf(bound, out_dir)
      bound
    end

    def page_a_data
      data = Pptx::ChartData.new
      data.categories = %w[Jan Feb Mar]
      data.add_series("Alpha", [1, 2, 3])
      data
    end

    def page_b_data
      data = Pptx::ChartData.new
      data.categories = %w[East West South North]
      data.add_series("Beta", [9.0, 7.0, 5.0, 3.0])
      data.add_series("Gamma", [2.0, 4.0, 6.0, 8.0])
      data
    end

    def bind_per_page(src, dst, data_by_slide)
      prs = Pptx::Presentation.open(src)
      data_by_slide.each do |slide_no, data|
        shape = prs.slides[slide_no - 1].shapes.to_a.find { |s| s.name == SHAPE_NAME }
        raise "chart shape #{SHAPE_NAME} not found on slide #{slide_no} of #{src}" unless shape

        shape.chart.replace_data(data)
      end
      prs.save(dst)
      dst
    end

    def assert_independent!(path, first, second)
      expected_first = { categories: %w[Jan Feb Mar],
                         series: [["Alpha", [1.0, 2.0, 3.0]]] }
      expected_second = { categories: %w[East West South North],
                          series: [["Beta", [9.0, 7.0, 5.0, 3.0]],
                                   ["Gamma", [2.0, 4.0, 6.0, 8.0]]] }
      unless first[:categories] == expected_first[:categories] && first[:series] == expected_first[:series]
        raise "slide 1 lost its data after slide 2 binding: #{first.inspect}"
      end
      unless second[:categories] == expected_second[:categories] && second[:series] == expected_second[:series]
        raise "slide 2 did not keep its own data: #{second.inspect}"
      end

      parts = read_zip_parts(path)
      charts = (1..2).map { |slide_no| chart_partname_in(parts, slide_no) }
      raise "chart parts are still shared: #{charts.inspect}" if charts.uniq.size != 2

      workbooks = charts.map { |chart| workbook_partname_in(parts, chart) }
      if workbooks.any?(&:nil?) || workbooks.uniq.size != 2
        raise "embedded workbooks are not per-page: #{workbooks.inspect}"
      end
      raise "embedded workbooks are identical: #{workbooks.inspect}" if parts[workbooks[0]] == parts[workbooks[1]]

      puts "== deep copy: charts=#{charts.inspect} workbooks=#{workbooks.inspect} independent"
    end

    # ---- 包级深拷贝:第一页保留原 chart part,后续引用同一部件的页各复制一份 ----

    def deep_copy_shared_charts(parts)
      next_no = parts.keys.filter_map { |name| name[%r{\Appt/charts/chart(\d+)\.xml\z}, 1]&.to_i }.max.to_i
      owner = {}
      output_slides(parts).each do |slide_no|
        chart = chart_partname_in(parts, slide_no)
        next unless chart

        if owner.key?(chart)
          next_no += 1
          new_chart = "ppt/charts/chart#{next_no}.xml"
          copy_chart_part(parts, chart, new_chart)
          repoint_slide_chart(parts, slide_no, new_chart)
        else
          owner[chart] = slide_no
        end
      end
    end

    def copy_chart_part(parts, source, target)
      # 不复制 chartN.xml.rels,并删掉 c:externalData:否则 replace_data 会顺着
      # 悬空的 rId 找到共享的旧 xlsx,而不是为这一页新建 workbook。
      xml = parts.fetch(source).dup.force_encoding(Encoding::UTF_8)
      xml = xml.sub(%r{<c:externalData\b[^>]*/>}, "")
      xml = xml.sub(%r{<c:externalData\b[^>]*>.*?</c:externalData>}m, "")
      parts[target] = xml.force_encoding(Encoding::BINARY)

      # chart 部件靠 [Content_Types].xml 的逐个 Override 声明,xml 的 Default 不够
      types = parts.fetch("[Content_Types].xml").dup.force_encoding(Encoding::UTF_8)
      types.sub!(%r{</Types>}, %(<Override PartName="/#{target}" ContentType="#{CHART_CONTENT_TYPE}"/></Types>))
      parts["[Content_Types].xml"] = types.force_encoding(Encoding::BINARY)
    end

    def repoint_slide_chart(parts, slide_no, new_chart)
      name = "ppt/slides/_rels/slide#{slide_no}.xml.rels"
      rels = parts.fetch(name).dup.force_encoding(Encoding::UTF_8)
      rels.sub!(%r{Target="\.\./charts/chart\d+\.xml"}, %(Target="../#{new_chart.delete_prefix('ppt/')}"))
      parts[name] = rels.force_encoding(Encoding::BINARY)
    end

    def chart_partname_in(parts, slide_no)
      rels = parts.fetch("ppt/slides/_rels/slide#{slide_no}.xml.rels")
      rel = rels[%r{<Relationship\b[^>]*Type="[^"]*/chart"[^>]*>}]
      return nil unless rel

      chart = rel[%r{Target="\.\./charts/(chart\d+\.xml)"}, 1]
      chart && "ppt/charts/#{chart}"
    end

    def workbook_partname_in(parts, chart_part)
      name = "ppt/charts/_rels/#{File.basename(chart_part)}.rels"
      rels = parts[name]
      return nil unless rels

      workbook = rels[%r{Target="\.\./embeddings/([^"]+)"}, 1]
      workbook && "ppt/embeddings/#{workbook}"
    end

    def output_slides(parts)
      parts.keys.filter_map { |name| name[%r{\Appt/slides/slide(\d+)\.xml\z}, 1]&.to_i }.sort
    end

    def read_zip_parts(path)
      Zip::File.open(path) do |zip|
        zip.each_with_object({}) do |entry, parts|
          parts[entry.name] = entry.get_input_stream(&:read) if entry.file?
        end
      end
    end

    def write_zip_parts(parts, path)
      Zip::OutputStream.open(path) do |zos|
        parts.each do |name, data|
          zos.put_next_entry(name)
          zos.write(data)
        end
      end
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || File.join(Dir.mktmpdir("chart_spike"))
  PowerTomDev::ChartBindingSpike.run(out)
end
