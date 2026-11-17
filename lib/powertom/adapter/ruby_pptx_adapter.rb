# frozen_string_literal: true

require "ruby_pptx"

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
      # 返回 [{slide_no:, shape:, field:, slide:, picture:}]
      def picture_contexts(prs)
        contexts = []
        prs.slides.each_with_index do |slide, i|
          walk_shapes(slide.shapes) do |shape|
            next unless shape.is_a?(Pptx::Picture)

            field = image_field(shape)
            next unless field

            contexts << { slide_no: i + 1, shape: shape.name, field: field,
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

      # §5.3 图片替换:get_or_add 新 image part(按内容 sha1 去重,扩展名/content type
      # 由 ruby_pptx 按真实图片类型维护),repoint blip 引用,再按"填满形状、居中裁切"
      # 设置 srcRect。SVG 等矢量图不做裁切。
      def replace_image(slide, picture, image_path)
        _image_part, r_id = slide.part.get_or_add_image_part(image_path)
        pic_el = picture.element
        pic_el.blip.embed = r_id
        image = Pptx::Image.from_file(image_path)
        unless image.vector?
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
              "picture replacement failed (#{File.basename(image_path.to_s)}): #{e.class} #{e.message}"
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

      def save(prs, path)
        prs.save(path)
      end

      private

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

      def image_field(shape)
        name = shape.name.to_s
        return name.delete_prefix(IMAGE_FIELD_PREFIX) if name.start_with?(IMAGE_FIELD_PREFIX)

        descr = alt_text_of(shape)
        return descr.delete_prefix(IMAGE_FIELD_PREFIX) if descr&.start_with?(IMAGE_FIELD_PREFIX)

        nil
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
