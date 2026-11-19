# frozen_string_literal: true

require "ruby_pptx"
require "tempfile"
require "zip"

module PowerTom
  module Adapter
    # 设计文档 §4:适配层是唯一 import ruby_pptx 的模块。
    # 上游 0.x API 变动时,改动被封在这个文件里。
    class RubyPptxAdapter
      def open(path)
        Pptx::Presentation.open(path)
      rescue StandardError => e
        raise InvalidTemplateError, "cannot open template (#{e.class}: #{e.message})"
      end

      # 遍历全部幻灯片的文本段落(组合形状递归展开)。
      # 返回 [{slide_no:, shape:, paragraph:, run_texts:}]
      def paragraph_contexts(prs)
        contexts = []
        prs.slides.each_with_index do |slide, i|
          slide_no = i + 1
          each_text_shape(slide.shapes) do |shape|
            shape.text_frame.paragraphs.each do |paragraph|
              runs = paragraph.runs
              next if runs.empty?

              contexts << {
                slide_no: slide_no,
                shape: shape.name,
                paragraph: paragraph,
                run_texts: runs.map(&:text)
              }
            end
          end
        end
        contexts
      end

      # §5.1 写回:按下标设置每个 run 的文本。文本数组长度必须与现有 run 数一致,
      # run 节点本身不动(保留 rPr 样式引用)。
      def write_paragraph_runs(paragraph, texts)
        runs = paragraph.runs
        if texts.size != runs.size
          raise Error,
                "write-back failed: run count mismatch (existing #{runs.size}, passed #{texts.size})"
        end

        runs.each_with_index { |run, i| run.text = texts[i] }
      end

      # §6 保存:先做图表 schema 归一化(补偿上游 writer 缺陷),再写盘
      def save(prs, path)
        normalize_chart_quirks(prs)
        prs.save(path)
        path
      end

      # 上游图表 writer 的两个缺陷(L3 OpenXmlValidator 首跑取证,ruby_pptx
      # 0.3.0 仍未修复):
      # 1. 轴 id 常量是负数(如 VAL_AX_ID="-2112772216"),而 axId 的 schema
      #    约束是 MaxInclusive 2147483647(ST_DrawingElementId 实际按非负有界
      #    int32 校验,不是 uint32)—— LibreOffice/PowerPoint 宽容,官方校验器
      #    拒绝;把全部 c:axId/c:crossAx 的负值取绝对值(上游负数都大于
      #    -2^31,abs 后合法且图表内引用自洽)。
      # 2. RadarChartWriter 给每个 ser 写 c:smooth,但 radar ser 的 schema
      #    没有该子元素 —— 直接移除。
      #
      # 这是适配层的兼容护城河:架构不能假设底层库永远输出正确,上游修复前
      # 不得删除。上游发布修复版本后,先升级并用 L3 验证,再按版本门控
      # (如 Gem::Version.new(Pptx::VERSION) < Gem::Version.new("<fixed>")),
      # 最后才在后续大版本里标记 Deprecated 并移除。
      def normalize_chart_quirks(prs)
        prs.slides.each do |slide|
          walk_shapes(slide.shapes) do |shape|
            next unless shape.respond_to?(:chart?) && shape.chart?

            normalize_chart_element(shape.chart.element)
          end
        end
      end

      def normalize_chart_element(chart_el)
        chart_el.xpath(".//c:axId | .//c:crossAx").each do |el|
          val = el.get("val").to_i
          el.set("val", val.abs.to_s) if val.negative?
        end
        chart_el.xpath(".//c:radarChart//c:ser/c:smooth").each do |smooth|
          smooth.parent.remove(smooth)
        end
        chart_el
      end

      # 备注文本(§3.3:v0 不渲染备注,只用于发现其中的标签并记 warning)。
      # 返回 [{slide_no:, text:}];无备注页返回空串。
      def notes_texts(prs)
        prs.slides.each_with_index.map do |slide, i|
          { slide_no: i + 1, text: slide.notes.to_s }
        end
      rescue StandardError
        # 备注读取异常不影响正文渲染(v0 备注只做检查)
        []
      end

      # 图片占位上下文:形状 name 或 alt text 符合 powertom:image:字段名 约定(§5.3)
      # 返回 [{slide_no:, shape:, field:, mode:, mode_error:, placeholder:,
      #        slide:, picture:}]
      # 占位语法:powertom:image:<field>[; mode=fill|contain],默认 fill
      def picture_contexts(prs)
        contexts = []
        prs.slides.each_with_index do |slide, i|
          walk_shapes(slide.shapes) do |shape|
            next unless shape.is_a?(Pptx::Picture)

            spec = image_spec(shape)
            next unless spec

            contexts << { slide_no: i + 1, shape: shape.name, field: spec[:field],
                          mode: spec[:mode], mode_error: spec[:error],
                          placeholder: "#{IMAGE_FIELD_PREFIX}#{spec[:raw]}",
                          slide: slide, picture: shape }
          end
        end
        contexts
      end

      # 图片比例与占位形状差异(超过阈值时返回比例信息,用于温和告警)
      def image_aspect_mismatch(picture, image_path, threshold: 0.2)
        image = Pptx::Image.from_file(image_path)
        return nil if image.vector?

        native = image.native_size
        image_width = native[0].emu
        image_height = native[1].emu
        shape_width = picture.width&.emu
        shape_height = picture.height&.emu
        return nil unless image_width && image_height && shape_width && shape_height
        return nil unless shape_width.positive? && shape_height.positive?

        image_ratio = image_width.to_f / image_height
        shape_ratio = shape_width.to_f / shape_height
        diff = (image_ratio - shape_ratio).abs / shape_ratio
        return nil if diff <= threshold

        { image_ratio: image_ratio, shape_ratio: shape_ratio, diff: diff }
      end

      # 图表里的模板标签(v0 不绑定图表数据,只用于温和告警)
      def chart_tags(prs)
        list = []
        prs.slides.each_with_index do |slide, i|
          walk_shapes(slide.shapes) do |shape|
            next unless shape.respond_to?(:chart?) && shape.chart?

            tags = shape.chart.element.to_xml.to_s.scan(/\{\{[^{}]*\}\}/).uniq
            next if tags.empty?

            list << { slide_no: i + 1, shape: shape.name, tags: tags }
          end
        end
        list
      rescue StandardError
        []
      end

      # §5.4 图表数据绑定:形状 name 或 alt text = powertom:chart:字段名 的图表
      # 即为占位(docs/chart-binding-design.md)。返回 [{slide_no:, shape:, field:,
      # slide:, chart_shape:, kind:}] ;kind 为绘图类型(combo 图返回 :combo);
      # combo 额外携带 series_count/distribution,供绑定层做数量守卫
      def chart_contexts(prs)
        contexts = []
        prs.slides.each_with_index do |slide, i|
          walk_shapes(slide.shapes) do |shape|
            next unless shape.respond_to?(:chart?) && shape.chart?

            field = chart_field(shape)
            next unless field

            kind = chart_kind(shape.chart)
            entry = { slide_no: i + 1, shape: shape.name, field: field,
                      slide: slide, chart_shape: shape, kind: kind }
            if %i[combo XY BUBBLE].include?(kind)
              entry[:series_count] = chart_series_count(shape.chart)
              entry[:distribution] = chart_distribution_label(shape.chart)
            end
            contexts << entry
          end
        end
        contexts
      end

      # 支持绑定数据的图表 kind:普通绘图类型(bar 覆盖柱形/条形;radar 同走
      # cat/val 模型,spike2 R1-R4 实测直接可用)、:combo 与 XY 家族(:XY 散点 /
      # :BUBBLE 气泡,适配层自行重写 xVal/yVal/bubbleSize,上游 replace_data
      # 不能绑它们——spike2 取证)。
      SUPPORTED_CHART_KINDS = %i[BAR LINE AREA PIE DOUGHNUT RADAR combo XY BUBBLE].freeze

      # plot_type 只描述第一个 plot,combo 图会被误判成它的首个类型,
      # 所以先数 plot 数量(访问链与上游 Chart#plot_area 一致)
      def chart_kind(chart)
        plots = chart.element.chart.plotArea.plot_elements
        return :combo if plots.size > 1

        chart.plot_type || :unknown
      end

      # 判定与文案是模板层规则,check(validator)以类方法复用,不持有实例
      def self.unsupported_chart_kind?(kind)
        !SUPPORTED_CHART_KINDS.include?(kind)
      end

      def self.unsupported_chart_kind_label(kind)
        { unknown: "unknown" }.fetch(kind, kind.to_s.downcase)
      end

      PLOT_FAMILY_LABELS = { "c:barChart" => "column", "c:lineChart" => "line",
                             "c:areaChart" => "area", "c:area3DChart" => "area",
                             "c:radarChart" => "radar",
                             "c:scatterChart" => "scatter", "c:bubbleChart" => "bubble" }.freeze

      # 各 plot 的系列分布,如 "column×1 + line×1" / "scatter×1"
      # (错误定位与校验消息用)
      def chart_distribution_label(chart)
        chart.element.chart.plotArea.plot_elements.map do |plot|
          "#{PLOT_FAMILY_LABELS.fetch(plot.nsptag, plot.nsptag)}×#{plot.ser_list.size}"
        end.join(" + ")
      end

      # 全部 plot 的系列总数(绑定数据必须恰好提供这么多系列:
      # combo 数量不匹配会让上游 trim/clone 静默增删 plot 破坏结构)
      def chart_series_count(chart)
        chart.element.chart.plotArea.plot_elements.sum { |plot| plot.ser_list.size }
      end

      CHART_FIELD_PREFIX = "powertom:chart:"

      def chart_field(shape)
        name = shape.name.to_s
        return name.delete_prefix(CHART_FIELD_PREFIX) if name.start_with?(CHART_FIELD_PREFIX)

        descr = chart_alt_text(shape)
        return descr.delete_prefix(CHART_FIELD_PREFIX) if descr&.start_with?(CHART_FIELD_PREFIX)

        nil
      end

      def chart_alt_text(shape)
        cnv_pr = shape.element.xpath("./p:nvGraphicFramePr/p:cNvPr").first
        cnv_pr&.get("descr")
      rescue StandardError
        nil
      end

      # 把整个数据集写入该图表占位。克隆页共享同一 chart part(spike 实测
      # shared=true),绑定前为该形状深拷贝独立 part,再 replace_data;
      # value: {categories:, series: [{name:, values:}], number_format:}
      # 散点/气泡:{series: [{name:, points: [{x:, y:(, size:)}]}]},
      # ruby_pptx 0.3.0 起上游 replace_data 直接支持 XyChartData/BubbleChartData
      # (重写 c:tx/c:xVal/c:yVal/c:bubbleSize 并重建内嵌 workbook)
      def replace_chart_data(prs, shape, slide, value)
        chart = shape.chart
        if chart_part_shared?(prs, chart.part)
          new_part = clone_chart_part(chart.part)
          rewire_chart_rel(slide, shape, new_part)
          chart = new_part.chart
        end

        kind = chart_kind(chart)
        if %i[XY BUBBLE].include?(kind)
          chart.replace_data(build_xy_chart_data(value, bubble: kind == :BUBBLE))
        else
          data = Pptx::ChartData.new(number_format: part_value(value, "number_format") || "General")
          data.categories = part_value(value, "categories")
          part_value(value, "series").each do |s|
            data.add_series(part_value(s, "name").to_s, part_value(s, "values"))
          end
          chart.replace_data(data)
        end
        harmonize_workbook_font(chart.part)
      rescue StandardError => e
        raise PowerTom::Error,
              "chart data binding failed (#{shape.name}): #{e.class} #{e.message}"
      end

      # 散点/气泡数据:{series: [{name:, points: [{x:, y:(, size:)}]}]}
      def build_xy_chart_data(value, bubble:)
        xy = (bubble ? Pptx::BubbleChartData : Pptx::XyChartData)
             .new(number_format: part_value(value, "number_format") || "General")
        part_value(value, "series").each do |s|
          series = xy.add_series(part_value(s, "name").to_s)
          part_value(s, "points").each do |point|
            if bubble
              series.add_point(part_value(point, "x"), part_value(point, "y"), part_value(point, "size"))
            else
              series.add_point(part_value(point, "x"), part_value(point, "y"))
            end
          end
        end
        xy
      end

      # 绑定会重建内嵌 workbook,上游 writer 只在含日期分类时才写 styles.xml
      # 且把基础字体写死为 Calibri(workbook_writer);其余情况根本没有
      # styles.xml,Excel 打开"编辑数据"时回退到本地默认字体,与演示文稿
      # 主题不一致。按 PowerPoint 自产 workbook 的做法补齐:基础字体取
      # 主题 minorFont(与图表文本所见一致)。取不到主题或结构对不上时
      # 保持原样(尽力而为,不影响绑定本身)。
      def harmonize_workbook_font(chart_part)
        rel = chart_part.rels.each_value.find do |r|
          !r.external? && r.reltype == Pptx::Opc::RELATIONSHIP_TYPE::PACKAGE
        end
        workbook = rel&.target_part
        return unless workbook.is_a?(Pptx::Opc::Part)

        font = theme_minor_font_name(chart_part.package)
        return unless font

        patched = rebuild_workbook_base_font(workbook.blob, font)
        workbook.blob = patched if patched
      end

      # 主题 minorFont 的 latin 字体名(空或 "+mn-lt" 占位时退回 ea)。
      # xlsx 的 <name> 是单值,PowerPoint 自产 workbook 也写 latin 名。
      def theme_minor_font_name(package)
        theme = package.parts.find { |part| part.partname.to_s[/theme\d+\.xml\z/] }
        return nil unless theme

        minor = theme.element.xpath(".//a:minorFont").first
        return nil unless minor

        latin = minor.xpath("./a:latin").first&.get("typeface")
        ea = minor.xpath("./a:ea").first&.get("typeface")
        [latin, ea].compact.find { |name| !name.to_s.empty? && !name.start_with?("+") }
      end

      BASE_FONT_NAME_RE = %r{<name val="Calibri"/>}
      STYLES_CT = "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"
      STYLES_RT = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"

      # 两种情形:已有 styles.xml(含日期)→ 就地替换基础字体名;
      # 没有 → 注入最小 styles.xml + content-type Override + workbook 关系。
      # 结构对不上时返回 nil,调用方保持原样
      def rebuild_workbook_base_font(blob, font_name)
        src = Tempfile.new(["powertom_wb_src", ".xlsx"])
        dst = Tempfile.new(["powertom_wb_dst", ".xlsx"])
        begin
          File.binwrite(src.path, blob)
          done = false
          Zip::File.open(src.path) do |zip|
            has_styles = zip.entries.any? { |entry| entry.name == "xl/styles.xml" }
            Zip::OutputStream.open(dst.path) do |out|
              zip.entries.each do |entry|
                next if entry.directory?

                out.put_next_entry(entry.name)
                content = entry.get_input_stream.read
                case entry.name
                when "xl/styles.xml"
                  content = content.sub(BASE_FONT_NAME_RE) do |_match|
                    done = true
                    %(<name val="#{font_name}"/>)
                  end
                when "xl/_rels/workbook.xml.rels"
                  unless has_styles
                    new_rel = "<Relationship Id=\"#{next_workbook_rid(content)}\" " \
                              "Type=\"#{STYLES_RT}\" Target=\"styles.xml\"/>"
                    content = content.sub("</Relationships>",
                                          "#{new_rel}</Relationships>")
                  end
                when "[Content_Types].xml"
                  unless has_styles
                    content = content.sub(
                      "</Types>",
                      %(<Override PartName="/xl/styles.xml" ContentType="#{STYLES_CT}"/></Types>)
                    )
                  end
                end
                out.write(content)
              end
              unless has_styles
                out.put_next_entry("xl/styles.xml")
                out.write(injected_styles_xml(font_name))
                done = true
              end
            end
          end
          done ? File.binread(dst.path) : nil
        ensure
          src.close!
          dst.close!
        end
      end

      def next_workbook_rid(rels_xml)
        max = rels_xml.scan(/Id="rId(\d+)"/).flatten.map(&:to_i).max || 0
        "rId#{max + 1}"
      end

      # 注入用的最小 styles.xml(无 numFmts:非日期场景没有单元格引用样式)
      def injected_styles_xml(font_name)
        <<~XML
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="1"><font><sz val="11"/><name val="#{font_name}"/></font></fonts>
          <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
          <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellXfs>
          </styleSheet>
        XML
      end

      def part_value(hash, key)
        hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]
      end

      # 该 chart part 被多个 slide 关系引用时视为共享
      def chart_part_shared?(prs, chart_part)
        refs = 0
        prs.slides.each do |slide|
          slide.part.rels.each_value do |rel|
            next if rel.external?

            refs += 1 if rel.target_part.equal?(chart_part)
          end
        end
        refs > 1
      end

      # 深拷贝 chart part:复制 chartSpace XML 并剥离 c:externalData
      # (replace_data 会为副本重建内嵌 xlsx 与外部数据链接),
      # style/colors 等其余关系按类型重接到同一目标部件。
      def clone_chart_part(part)
        blob = part.element.to_xml.to_s.sub(EXTERNAL_DATA_RE, "")
        new_part = Pptx::Parts::ChartPart.load(
          part.package.next_partname(Pptx::Parts::ChartPart::PARTNAME_TEMPLATE),
          Pptx::Opc::CONTENT_TYPE::DML_CHART, part.package, blob
        )
        part.rels.each_value do |rel|
          next if rel.external? || rel.reltype == Pptx::Opc::RELATIONSHIP_TYPE::PACKAGE

          new_part.relate_to(rel.target_part, rel.reltype)
        end
        new_part
      end

      EXTERNAL_DATA_RE = %r{<c:externalData\b[^>]*(?:/>|>.*?</c:externalData>)}m

      # 把 slide 上该形状的 c:chart 关系重接到新 chart part。
      # relate_to 只会新增关系,所以旧关系必须在改写 r:id 后 drop 掉
      # (XmlPart#drop_rel 按引用计数保护),否则 rels 里会残留指向原
      # chart part 的 stale 引用,共享判定与 save 的关系图遍历都会被带偏。
      def rewire_chart_rel(slide, shape, new_part)
        chart_el = shape.element.xpath(".//c:chart").first
        old_rid = chart_el&.get("r:id")
        new_rid = slide.part.relate_to(new_part, Pptx::Opc::RELATIONSHIP_TYPE::CHART)
        chart_el&.set("r:id", new_rid)
        slide.part.drop_rel(old_rid) if old_rid && old_rid != new_rid
      end

      # §5.3 图片替换:get_or_add 新 image part(按内容 sha1 去重,扩展名/content type
      # 由 ruby_pptx 按真实图片类型维护),repoint blip 引用。
      # image_source: 文件路径 String,或 {data:, extension:}(AssetResolver 返回字节)
      # fill:填满形状、居中裁切;contain:等比缩放到形状内、居中留边。
      # SVG 等矢量图没有原生像素尺寸,contain 保持原几何,fill 不做裁切。
      def replace_image(slide, picture, image_source, mode: :fill)
        image_path, temp = materialize_image(image_source)
        _image_part, r_id = slide.part.get_or_add_image_part(image_path)
        pic_el = picture.element
        pic_el.blip.embed = r_id
        image = Pptx::Image.from_file(image_path)
        if mode == :contain
          fit_image_inside(picture, image)
        elsif !image.vector?
          view = [picture.width, picture.height]
          if view[0] && view[1]
            # crop_to_fit 只关心比例;Length 没有 to_f,传 EMU 裸值
            native = image.native_size
            pic_el.crop_to_fit([native[0].emu, native[1].emu],
                               [view[0].emu, view[1].emu])
          end
        end
        true
      rescue StandardError => e
        raise PowerTom::Error,
              "picture replacement failed (#{image_label(image_source)}): #{e.class} #{e.message}"
      ensure
        temp&.close!
      end

      # AssetResolver 的字节结果落到临时文件,ruby_pptx 的图片 part 按真实类型识别
      def materialize_image(source)
        return [source, nil] if source.is_a?(String)

        data = part_value(source, "data")
        extension = part_value(source, "extension").to_s
        unless data.is_a?(String) && !data.empty?
          raise PowerTom::Error, "asset resolver must return a file path or {data:, extension:} with binary data"
        end
        unless extension.match?(/\A[a-zA-Z0-9]{2,5}\z/)
          raise PowerTom::Error, "asset resolver image extension is invalid: #{extension.inspect}"
        end

        temp = Tempfile.new(["powertom_image", ".#{extension}"])
        temp.binmode
        temp.write(data)
        temp.close
        [temp.path, temp]
      end

      def image_label(source)
        source.is_a?(String) ? File.basename(source) : "asset"
      end

      # contain:按 min(宽比, 高比) 缩放,居中写入 picture 的 xfrm,并清掉旧裁切。
      # 边距露出的是图片后面的内容(幻灯片背景或其它形状),这里不合成背景填充。
      def fit_image_inside(picture, image)
        return if image.vector?

        native = image.native_size
        left = picture.left&.emu
        top = picture.top&.emu
        width = picture.width&.emu
        height = picture.height&.emu
        return unless [left, top, width, height].none?(&:nil?)
        return unless width.positive? && height.positive?

        image_width = native[0].emu
        image_height = native[1].emu
        scale = [width.to_f / image_width, height.to_f / image_height].min
        fitted_width = (image_width * scale).round
        fitted_height = (image_height * scale).round

        picture.left = Pptx::Length.emu(left + ((width - fitted_width) / 2))
        picture.top = Pptx::Length.emu(top + ((height - fitted_height) / 2))
        picture.width = Pptx::Length.emu(fitted_width)
        picture.height = Pptx::Length.emu(fitted_height)
        picture.element.xpath("./p:blipFill").first&.remove_all("a:srcRect")
      end

      # 逐页形状名(含组合内、含无文本形状),用于模板结构自检。
      # 返回 [{slide_no:, names: [String]}]
      def shape_names_by_slide(prs)
        prs.slides.each_with_index.map do |slide, i|
          names = []
          walk_shapes(slide.shapes) { |shape| names << shape.name }
          { slide_no: i + 1, names: names }
        end
      end

      # 母版与版式上的文本形状(用于发现写在母版/版式上的标签)。
      # 返回 [{container:, shape:, text:}]
      def container_texts(prs)
        entries = []
        prs.slide_masters.each do |master|
          collect_container_texts(entries, master, "master")
          master.slide_layouts.each do |layout|
            collect_container_texts(entries, layout, "layout")
          end
        end
        entries
      end

      # 表格结构(表格行循环用):逐页每张表的行与单元格文本,以及合并单元格分布
      # 返回 [{slide_no:, shape:, columns:, element:, frame:, rows: [[cell_text, ...], ...],
      #        merged_rows: [bool, ...]}]
      def table_contexts(prs)
        list = []
        prs.slides.each_with_index do |slide, i|
          walk_shapes(slide.shapes) do |shape|
            next unless shape.respond_to?(:table?) && shape.table?

            table = shape.table
            list << {
              slide_no: i + 1,
              shape: shape.name,
              columns: table.columns.size,
              element: table_element(shape),
              frame: shape.element,
              rows: table.rows.map { |row| row.cells.map { |cell| cell.text.to_s } },
              merged_rows: table.rows.map do |row|
                row.cells.any? { |cell| cell.merge_origin? || cell.spanned? }
              end
            }
          end
        end
        list
      end

      # 克隆第 row_index 行为 count 份(插在原位置),再删除模板行;
      # 同步 graphicFrame 高度,避免行数变化后被外框裁剪。
      def expand_table_row(table_element, frame_element, row_index, count)
        template = table_element.tr_list[row_index]
        count.times { template.add_previous_sibling(table_element.import(template)) }
        table_element.remove(template)
        sync_table_height(table_element, frame_element)
        true
      end

      # 两级嵌套展开:每个父项先输出一行父内容行,随后输出它的子内容行。
      # child_counts: [每个父项的子数组长度]
      # 模板中的父/子标记行与内容行在展开后全部删除。
      def expand_table_rows_nested(table_element, frame_element, plan, child_counts)
        trs = table_element.tr_list
        parent_marker = trs[plan[:parent][:marker]]
        parent_content = trs[plan[:parent][:content]]
        child_marker = trs[plan[:child][:marker]]
        child_content = trs[plan[:child][:content]]

        child_counts.each do |count|
          parent_marker.add_previous_sibling(table_element.import(parent_content))
          count.times { parent_marker.add_previous_sibling(table_element.import(child_content)) }
        end

        [parent_marker, parent_content, child_marker, child_content].each do |tr|
          table_element.remove(tr)
        end
        sync_table_height(table_element, frame_element)
        true
      end

      # 动态列(#grid):首列固定,第二列是列模板;按 column_count 克隆
      # a:gridCol 与每一行的第二个 a:tc,再删除模板列。
      def expand_grid_columns(table_element, frame_element, column_count)
        grid = table_element.xpath("./a:tblGrid").first
        template_col = grid.gridCol_list[1]
        column_count.times { template_col.add_previous_sibling(grid.import(template_col)) }
        grid.remove(template_col)

        table_element.tr_list.each do |tr|
          template_cell = tr.tc_list[1]
          column_count.times { template_cell.add_previous_sibling(tr.import(template_cell)) }
          tr.remove(template_cell)
        end
        sync_table_height(table_element, frame_element)
        true
      end

      # grid 标记只用于声明,渲染前从表头首格移除(保留同格的其他文字与首 run 样式)
      def strip_grid_marker(table_element, row_index, column_index)
        cell = table_element.tr_list[row_index].tc_list[column_index]
        strip_tags_in_cell(cell, /\{\{\s*#grid\b[^{}]*\}\}/)
        true
      end

      # 列带标记({{#cols}} / {{/cols}} / 列条件)在列克隆前移除,避免被复制到每一列
      def strip_column_markers(table_element, row_index, first_col, last_col)
        cells = table_element.tr_list[row_index].tc_list
        (first_col..last_col).each do |c|
          strip_tags_in_cell(cells[c], %r{\{\{\s*(?:#cols\b[^{}]*|/cols|#if\b[^{}]*|/if)\s*\}\}})
        end
        true
      end

      def table_row_element(table_element, row_index)
        table_element.tr_list[row_index]
      end

      # 把 [open_element, close_element] 之间的模板行整体克隆 count 份。
      # 返回每份克隆的行元素数组(按输出顺序),并删除开闭标记与模板行。
      def clone_table_row_range(table_element, open_element, close_element, count)
        trs = table_element.tr_list
        open_index = trs.index { |tr| tr.node == open_element.node }
        close_index = trs.index { |tr| tr.node == close_element.node }
        unless open_index && close_index && close_index > open_index
          raise PowerTom::Error,
                "row block marker not found (the block may already have been expanded)"
        end

        templates = ((open_index + 1)...close_index).map { |i| trs[i] }
        groups = Array.new(count) do
          templates.map { |template| open_element.add_previous_sibling(table_element.import(template)) }
        end
        ([open_element, close_element] + templates).each { |tr| table_element.remove(tr) }
        groups
      end

      # 条件区块:标记行总是删除;keep_content=false 时内容行一并删除
      def prune_table_row_range(table_element, open_element, close_element, keep_content:)
        trs = table_element.tr_list
        open_index = trs.index { |tr| tr.node == open_element.node }
        close_index = trs.index { |tr| tr.node == close_element.node }
        unless open_index && close_index && close_index > open_index
          raise PowerTom::Error,
                "conditional block marker not found (the block may already have been expanded)"
        end

        content = ((open_index + 1)...close_index).map { |i| trs[i] }
        content.each { |tr| table_element.remove(tr) } unless keep_content
        table_element.remove(open_element)
        table_element.remove(close_element)
        true
      end

      # 区块展开/裁剪后统一刷新表格高度
      def refresh_table_height(table_element, frame_element)
        sync_table_height(table_element, frame_element)
        true
      end

      # 动态列带:模板列 [first_col..last_col] 按 count 克隆(表格网格 + 每一行)
      def expand_column_band(table_element, frame_element, first_col, last_col, count)
        grid = table_element.xpath("./a:tblGrid").first
        grid_cols = grid.gridCol_list
        template_cols = (first_col..last_col).map { |i| grid_cols[i] }
        anchor = grid_cols[last_col]
        count.times do
          template_cols.each { |col| anchor.add_previous_sibling(grid.import(col)) }
        end
        template_cols.each { |col| grid.remove(col) }

        table_element.tr_list.each do |tr|
          cells = tr.tc_list
          template_cells = (first_col..last_col).map { |i| cells[i] }
          cell_anchor = cells[last_col]
          count.times do
            template_cells.each { |cell| cell_anchor.add_previous_sibling(tr.import(cell)) }
          end
          template_cells.each { |cell| tr.remove(cell) }
        end
        sync_table_height(table_element, frame_element)
        sync_table_width(table_element, frame_element)
        true
      end

      # 按原始列索引删除若干列(从右到左),用于列级条件
      def remove_table_columns(table_element, frame_element, indices)
        return true if indices.empty?

        grid = table_element.xpath("./a:tblGrid").first
        grid_cols = grid.gridCol_list
        indices.uniq.sort.reverse_each do |index|
          grid.remove(grid_cols[index])
          table_element.tr_list.each do |tr|
            tr.remove(tr.tc_list[index])
          end
        end
        sync_table_width(table_element, frame_element)
        true
      end

      # 把单元格段落里的指定标签移除(保留同格其他文字与首 run 样式)
      def strip_tags_in_cell(cell, pattern)
        cell.xpath("./a:txBody/a:p").each do |paragraph|
          runs = paragraph.xpath("./a:r")
          next if runs.empty?

          joined = runs.map { |run| run.xpath("./a:t").first&.text.to_s }.join
          next unless joined.match?(pattern)

          cleaned = joined.gsub(pattern, "").strip
          runs.each_with_index do |run, i|
            text_node = run.xpath("./a:t").first
            text_node.text = i.zero? ? cleaned : "" if text_node
          end
        end
        true
      end

      # 表格单元格里的段落(展开行之后采集,用于绑定)
      def table_cell_contexts(prs)
        list = []
        prs.slides.each_with_index do |slide, i|
          walk_shapes(slide.shapes) do |shape|
            next unless shape.respond_to?(:table?) && shape.table?

            table = shape.table
            table.rows.each_with_index do |row, r|
              row.cells.each_with_index do |cell, c|
                cell.text_frame.paragraphs.each do |paragraph|
                  runs = paragraph.runs
                  next if runs.empty?

                  list << {
                    slide_no: i + 1,
                    shape: "#{shape.name}[#{r + 1},#{c + 1}]",
                    table_shape: shape.name,
                    row_index: r,
                    col_index: c,
                    in_table: true,
                    paragraph: paragraph,
                    run_texts: runs.map(&:text)
                  }
                end
              end
            end
          end
        end
        list
      end

      # 按名称查找形状(含组合内);找不到返回 nil
      def find_shape(prs, slide_no, name)
        slide = prs.slides[slide_no - 1]
        return nil unless slide

        found = nil
        walk_shapes(slide.shapes) { |shape| found ||= shape if shape.name == name }
        found
      end

      CONDITIONAL_PREFIX = "powertom:if:"

      # 形状级条件占位:name / alt text 以 powertom:if: 开头。
      # 返回 [{slide_no:, shape:, field:, element:}],含组合形状(先父后子)
      def conditional_contexts(prs)
        list = []
        prs.slides.each_with_index do |slide, i|
          walk_all_shapes(slide.shapes) do |shape|
            field = conditional_field(shape)
            next unless field

            list << { slide_no: i + 1, shape: shape.name, field: field, element: shape.element }
          end
        end
        list
      end

      # 删除形状(含整个组合);render 在绑定前调用
      def remove_shape(element)
        element.parent&.remove(element)
      end

      private

      def walk_all_shapes(shapes, &block)
        shapes.each do |shape|
          block.call(shape)
          walk_all_shapes(shape.shapes, &block) if shape.is_a?(Pptx::GroupShape)
        end
      end

      def conditional_field(shape)
        name = shape.name.to_s
        return name.delete_prefix(CONDITIONAL_PREFIX) if name.start_with?(CONDITIONAL_PREFIX)

        descr = alt_text_of(shape)
        descr.delete_prefix(CONDITIONAL_PREFIX) if descr&.start_with?(CONDITIONAL_PREFIX)
      end

      def walk_shapes(shapes, &block)
        shapes.each do |shape|
          if shape.is_a?(Pptx::GroupShape)
            walk_shapes(shape.shapes, &block)
          else
            block.call(shape)
          end
        end
      end

      def each_text_shape(shapes, &block)
        walk_shapes(shapes) { |shape| block.call(shape) if shape.text_frame? }
      end

      IMAGE_FIELD_PREFIX = "powertom:image:"
      IMAGE_MODES = %w[fill contain].freeze

      # 从形状 name / alt text 解析图片占位;不是图片占位时返回 nil
      def image_spec(shape)
        name = shape.name.to_s
        raw = if name.start_with?(IMAGE_FIELD_PREFIX)
                name.delete_prefix(IMAGE_FIELD_PREFIX)
              else
                descr = alt_text_of(shape)
                descr.delete_prefix(IMAGE_FIELD_PREFIX) if descr&.start_with?(IMAGE_FIELD_PREFIX)
              end
        raw && parse_image_spec(raw)
      end

      # field[; mode=fill|contain];默认 fill,未知选项保留为 mode_error
      def parse_image_spec(raw)
        field, *options = raw.split(";").map(&:strip)
        mode = :fill
        error = field.empty? ? "picture placeholder has no field name" : nil
        options.each do |option|
          key, value = option.split("=", 2).map(&:strip)
          if key == "mode" && IMAGE_MODES.include?(value)
            mode = value.to_sym
          else
            error ||= "unsupported picture option '#{option}'; supported: mode=fill|contain"
          end
        end
        { field: field, mode: mode, error: error, raw: raw.strip }
      end

      def alt_text_of(shape)
        cnv_pr = shape.element.xpath("./p:nvPicPr/p:cNvPr").first
        cnv_pr&.get("descr")
      rescue StandardError
        nil
      end

      def table_element(shape)
        shape.element.xpath("./a:graphic/a:graphicData/a:tbl").first
      end

      # 表格实际高度 = 各行 h 之和;写回 graphicFrame 的 a:ext/@cy
      def sync_table_height(table_element, frame_element)
        total = table_element.tr_list.sum { |tr| tr.get("h").to_i }
        ext = frame_element.xpath("./p:xfrm/a:ext").first
        ext&.set("cy", total.to_s)
      end

      # 表格实际宽度 = 各 gridCol 的 w 之和;写回 graphicFrame 的 a:ext/@cx
      def sync_table_width(table_element, frame_element)
        total = table_element.xpath("./a:tblGrid/a:gridCol").sum { |col| col.get("w").to_i }
        ext = frame_element.xpath("./p:xfrm/a:ext").first
        ext&.set("cx", total.to_s)
      end

      def collect_container_texts(entries, container, kind)
        label = begin
          name = container.part.name
          name.nil? || name.to_s.empty? ? kind : "#{kind}『#{name}』"
        rescue StandardError
          kind
        end
        walk_shapes(container.shapes) do |shape|
          next unless shape.text_frame?

          text = shape.text_frame.text.to_s
          next unless text.include?("{{")

          entries << { container: label, shape: shape.name, text: text }
        end
      end
    end
  end
end
