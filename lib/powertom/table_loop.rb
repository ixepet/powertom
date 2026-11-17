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

    # v0.2.x 区块语法:配对行区块 + 列带(可写在行区块内,支持多列模板)
    COLS_OPEN_RE = /\A\{\{\s*#cols\s+([A-Za-z0-9_\.]+)(?:\s+value:\s*([A-Za-z0-9_\.]+(?:\s*,\s*[A-Za-z0-9_\.]+)*))?\s*\}\}\z/.freeze
    IF_OPEN_RE = /\A\{\{\s*#if\s+([A-Za-z0-9_\[\]\.]+)\s*\}\}\z/.freeze
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
              "表格第 #{grid_markers.first[:row] + 1} 行:同一张表不能混用 {{#grid}} 与 {{#rows}}"
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
                  "表格第 #{r + 1} 行第 #{c + 1} 列:{{#{path}}} 只能写在使用 " \
                  "{{#rows}} 区块或 {{#grid}} 的表格里"
          end
        end
      end
    end

    def scope_variable?(path)
      path == "cell" || path == "row" || path.start_with?("row.") ||
        path == "col" || path.start_with?("col.")
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
      row_tags, col_tags = collect_block_tags(rows)
      blocks = parse_block_tree(rows, row_tags)
      band = parse_column_band(rows, row_tags, col_tags)
      if band && band_in_if?(blocks, band[:row])
        raise TemplateSyntaxError, "表格第 #{band[:row] + 1} 行:列带不能写在条件区块内"
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
      rows.each_with_index do |cells, r|
        cells.each_with_index do |text, c|
          directive_tags(text).each do |tag|
            raw = raw_of(tag)
            item = { row: r, col: c, raw: raw, tag: tag }
            if raw.start_with?("#rows", "/rows", "#if", "/if")
              row_tags << item
            elsif raw.start_with?("#cols", "/cols")
              col_tags << item
            else
              raise TemplateSyntaxError,
                    "表格第 #{r + 1} 行:区块模式不支持 #{tag}(只支持 #rows / #cols / #if 区块)"
            end
          end
        end
      end
      [row_tags, col_tags]
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
                  "表格第 #{item[:row] + 1} 行:条件区块内不能放行区块(请把条件写在外层)"
          end
          stack.push(open_block(rows, item, stack))
        when /\A\/rows/
          if if_stack.any?
            raise TemplateSyntaxError,
                  "表格第 #{item[:row] + 1} 行:条件区块必须完整包含在行区块内"
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
              "表格第 #{node[:open] + 1} 行:{{#if #{node[:path]}}} 缺少 {{/if}}"
      end
      unless stack.empty?
        block = stack.last
        raise TemplateSyntaxError,
              "表格第 #{block[:open] + 1} 行:{{#rows #{block[:path]}}} 缺少 {{/rows}}"
      end
      roots
    end

    def open_if(rows, item, stack, if_stack)
      validate_block_marker!(rows, item, "#if")
      path = item[:tag][IF_OPEN_RE, 1]
      unless path
        raise TemplateSyntaxError,
              "表格第 #{item[:row] + 1} 行:#{item[:tag]} 条件标记不合法,应为 {{#if 路径}}"
      end
      if stack.empty?
        raise TemplateSyntaxError, "表格第 #{item[:row] + 1} 行:条件区块必须写在行区块内"
      end
      if if_stack.any?
        raise TemplateSyntaxError, "表格第 #{item[:row] + 1} 行:条件区块不能嵌套(请合并条件)"
      end

      if_stack.push({ path: path, open: item[:row], close: nil })
    end

    def close_if(rows, item, stack, if_stack)
      validate_block_marker!(rows, item, "/if")
      if if_stack.empty?
        raise TemplateSyntaxError,
              "表格第 #{item[:row] + 1} 行:{{/if}} 没有对应的 {{#if}}"
      end

      node = if_stack.pop
      if item[:row] <= node[:open] + 1
        raise TemplateSyntaxError,
              "表格第 #{node[:open] + 1} 行:{{#if #{node[:path]}}} 区块内至少需要一行内容"
      end
      node[:close] = item[:row]
      stack.last[:ifs] << node
    end

    def open_block(rows, item, stack)
      validate_block_marker!(rows, item, "#rows")
      path = item[:tag][MARKER_RE, 1]
      unless path
        raise TemplateSyntaxError,
              "表格第 #{item[:row] + 1} 行:#{item[:tag]} 行区块标记不合法,应为 {{#rows 路径}}"
      end
      depth = stack.size + 1
      if depth > MAX_BLOCK_DEPTH
        raise TemplateSyntaxError,
              "表格第 #{item[:row] + 1} 行:行区块嵌套超过 #{MAX_BLOCK_DEPTH} 级"
      end

      block = { path: path, open: item[:row], close: nil, children: [], ifs: [], depth: depth }
      parent = stack.last
      if parent
        prefix = "#{parent[:path]}[]"
        unless path.start_with?("#{prefix}.")
          raise TemplateSyntaxError,
                "表格第 #{item[:row] + 1} 行:{{#rows #{path}}} 必须以 #{prefix} 开头" \
                "(父区块 #{parent[:path]})"
        end
        block[:relative] = path.delete_prefix("#{prefix}.")
      elsif path.include?("[]")
        raise TemplateSyntaxError,
              "表格第 #{item[:row] + 1} 行:顶层行区块路径不带 [](如 {{#rows classes}})"
      end
      block[:prefix] = "#{path}[]"
      block
    end

    def close_block(rows, item, stack, roots)
      validate_block_marker!(rows, item, "/rows")
      if stack.empty?
        raise TemplateSyntaxError,
              "表格第 #{item[:row] + 1} 行:{{/rows}} 没有对应的 {{#rows}}"
      end

      block = stack.pop
      if item[:row] <= block[:open] + 1
        raise TemplateSyntaxError,
              "表格第 #{block[:open] + 1} 行:{{#rows #{block[:path]}}} 区块内至少需要一行内容"
      end
      block[:close] = item[:row]
      (stack.last ? stack.last[:children] : roots) << block
    end

    # 区块标记必须独占整行首列
    def validate_block_marker!(rows, item, kind)
      cells = rows[item[:row]]
      line = "表格第 #{item[:row] + 1} 行"
      unless item[:col].zero? && cells[item[:col]].to_s.strip == item[:tag]
        raise TemplateSyntaxError, "#{line}:#{item[:tag]} 区块标记必须独占整行首列"
      end
      if cells.each_with_index.any? { |text, c| c != item[:col] && !text.to_s.strip.empty? }
        raise TemplateSyntaxError, "#{line}:#{item[:tag]} 区块标记必须独占整行,其余单元格请留空"
      end
      case kind
      when "#rows"
        return if item[:tag].match?(MARKER_RE)
      when "/rows"
        return if item[:raw].match?(/\A\/rows\z/)
      when "#if"
        return if item[:tag].match?(IF_OPEN_RE)
      else
        return if item[:raw].match?(/\A\/if\z/)
      end

      raise TemplateSyntaxError, "#{line}:#{item[:tag]} 区块标记不合法"
    end

    def parse_column_band(rows, row_tags, tags)
      return nil if tags.empty?

      opens = tags.select { |t| t[:raw].start_with?("#cols") }
      closes = tags.select { |t| t[:raw].start_with?("/cols") }
      if opens.size > 1 || closes.size > 1
        extra = (opens + closes).max_by { |t| t[:row] }
        raise TemplateSyntaxError, "表格第 #{extra[:row] + 1} 行:一张表只允许一个列带"
      end
      if opens.empty? || closes.empty?
        raise TemplateSyntaxError,
              "表格第 #{tags.first[:row] + 1} 行:列带必须同时有 {{#cols}} 与 {{/cols}}"
      end

      open = opens.first
      close = closes.first
      line = "表格第 #{open[:row] + 1} 行"
      unless open[:row] == close[:row]
        raise TemplateSyntaxError, "#{line}:{{#cols}} 与 {{/cols}} 必须写在同一行"
      end
      if row_tags.any? { |t| t[:row] == open[:row] }
        raise TemplateSyntaxError, "#{line}:列带不能写在行区块标记行上"
      end
      if open[:col] < 1
        raise TemplateSyntaxError, "#{line}:列带必须写在数据列(首列之外)"
      end
      if close[:col] < open[:col]
        raise TemplateSyntaxError, "#{line}:{{/cols}} 必须在 {{#cols}} 右侧"
      end

      m = open[:tag].match(COLS_OPEN_RE)
      unless m
        raise TemplateSyntaxError,
              "#{line}:{{#cols}} 写法不合法,应为 {{#cols 数组 [value: 字段1,字段2]}}"
      end
      width = close[:col] - open[:col] + 1
      value_paths = m[2]&.split(/\s*,\s*/)
      if value_paths && ![1, width].include?(value_paths.size)
        raise TemplateSyntaxError,
              "#{line}:value: 的数量必须为 1 或与列带宽度(#{width})一致,当前 #{value_paths.size} 个"
      end
      { path: m[1], value_paths: value_paths, row: open[:row],
        first_col: open[:col], last_col: close[:col], width: width }
    end

    def check_block_merges!(merged_rows, blocks, band)
      if band
        row = merged_rows.index(true)
        if row
          raise TemplateSyntaxError, "表格第 #{row + 1} 行:列带循环不支持合并单元格,请先拆分"
        end
      end

      stacks = build_row_stacks(blocks)
      merged_rows.each_with_index do |merged, r|
        next unless merged
        next if stacks[r].nil?

        raise TemplateSyntaxError, "表格第 #{r + 1} 行:行区块内不支持合并单元格,请先拆分"
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
                  "表格第 #{node[:open] + 1} 行:{{#if #{path}}} 不在当前行区块作用域内"
          end
          if path.scan("[]").size > match[:prefix].scan("[]").size
            raise TemplateSyntaxError,
                  "表格第 #{node[:open] + 1} 行:{{#if #{path}}} 引用了未展开的下一级数组"
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
      line = "表格第 #{row + 1} 行第 #{col + 1} 列"
      if path == "cell"
        unless in_band && !stack.empty?
          raise TemplateSyntaxError,
                "#{line}:{{cell}} 只能写在行区块内的列带单元格里"
        end
        return
      end
      if path == "col" || path.start_with?("col.")
        unless in_band
          raise TemplateSyntaxError, "#{line}:{{#{path}}} 只能写在列带单元格里"
        end
        return
      end
      if path == "row" || path.start_with?("row.")
        if stack.empty?
          raise TemplateSyntaxError, "#{line}:{{#{path}}} 只能写在行区块内容行里"
        end
        return
      end
      if band_decl_row && in_band
        raise TemplateSyntaxError,
              "#{line}:列带声明行只能写 {{col.字段}},不能写 {{#{path}}}"
      end
      return unless path.include?("[]")

      match = stack.select { |b| path == b[:prefix] || path.start_with?("#{b[:prefix]}.") }
                   .max_by { |b| b[:prefix].length }
      if match.nil?
        raise TemplateSyntaxError,
              "#{line}:{{#{path}}} 不在当前行区块作用域内"
      end
      if path.scan("[]").size > match[:prefix].scan("[]").size
        raise TemplateSyntaxError,
              "#{line}:{{#{path}}} 引用了未展开的下一级数组(当前最内层 #{match[:prefix]})"
      end
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

    # 单元格里可绑定的标签路径(去掉 formatter 与 # / 闭合指令)
    def label_paths(text)
      text.to_s.scan(Scanner::TAG_RE).filter_map do |tag|
        raw = raw_of(tag)
        next if raw.start_with?("#") || raw.start_with?("/")

        raw.split(":", 2).first
      end
    end
  end
end
