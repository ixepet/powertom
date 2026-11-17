# frozen_string_literal: true

require_relative "scanner"

module PowerTom
  # 表格行/列循环的纯逻辑部分:根据表格单元格文本生成展开计划。
  #
  # 三种语法(设计见 docs/表格循环语法设计.md):
  #   L0  {{数组[].字段}}              单级行循环(一张表一个循环行)
  #   L1  {{#rows 路径}} 标记行        两级嵌套:父行 → 子行
  #   L2  {{#grid rows: .. cols: ..}}  动态列:首列固定,列按 cols 克隆
  #
  # plan 返回 nil 表示该表没有循环;结构错误抛 TemplateSyntaxError。
  module TableLoop
    # 行标记必须整格只有这一条标签
    MARKER_RE = /\A\{\{\s*#rows\s+([A-Za-z0-9_\[\]\.]+)\s*\}\}\z/.freeze

    module_function

    # rows: [[cell_text, ...], ...]
    # merged_rows: [bool](该行是否含合并单元格)
    # columns: 表格列数(nil → 不校验 grid 的两列模板约束)
    # 返回 nil / {kind: :simple, ...} / {kind: :nested, ...} / {kind: :grid, ...}
    def plan(rows, merged_rows: [], columns: nil)
      grid_markers = collect_grid_markers(rows)
      row_markers = collect_row_markers(rows)

      if !grid_markers.empty? && !row_markers.empty?
        raise TemplateSyntaxError,
              "表格第 #{grid_markers.first[:row] + 1} 行:同一张表不能混用 {{#grid}} 与 {{#rows}}"
      end
      return grid_plan(rows, grid_markers, merged_rows, columns) unless grid_markers.empty?
      return simple_plan(rows, merged_rows) if row_markers.empty?

      nested_plan(rows, row_markers, merged_rows)
    end

    # 文本里出现的循环数组根路径(如 "classes[].name" → "classes")
    def loop_roots(text)
      text.to_s.scan(Scanner::TAG_RE).filter_map do |tag|
        raw = tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
        next if raw.start_with?("#")

        path = raw.split(":", 2).first
        path.split("[]", 2).first if path.include?("[]")
      end
    end

    # ---- L0:简单行循环 ----

    def simple_plan(rows, merged_rows)
      found = {}
      rows.each_with_index do |cells, index|
        roots = cells.flat_map { |text| loop_roots(text) }.uniq
        next if roots.empty?

        if roots.size > 1
          raise TemplateSyntaxError,
                "表格第 #{index + 1} 行包含多个循环数组(#{roots.join('、')}),一行只允许一个"
        end
        unless found.empty?
          first = found.keys.first + 1
          raise TemplateSyntaxError,
                "一张表只支持一个行循环:第 #{first} 行已是循环行,第 #{index + 1} 行又出现"
        end

        found[index] = roots.first
      end
      return nil if found.empty?

      row, root = found.first
      if merged_rows[row]
        raise TemplateSyntaxError,
              "表格第 #{row + 1} 行:循环区域包含合并单元格,请先拆分(设计文档 §7)"
      end
      { kind: :simple, row: row, root: root }
    end

    # ---- L1:两级嵌套 ----

    # 收集 {{#rows 路径}} 标记行,并校验标记本身的写法
    def collect_row_markers(rows)
      rows.each_with_index.filter_map do |cells, index|
        tags = cells.each_with_index.flat_map do |text, col|
          directive_tags(text).reject { |tag| grid_tag?(tag) }
                              .map { |tag| { col: col, tag: tag } }
        end
        next nil if tags.empty?

        validate_marker_row!(cells, index, tags)
        { row: index, path: tags.first[:tag][MARKER_RE, 1] }
      end
    end

    def validate_marker_row!(cells, index, tags)
      line = "表格第 #{index + 1} 行"
      if tags.size > 1
        raise TemplateSyntaxError,
              "#{line}包含 #{tags.size} 条行指令,一行只允许一条 {{#rows 路径}}"
      end

      col = tags.first[:col]
      tag = tags.first[:tag]
      unless col.zero? && cells[col].to_s.strip == tag
        raise TemplateSyntaxError, "#{line}:#{tag} 行标记必须独占首列单元格"
      end
      if cells.each_with_index.any? { |text, c| c != col && !text.to_s.strip.empty? }
        raise TemplateSyntaxError, "#{line}:#{tag} 行标记必须独占一行,其余单元格请留空"
      end

      path = tag[MARKER_RE, 1]
      unless path
        raise TemplateSyntaxError, "#{line}:#{tag} 行标记不合法,应为 {{#rows 路径}}"
      end

      check_marker_path!(path, line, tag)
    end

    def check_marker_path!(path, line, tag)
      if path.scan("[]").size > 1
        raise TemplateSyntaxError,
              "#{line}:#{tag} 堆叠层级超过 2 级,只支持「父级 → 子级」两层"
      end
      return unless path.match?(/\[\d+\]/)

      raise TemplateSyntaxError, "#{line}:#{tag} 行标记路径不支持下标,请用数组名 + []"
    end

    def nested_plan(rows, markers, merged_rows)
      if markers.size > 2
        raise TemplateSyntaxError,
              "表格第 #{markers[2][:row] + 1} 行:堆叠层级超过 2 级(一张表最多父级 + 子级)"
      end

      parent = markers.first
      if parent[:path].include?("[]")
        raise TemplateSyntaxError,
              "表格第 #{parent[:row] + 1} 行:{{#rows #{parent[:path]}}} 前缺少父行标记(父级路径不带 [])"
      end

      parent_content = content_row_after(rows, markers, parent, "父")
      if markers.size == 1
        raise TemplateSyntaxError,
              "表格第 #{parent[:row] + 1} 行:只有父行标记 {{#rows #{parent[:path]}}},缺少子行标记;" \
              "单级循环请直接用 {{#{parent[:path]}[].字段}}"
      end

      child = markers[1]
      relative = child_relative_path!(parent, child)
      if child[:row] <= parent_content
        raise TemplateSyntaxError,
              "表格第 #{child[:row] + 1} 行:子行标记必须写在父行内容行(第 #{parent_content + 1} 行)之后"
      end
      child_content = content_row_after(rows, markers, child, "子")

      check_merged!(merged_rows, [parent[:row], parent_content, child[:row], child_content])
      check_no_mixed_loops!(rows, markers, [parent_content, child_content])

      parent_prefix = "#{parent[:path]}[]"
      child_prefix = "#{child[:path]}[]"
      check_level_labels!(rows[parent_content], [parent_prefix], parent_content)
      check_level_labels!(rows[child_content], [parent_prefix, child_prefix], child_content)

      {
        kind: :nested,
        parent: { marker: parent[:row], content: parent_content,
                  path: parent[:path], prefix: parent_prefix },
        child: { marker: child[:row], content: child_content,
                 path: child[:path], prefix: child_prefix, relative: relative }
      }
    end

    # 标记行后必须紧跟一行内容行(且不能是另一条标记)
    def content_row_after(rows, markers, marker, level)
      content = marker[:row] + 1
      if content >= rows.size
        raise TemplateSyntaxError,
              "表格第 #{marker[:row] + 1} 行:#{level}行标记后缺少内容行"
      end
      if markers.any? { |m| m[:row] == content }
        raise TemplateSyntaxError,
              "表格第 #{marker[:row] + 1} 行:#{level}行标记后必须紧跟内容行,不能紧跟另一条行标记"
      end
      content
    end

    # 子标记路径必须是 父级[] + "." + 相对字段(允许点路径,但只允许一个 [])
    def child_relative_path!(parent, child)
      prefix = "#{parent[:path]}[]"
      relative = child[:path].delete_prefix("#{prefix}.")
      return relative if child[:path] != prefix && child[:path].start_with?("#{prefix}.") && !relative.empty?

      raise TemplateSyntaxError,
            "表格第 #{child[:row] + 1} 行:子行标记 {{#rows #{child[:path]}}} 必须以 #{prefix} 开头" \
            "(如 {{#rows #{prefix}.items}})"
    end

    def check_merged!(merged_rows, rows)
      row = rows.find { |index| merged_rows[index] }
      return unless row

      raise TemplateSyntaxError, "表格第 #{row + 1} 行:循环区域包含合并单元格,请先拆分(设计文档 §7)"
    end

    # 有 #rows 标记时,其余行不能再出现 [] 标签(两种语法不混用)
    def check_no_mixed_loops!(rows, markers, content_rows)
      rows.each_with_index do |cells, index|
        next if content_rows.include?(index) || markers.any? { |m| m[:row] == index }
        next if cells.none? { |text| loop_roots(text).any? }

        raise TemplateSyntaxError,
              "表格第 #{index + 1} 行:同一张表不能混用 {{#rows}} 标记与 {{数组[].字段}} 行循环"
      end
    end

    # 内容行里的 [] 标签必须指向本行已展开的层级(子行可引用父级字段)
    def check_level_labels!(cells, prefixes, row_index)
      cells.each do |text|
        label_paths(text).each do |path|
          next unless path.include?("[]")

          match = prefixes.select { |prefix| path == prefix || path.start_with?("#{prefix}.") }
                          .max_by(&:length)
          next if match && path.scan("[]").size == match.scan("[]").size

          expected = prefixes.map { |prefix| "{{#{prefix}.字段}}" }.join(" 或 ")
          raise TemplateSyntaxError,
                "表格第 #{row_index + 1} 行:{{#{path}}} 与循环数组不匹配(当前行应为 #{expected})"
        end
      end
    end

    # ---- L2:动态列 ----

    def collect_grid_markers(rows)
      rows.each_with_index.filter_map do |cells, index|
        tags = cells.each_with_index.flat_map do |text, col|
          directive_tags(text).select { |tag| grid_tag?(tag) }
                              .map { |tag| { col: col, tag: tag } }
        end
        next nil if tags.empty?

        validate_grid_row!(index, tags)
        { row: index, col: tags.first[:col],
          args: parse_grid_args(tags.first[:tag], index) }
      end
    end

    def validate_grid_row!(index, tags)
      line = "表格第 #{index + 1} 行"
      if tags.size > 1
        raise TemplateSyntaxError, "#{line}包含 #{tags.size} 条 grid 标记,一行只允许一条"
      end
      return if tags.first[:col].zero?

      raise TemplateSyntaxError, "#{line}:#{tags.first[:tag]} grid 标记必须放在表头行首列"
    end

    # {{#grid rows: 数组 cols: 数组 [value: 行内字段]}}
    def parse_grid_args(tag, row_index)
      line = "表格第 #{row_index + 1} 行"
      raw = tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
      body = raw.sub(/\A#grid/, "")
      args = {}
      pos = 0
      while pos < body.length
        m = body.match(/\G\s*(rows|cols|value)\s*:\s*([A-Za-z0-9_\.]+)\s*/, pos)
        unless m
          raise TemplateSyntaxError,
                "#{line}:#{tag} grid 标记写法不合法," \
                "应为 {{#grid rows: 数组 cols: 数组 [value: 字段]}}"
        end
        key = m[1].to_sym
        raise TemplateSyntaxError, "#{line}:#{tag} grid 参数重复:#{m[1]}" if args.key?(key)

        args[key] = m[2]
        pos = m.end(0)
      end
      %i[rows cols].each do |key|
        next if args[key]

        raise TemplateSyntaxError, "#{line}:#{tag} grid 标记缺少 #{key}: 参数"
      end
      args
    end

    def grid_plan(rows, markers, merged_rows, columns)
      if markers.size > 1
        raise TemplateSyntaxError,
              "表格第 #{markers[1][:row] + 1} 行:一张表只允许一个 grid 标记" \
              "(第 #{markers.first[:row] + 1} 行已声明)"
      end

      marker = markers.first
      line = "表格第 #{marker[:row] + 1} 行"
      if columns && columns != 2
        raise TemplateSyntaxError,
              "#{line}:grid 表只支持两列模板(首列行标题 + 第二列数据模板),当前 #{columns} 列"
      end
      if marker[:row] + 1 >= rows.size
        raise TemplateSyntaxError, "#{line}:grid 标记后缺少内容行"
      end

      content = marker[:row] + 1
      if merged_rows.any?
        row = merged_rows.index(true)
        raise TemplateSyntaxError, "表格第 #{row + 1} 行:grid 循环不支持合并单元格,请先拆分"
      end

      check_grid_no_loop_labels!(rows)
      check_grid_header_labels!(rows[marker[:row]], marker[:row])
      check_grid_content_labels!(rows[content], content)

      {
        kind: :grid,
        grid: { header: marker[:row], content: content,
                rows_path: marker[:args][:rows],
                cols_path: marker[:args][:cols],
                value_path: marker[:args][:value] }
      }
    end

    def check_grid_no_loop_labels!(rows)
      rows.each_with_index do |cells, index|
        next if cells.none? { |text| loop_roots(text).any? }

        raise TemplateSyntaxError,
              "表格第 #{index + 1} 行:同一张表不能混用 {{#grid}} 与 {{数组[].字段}} 行循环"
      end
    end

    # 表头数据列只允许 {{col.字段}}(列模板)
    def check_grid_header_labels!(cells, row_index)
      cells.each_with_index do |text, col|
        next if col.zero?

        label_paths(text).each do |path|
          next if path == "col" || path.start_with?("col.")

          raise TemplateSyntaxError,
                "表格第 #{row_index + 1} 行第 #{col + 1} 列:{{#{path}}} 不属于 grid 表头作用域" \
                "(应为 {{col.字段}})"
        end
      end
    end

    # 内容行:首列是行标题({{row.字段}}),其余列可用 {{row.*}} / {{col.*}} / {{cell}}
    def check_grid_content_labels!(cells, row_index)
      cells.each_with_index do |text, col|
        label_paths(text).each do |path|
          allowed = if col.zero?
                      !(path == "cell" || path == "col" || path.start_with?("col."))
                    else
                      path == "cell" || path == "row" || path.start_with?("row.") ||
                        path == "col" || path.start_with?("col.")
                    end
          next if allowed

          scope = col.zero? ? "首列只能写 {{row.字段}} 或整页字段" : "数据列应为 {{row.字段}} / {{col.字段}} / {{cell}}"
          raise TemplateSyntaxError,
                "表格第 #{row_index + 1} 行第 #{col + 1} 列:{{#{path}}} 不属于 grid 内容行作用域(#{scope})"
        end
      end
    end

    # ---- 文本工具 ----

    def directive_tags(text)
      text.to_s.scan(Scanner::TAG_RE).select do |tag|
        tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s.start_with?("#")
      end
    end

    def grid_tag?(tag)
      tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s.start_with?("#grid")
    end

    # 单元格里可绑定的标签路径(去掉 formatter 与 # 指令)
    def label_paths(text)
      text.to_s.scan(Scanner::TAG_RE).filter_map do |tag|
        raw = tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
        next if raw.start_with?("#")

        raw.split(":", 2).first
      end
    end
  end
end
