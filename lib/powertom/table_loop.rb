# frozen_string_literal: true

require_relative "scanner"

module PowerTom
  # 表格行/列循环的纯逻辑部分:根据表格单元格文本生成展开计划。
  #
  # 三种语法(设计见 docs/table-loop-design.md):
  #   L0  {{数组[].字段}}              单级行循环(一张表一个循环行)
  #   L1  {{#rows 路径}} 标记行        两级嵌套:父行 → 子行
  #   L2  {{#grid rows: .. cols: ..}}  动态列:首列固定,列按 cols 克隆
  #
  # plan 返回 nil 表示该表没有循环;结构错误抛 TemplateSyntaxError。
  module TableLoop
    # 行标记必须整格只有这一条标签
    MARKER_RE = /\A\{\{\s*#rows\s+([A-Za-z0-9_\[\].]+)\s*\}\}\z/

    # v0.2.x 区块语法:配对行区块 + 列带(可写在行区块内,支持多列模板)
    COLS_OPEN_RE = /
      \A\{\{\s*\#cols\s+([A-Za-z0-9_.]+)
      (?:\s+value:\s*([A-Za-z0-9_.]+(?:\s*,\s*[A-Za-z0-9_.]+)*))?
      \s*\}\}\z
    /x
    IF_OPEN_RE = /\A\{\{\s*#if\s+([A-Za-z0-9_\[\].]+)\s*\}\}\z/
    MAX_BLOCK_DEPTH = 3

    module_function

    # rows: [[cell_text, ...], ...]
    # merged_rows: [bool](该行是否含合并单元格)
    # columns: 表格列数(nil → 不校验 grid 的两列模板约束)
    # 返回 nil / {kind: :simple, ...} / {kind: :nested, ...} / {kind: :grid, ...} /
    #      {kind: :blocks, blocks:, cols:}
    def plan(rows, merged_rows: [], columns: nil)
      return blocks_plan(rows, merged_rows) if block_syntax?(rows)

      grid_markers = collect_grid_markers(rows)
      row_markers = collect_row_markers(rows)

      if !grid_markers.empty? && !row_markers.empty?
        raise TemplateSyntaxError,
              "table row #{grid_markers.first[:row] + 1}: a table cannot mix {{#grid}} and {{#rows}}"
      end
      plan = if !grid_markers.empty?
               grid_plan(rows, grid_markers, merged_rows, columns)
             elsif row_markers.empty?
               simple_plan(rows, merged_rows)
             else
               nested_plan(rows, row_markers, merged_rows)
             end
      check_orphan_scope_labels!(rows) unless plan && plan[:kind] == :grid
      plan
    end

    # 没有 #grid / 区块时,row. / col. / cell 是保留作用域变量,出现即报错
    def check_orphan_scope_labels!(rows)
      rows.each_with_index do |cells, r|
        cells.each_with_index do |text, c|
          label_paths(text).each do |path|
            next unless scope_variable?(path)

            raise TemplateSyntaxError,
                  "table row #{r + 1}, column #{c + 1}: {{#{path}}} can only be used in tables with " \
                  "a {{#rows}} block or {{#grid}}"
          end
        end
      end
    end

    def scope_variable?(path)
      path == "cell" || path == "row" || path.start_with?("row.") ||
        path == "col" || path.start_with?("col.")
    end

    # 文本里出现的循环数组根路径(如 "classes[].name" → "classes");
    # 聚合标签(classes[].avg:sum)不是行循环标记,跳过
    def loop_roots(text)
      text.to_s.scan(Scanner::TAG_RE).filter_map do |tag|
        raw = tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
        next if raw.start_with?("#")

        path, spec = raw.split(":", 2)
        next if aggregator_path?(path, spec)

        path.split("[]", 2).first if path.include?("[]")
      end
    end

    def aggregator_path?(path, spec)
      path.include?("[]") && Scanner.aggregator_spec?(spec)
    end

    # ---- L0:简单行循环 ----

    def simple_plan(rows, merged_rows)
      found = {}
      rows.each_with_index do |cells, index|
        roots = cells.flat_map { |text| loop_roots(text) }.uniq
        next if roots.empty?

        if roots.size > 1
          raise TemplateSyntaxError,
                "table row #{index + 1} contains multiple loop arrays (#{roots.join(', ')}); " \
                "only one is allowed per row"
        end
        unless found.empty?
          first = found.keys.first + 1
          raise TemplateSyntaxError,
                "a table supports only one row loop: row #{first} is already a loop row, " \
                "and row #{index + 1} adds another"
        end

        found[index] = roots.first
      end
      return nil if found.empty?

      row, root = found.first
      if merged_rows[row]
        raise TemplateSyntaxError,
              "table row #{row + 1}: the loop area contains merged cells; split them first (design document §7)"
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
      line = "table row #{index + 1}"
      if tags.size > 1
        raise TemplateSyntaxError,
              "#{line} contains #{tags.size} row directives; only one {{#rows path}} is allowed per row"
      end

      col = tags.first[:col]
      tag = tags.first[:tag]
      unless col.zero? && cells[col].to_s.strip == tag
        raise TemplateSyntaxError,
              "#{line}: #{tag} row marker must occupy the first cell alone"
      end
      if cells.each_with_index.any? { |text, c| c != col && !text.to_s.strip.empty? }
        raise TemplateSyntaxError, "#{line}: #{tag} row marker must occupy the whole row; leave the other cells empty"
      end

      path = tag[MARKER_RE, 1]
      raise TemplateSyntaxError, "#{line}: #{tag} is an invalid row marker; use {{#rows path}}" unless path

      check_marker_path!(path, line, tag)
    end

    def check_marker_path!(path, line, tag)
      if path.scan("[]").size > 1
        raise TemplateSyntaxError,
              "#{line}: #{tag} nesting exceeds two levels; only parent → child is supported"
      end
      return unless path.match?(/\[\d+\]/)

      raise TemplateSyntaxError, "#{line}: #{tag} row marker paths do not support indices; use the array name + []"
    end

    def nested_plan(rows, markers, merged_rows)
      if markers.size > 2
        raise TemplateSyntaxError,
              "table row #{markers[2][:row] + 1}: nesting exceeds two levels (a table allows at most parent + child)"
      end

      parent = markers.first
      if parent[:path].include?("[]")
        raise TemplateSyntaxError,
              "table row #{parent[:row] + 1}: {{#rows #{parent[:path]}}} is missing a parent row marker " \
              "(the parent path has no [])"
      end

      parent_content = content_row_after(rows, markers, parent, "parent")
      if markers.size == 1
        raise TemplateSyntaxError,
              "table row #{parent[:row] + 1}: only the parent marker {{#rows #{parent[:path]}}} is present; " \
              "the child marker is missing. For a single-level loop use {{#{parent[:path]}[].field}} directly"
      end

      child = markers[1]
      relative = child_relative_path!(parent, child)
      if child[:row] <= parent_content
        raise TemplateSyntaxError,
              "table row #{child[:row] + 1}: the child marker must come after the parent content row " \
              "(row #{parent_content + 1})"
      end
      child_content = content_row_after(rows, markers, child, "child")

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
              "table row #{marker[:row] + 1}: the #{level} marker is missing its content row"
      end
      if markers.any? { |m| m[:row] == content }
        raise TemplateSyntaxError,
              "table row #{marker[:row] + 1}: the #{level} marker must be followed by a content row, not another marker"
      end
      content
    end

    # 子标记路径必须是 父级[] + "." + 相对字段(允许点路径,但只允许一个 [])
    def child_relative_path!(parent, child)
      prefix = "#{parent[:path]}[]"
      relative = child[:path].delete_prefix("#{prefix}.")
      return relative if child[:path] != prefix && child[:path].start_with?("#{prefix}.") && !relative.empty?

      raise TemplateSyntaxError,
            "table row #{child[:row] + 1}: child marker {{#rows #{child[:path]}}} must start with #{prefix} " \
            "(for example {{#rows #{prefix}.items}})"
    end

    def check_merged!(merged_rows, rows)
      row = rows.find { |index| merged_rows[index] }
      return unless row

      raise TemplateSyntaxError,
            "table row #{row + 1}: the loop area contains merged cells; split them first (design document §7)"
    end

    # 有 #rows 标记时,其余行不能再出现 [] 标签(两种语法不混用)
    def check_no_mixed_loops!(rows, markers, content_rows)
      rows.each_with_index do |cells, index|
        next if content_rows.include?(index) || markers.any? { |m| m[:row] == index }
        next if cells.none? { |text| loop_roots(text).any? }

        raise TemplateSyntaxError,
              "table row #{index + 1}: a table cannot mix {{#rows}} markers with {{array[].field}} row loops"
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

          expected = prefixes.map { |prefix| "{{#{prefix}.field}}" }.join(" or ")
          raise TemplateSyntaxError,
                "table row #{row_index + 1}: {{#{path}}} does not match the loop array " \
                "(this row should use #{expected})"
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
      line = "table row #{index + 1}"
      if tags.size > 1
        raise TemplateSyntaxError,
              "#{line} contains #{tags.size} grid markers; only one is allowed per row"
      end
      return if tags.first[:col].zero?

      raise TemplateSyntaxError, "#{line}: #{tags.first[:tag]} grid marker must go in the first cell of the header row"
    end

    # {{#grid rows: 数组 cols: 数组 [value: 行内字段]}}
    def parse_grid_args(tag, row_index)
      line = "table row #{row_index + 1}"
      raw = tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
      body = raw.sub(/\A#grid/, "")
      args = {}
      pos = 0
      while pos < body.length
        m = body.match(/\G\s*(rows|cols|value)\s*:\s*([A-Za-z0-9_.]+)\s*/, pos)
        unless m
          raise TemplateSyntaxError,
                "#{line}: #{tag} has an invalid grid marker; " \
                "use {{#grid rows: array cols: array [value: field]}}"
        end
        key = m[1].to_sym
        raise TemplateSyntaxError, "#{line}: #{tag} repeats the grid argument #{m[1]}" if args.key?(key)

        args[key] = m[2]
        pos = m.end(0)
      end
      %i[rows cols].each do |key|
        next if args[key]

        raise TemplateSyntaxError, "#{line}: #{tag} grid marker is missing the #{key}: argument"
      end
      args
    end

    def grid_plan(rows, markers, merged_rows, columns)
      if markers.size > 1
        raise TemplateSyntaxError,
              "table row #{markers[1][:row] + 1}: a table allows only one grid marker " \
              "(already declared in row #{markers.first[:row] + 1})"
      end

      marker = markers.first
      line = "table row #{marker[:row] + 1}"
      if columns && columns != 2
        raise TemplateSyntaxError,
              "#{line}: a grid table supports exactly two template columns " \
              "(row titles + one data template); this table has #{columns}"
      end
      raise TemplateSyntaxError, "#{line}: the grid marker is missing its content row" if marker[:row] + 1 >= rows.size

      content = marker[:row] + 1
      if merged_rows.any?
        row = merged_rows.index(true)
        raise TemplateSyntaxError, "table row #{row + 1}: grid loops do not support merged cells; split them first"
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
              "table row #{index + 1}: a table cannot mix {{#grid}} with {{array[].field}} row loops"
      end
    end

    # 表头数据列只允许 {{col.字段}}(列模板)
    def check_grid_header_labels!(cells, row_index)
      cells.each_with_index do |text, col|
        next if col.zero?

        label_paths(text).each do |path|
          next if path == "col" || path.start_with?("col.")

          raise TemplateSyntaxError,
                "table row #{row_index + 1}, column #{col + 1}: {{#{path}}} is not in the grid header scope " \
                "(use {{col.field}})"
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

          scope = if col.zero?
                    "the first column allows only {{row.field}} or page fields"
                  else
                    "data columns allow {{row.field}} / {{col.field}} / {{cell}}"
                  end
          raise TemplateSyntaxError,
                "table row #{row_index + 1}, column #{col + 1}: " \
                "{{#{path}}} is not in the grid content row scope (#{scope})"
        end
      end
    end

    # ---- v0.2.0:配对行区块 + 单列带 ----

    # 出现 {{/rows}}、{{/cols}}、{{#cols}}、{{#if}}、{{/if}} 即进入区块模式
    def block_syntax?(rows)
      rows.any? do |cells|
        cells.any? do |text|
          directive_tags(text).any? do |tag|
            raw = raw_of(tag)
            raw.start_with?("#cols", "#if") || raw.start_with?("/rows", "/cols", "/if")
          end
        end
      end
    end

    def blocks_plan(rows, merged_rows)
      row_tags, col_tags, if_tags = collect_block_tags(rows)
      band = parse_column_band(rows, row_tags, col_tags)
      col_ifs, row_ifs = split_ifs(if_tags, band)
      band[:ifs] = parse_column_ifs(rows, col_ifs, band) if band
      blocks = parse_block_tree(rows, (row_tags + row_ifs).sort_by { |t| t[:row] })
      if band && band_in_if?(
        blocks, band[:row]
      )
        raise TemplateSyntaxError,
              "table row #{band[:row] + 1}: a column band cannot be written inside a conditional block"
      end

      check_block_ifs!(blocks)
      check_block_merges!(merged_rows, blocks, band)
      stacks = build_row_stacks(blocks)
      check_block_labels!(rows, stacks, band)
      { kind: :blocks, blocks: blocks, cols: band }
    end

    def collect_block_tags(rows)
      row_tags = []
      col_tags = []
      if_tags = []
      rows.each_with_index do |cells, r|
        cells.each_with_index do |text, c|
          directive_tags(text).each do |tag|
            raw = raw_of(tag)
            item = { row: r, col: c, raw: raw, tag: tag }
            if raw.start_with?("#rows", "/rows")
              row_tags << item
            elsif raw.start_with?("#cols", "/cols")
              col_tags << item
            elsif raw.start_with?("#if", "/if")
              if_tags << item
            else
              raise TemplateSyntaxError,
                    "table row #{r + 1}: block mode does not support #{tag} (only #rows / #cols / #if blocks)"
            end
          end
        end
      end
      [row_tags, col_tags, if_tags]
    end

    # 列带表头行内、位于列带范围内的 #if 是列级条件;其余是行级条件
    def split_ifs(tags, band)
      return [[], tags] unless band

      col_ifs = []
      row_ifs = []
      tags.each do |tag|
        if tag[:row] == band[:row] && tag[:col].between?(band[:first_col], band[:last_col])
          col_ifs << tag
        else
          row_ifs << tag
        end
      end
      [col_ifs, row_ifs]
    end

    def parse_column_ifs(rows, tags, band)
      return [] if tags.empty?

      stack = []
      result = []
      tags.each do |item|
        if item[:raw].start_with?("#if")
          node = open_column_if(rows, item, band, stack)
          stack.push(node)
        else
          close_column_if(rows, item, band, stack, result)
        end
      end
      unless stack.empty?
        node = stack.last
        raise TemplateSyntaxError,
              "table row #{band[:row] + 1}: column condition {{#if #{node[:path]}}} is missing {{/if}}"
      end

      result.sort_by { |node| node[:open_col] }.each_cons(2) do |left, right|
        next if right[:open_col] > left[:close_col]

        raise TemplateSyntaxError,
              "table row #{band[:row] + 1}: column condition ranges overlap " \
              "(columns #{left[:open_col] + 1}–#{left[:close_col] + 1} and " \
              "#{right[:open_col] + 1}–#{right[:close_col] + 1})"
      end
      result
    end

    def open_column_if(rows, item, band, stack)
      validate_column_if_marker!(rows, item, band)
      path = item[:tag][IF_OPEN_RE, 1]
      unless path
        raise TemplateSyntaxError,
              "table row #{band[:row] + 1}: #{item[:tag]} is an invalid column condition marker; use {{#if path}}"
      end
      if path.include?("[]") && !path.start_with?("#{band[:path]}[]")
        raise TemplateSyntaxError,
              "table row #{band[:row] + 1}: {{#if #{path}}} can only reference the current column array " \
              "#{band[:path]}[] or page fields"
      end
      raise TemplateSyntaxError, "table row #{band[:row] + 1}: column conditions cannot nest" if stack.any?

      { path: path, open_col: item[:col], close_col: nil }
    end

    def close_column_if(rows, item, band, stack, result)
      validate_column_if_marker!(rows, item, band)
      if stack.empty?
        raise TemplateSyntaxError,
              "table row #{band[:row] + 1}: {{/if}} has no matching column condition {{#if}}"
      end

      node = stack.pop
      if item[:col] < node[:open_col]
        raise TemplateSyntaxError,
              "table row #{band[:row] + 1}: {{/if}} must be to the right of its column condition {{#if}}"
      end
      node[:close_col] = item[:col]
      result << node
    end

    def validate_column_if_marker!(rows, item, band)
      line = "table row #{band[:row] + 1}"
      unless item[:row] == band[:row] &&
             item[:col].between?(band[:first_col], band[:last_col])
        raise TemplateSyntaxError, "#{line}: a column condition must be written inside the column band header"
      end
      return if rows[item[:row]][item[:col]].to_s.include?(item[:tag])

      raise TemplateSyntaxError, "#{line}: #{item[:tag]} column condition marker could not be located"
    end

    def parse_block_tree(rows, tags)
      roots = []
      stack = []
      if_stack = []
      tags.each do |item|
        case item[:raw]
        when /\A#rows/
          if if_stack.any?
            raise TemplateSyntaxError,
                  "table row #{item[:row] + 1}: a conditional block cannot contain a row block " \
                  "(move the condition outward)"
          end
          stack.push(open_block(rows, item, stack))
        when %r{\A/rows}
          if if_stack.any?
            raise TemplateSyntaxError,
                  "table row #{item[:row] + 1}: a conditional block must be fully contained in a row block"
          end
          close_block(rows, item, stack, roots)
        when /\A#if/
          open_if(rows, item, stack, if_stack)
        else
          close_if(rows, item, stack, if_stack)
        end
      end
      unless if_stack.empty?
        node = if_stack.last
        raise TemplateSyntaxError,
              "table row #{node[:open] + 1}: {{#if #{node[:path]}}} is missing {{/if}}"
      end
      unless stack.empty?
        block = stack.last
        raise TemplateSyntaxError,
              "table row #{block[:open] + 1}: {{#rows #{block[:path]}}} is missing {{/rows}}"
      end
      roots
    end

    def open_if(rows, item, stack, if_stack)
      validate_block_marker!(rows, item, "#if")
      path = item[:tag][IF_OPEN_RE, 1]
      unless path
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: #{item[:tag]} is an invalid condition marker; use {{#if path}}"
      end
      if stack.empty?
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: conditional blocks must be written inside a row block"
      end
      if if_stack.any?
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: conditional blocks cannot nest (combine the conditions)"
      end

      if_stack.push({ path: path, open: item[:row], close: nil })
    end

    def close_if(rows, item, stack, if_stack)
      validate_block_marker!(rows, item, "/if")
      if if_stack.empty?
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: {{/if}} has no matching {{#if}}"
      end

      node = if_stack.pop
      if item[:row] <= node[:open] + 1
        raise TemplateSyntaxError,
              "table row #{node[:open] + 1}: {{#if #{node[:path]}}} needs at least one content row"
      end
      node[:close] = item[:row]
      stack.last[:ifs] << node
    end

    def open_block(rows, item, stack)
      validate_block_marker!(rows, item, "#rows")
      path = item[:tag][MARKER_RE, 1]
      unless path
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: #{item[:tag]} is an invalid row block marker; use {{#rows path}}"
      end
      depth = stack.size + 1
      if depth > MAX_BLOCK_DEPTH
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: row block nesting exceeds #{MAX_BLOCK_DEPTH} levels"
      end

      block = { path: path, open: item[:row], close: nil, children: [], ifs: [], depth: depth }
      parent = stack.last
      if parent
        prefix = "#{parent[:path]}[]"
        unless path.start_with?("#{prefix}.")
          raise TemplateSyntaxError,
                "table row #{item[:row] + 1}: {{#rows #{path}}} must start with #{prefix} " \
                "(parent block #{parent[:path]})"
        end
        block[:relative] = path.delete_prefix("#{prefix}.")
      elsif path.include?("[]")
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: a top-level row block path has no [] (for example {{#rows classes}})"
      end
      block[:prefix] = "#{path}[]"
      block
    end

    def close_block(rows, item, stack, roots)
      validate_block_marker!(rows, item, "/rows")
      if stack.empty?
        raise TemplateSyntaxError,
              "table row #{item[:row] + 1}: {{/rows}} has no matching {{#rows}}"
      end

      block = stack.pop
      if item[:row] <= block[:open] + 1
        raise TemplateSyntaxError,
              "table row #{block[:open] + 1}: {{#rows #{block[:path]}}} needs at least one content row"
      end
      block[:close] = item[:row]
      (stack.last ? stack.last[:children] : roots) << block
    end

    # 区块标记必须独占整行首列
    def validate_block_marker!(rows, item, kind)
      cells = rows[item[:row]]
      line = "table row #{item[:row] + 1}"
      unless item[:col].zero? && cells[item[:col]].to_s.strip == item[:tag]
        raise TemplateSyntaxError, "#{line}: #{item[:tag]} block marker must occupy the first cell of a whole row"
      end
      if cells.each_with_index.any? { |text, c| c != item[:col] && !text.to_s.strip.empty? }
        raise TemplateSyntaxError,
              "#{line}: #{item[:tag]} block marker must occupy the whole row; leave the other cells empty"
      end

      case kind
      when "#rows"
        return if item[:tag].match?(MARKER_RE)
      when "/rows"
        return if item[:raw] == "/rows"
      when "#if"
        return if item[:tag].match?(IF_OPEN_RE)
      else
        return if item[:raw] == "/if"
      end

      raise TemplateSyntaxError, "#{line}: #{item[:tag]} is an invalid block marker"
    end

    def parse_column_band(_rows, row_tags, tags)
      return nil if tags.empty?

      opens = tags.select { |t| t[:raw].start_with?("#cols") }
      closes = tags.select { |t| t[:raw].start_with?("/cols") }
      if opens.size > 1 || closes.size > 1
        extra = (opens + closes).max_by { |t| t[:row] }
        raise TemplateSyntaxError, "table row #{extra[:row] + 1}: a table allows only one column band"
      end
      if opens.empty? || closes.empty?
        raise TemplateSyntaxError,
              "table row #{tags.first[:row] + 1}: a column band needs both {{#cols}} and {{/cols}}"
      end

      open = opens.first
      close = closes.first
      line = "table row #{open[:row] + 1}"
      unless open[:row] == close[:row]
        raise TemplateSyntaxError,
              "#{line}: {{#cols}} and {{/cols}} must be written in the same row"
      end
      if row_tags.any? do |t|
        t[:row] == open[:row]
      end
        raise TemplateSyntaxError,
              "#{line}: a column band cannot be written on a row block marker row"
      end
      if open[:col] < 1
        raise TemplateSyntaxError,
              "#{line}: a column band must start in a data column (outside the first column)"
      end
      raise TemplateSyntaxError, "#{line}: {{/cols}} must be to the right of {{#cols}}" if close[:col] < open[:col]

      m = open[:tag].match(COLS_OPEN_RE)
      unless m
        raise TemplateSyntaxError,
              "#{line}: invalid {{#cols}} marker; use {{#cols array [value: field1,field2]}}"
      end
      width = close[:col] - open[:col] + 1
      value_paths = m[2]&.split(/\s*,\s*/)
      if value_paths && ![1, width].include?(value_paths.size)
        raise TemplateSyntaxError,
              "#{line}: value: must contain 1 field or match the column band width (#{width}); got #{value_paths.size}"
      end
      { path: m[1], value_paths: value_paths, row: open[:row],
        first_col: open[:col], last_col: close[:col], width: width }
    end

    def check_block_merges!(merged_rows, blocks, band)
      if band
        row = merged_rows.index(true)
        if row
          raise TemplateSyntaxError,
                "table row #{row + 1}: column band loops do not support merged cells; split them first"
        end
      end

      stacks = build_row_stacks(blocks)
      merged_rows.each_with_index do |merged, r|
        next unless merged
        next if stacks[r].nil?

        raise TemplateSyntaxError, "table row #{r + 1}: row blocks do not support merged cells; split them first"
      end
    end

    # 条件区块里不允许出现列带
    def band_in_if?(blocks, row)
      blocks.any? do |block|
        block[:ifs].any? { |node| row.between?(node[:open], node[:close]) } ||
          band_in_if?(block[:children], row)
      end
    end

    # 条件路径含 [] 时,必须匹配当前区块栈里的某个作用域
    def check_block_ifs!(blocks, ancestors = [])
      blocks.each do |block|
        stack = ancestors + [block]
        block[:ifs].each do |node|
          path = node[:path]
          next unless path.include?("[]")

          match = stack.select { |b| path == b[:prefix] || path.start_with?("#{b[:prefix]}.") }
                       .max_by { |b| b[:prefix].length }
          if match.nil?
            raise TemplateSyntaxError,
                  "table row #{node[:open] + 1}: {{#if #{path}}} is not inside the current row block scope"
          end
          if path.scan("[]").size > match[:prefix].scan("[]").size
            raise TemplateSyntaxError,
                  "table row #{node[:open] + 1}: {{#if #{path}}} references a child array that was not expanded"
          end
        end
        check_block_ifs!(block[:children], stack)
      end
    end

    # 每个表格行所属的区块栈(外层 → 内层),供作用域校验与 check 复用
    def build_row_stacks(blocks)
      stacks = {}
      mark_block_rows(blocks, [], stacks)
      stacks
    end

    def mark_block_rows(blocks, ancestors, stacks)
      blocks.each do |block|
        (block[:open]..block[:close]).each { |r| stacks[r] = ancestors + [block] }
        mark_block_rows(block[:children], ancestors + [block], stacks)
      end
    end

    def check_block_labels!(rows, stacks, band)
      rows.each_with_index do |cells, r|
        stack = stacks[r] || []
        cells.each_with_index do |text, c|
          label_paths(text).each do |path|
            in_band = band && c.between?(band[:first_col], band[:last_col])
            band_decl_row = band && r == band[:row]
            validate_block_label!(path, r, c, stack, in_band, band_decl_row)
          end
        end
      end
    end

    def validate_block_label!(path, row, col, stack, in_band, band_decl_row)
      line = "table row #{row + 1}, column #{col + 1}"
      if path == "cell"
        unless in_band && !stack.empty?
          raise TemplateSyntaxError,
                "#{line}: {{cell}} can only be written in a column band cell inside a row block"
        end
        return
      end
      if path == "col" || path.start_with?("col.")
        raise TemplateSyntaxError, "#{line}: {{#{path}}} can only be written in a column band cell" unless in_band

        return
      end
      if path == "row" || path.start_with?("row.")
        raise TemplateSyntaxError, "#{line}: {{#{path}}} can only be written in a row block content row" if stack.empty?

        return
      end
      if band_decl_row && in_band
        raise TemplateSyntaxError,
              "#{line}: a column band declaration row allows only {{col.field}}, not {{#{path}}}"
      end
      return unless path.include?("[]")

      match = stack.select { |b| path == b[:prefix] || path.start_with?("#{b[:prefix]}.") }
                   .max_by { |b| b[:prefix].length }
      if match.nil?
        raise TemplateSyntaxError,
              "#{line}: {{#{path}}} is not inside the current row block scope"
      end
      return unless path.scan("[]").size > match[:prefix].scan("[]").size

      raise TemplateSyntaxError,
            "#{line}: {{#{path}}} references a child array that was not expanded (innermost scope: #{match[:prefix]})"
    end

    # ---- 文本工具 ----

    def directive_tags(text)
      text.to_s.scan(Scanner::TAG_RE).select do |tag|
        raw = raw_of(tag)
        raw.start_with?("#") || raw.start_with?("/")
      end
    end

    def raw_of(tag)
      tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
    end

    def grid_tag?(tag)
      tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s.start_with?("#grid")
    end

    # 单元格里可绑定的标签路径(去掉 formatter 与 # / 闭合指令);
    # 聚合标签由数据层对账,不参与表格作用域校验
    def label_paths(text)
      text.to_s.scan(Scanner::TAG_RE).filter_map do |tag|
        raw = raw_of(tag)
        next if raw.start_with?("#") || raw.start_with?("/")

        path, spec = raw.split(":", 2)
        next if aggregator_path?(path, spec)

        path
      end
    end
  end
end
