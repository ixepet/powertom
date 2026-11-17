# frozen_string_literal: true

require "tempfile"
require_relative "scanner"
require_relative "binder"
require_relative "path_resolver"
require_relative "grid_value"
require_relative "run_merge"
require_relative "table_loop"
require_relative "data_loading"
require_relative "adapter/ruby_pptx_adapter"
require_relative "adapter/page_surgery"

module PowerTom
  # §2.1 渲染入口。
  #   result = PowerTom.render("templates/x.pptx", data: "data.toml", strict: true)
  #   result.save("out/x.pptx")
  #   result.warnings  # 未使用字段、缺失字段降级、备注标签等
  #
  # data 支持 Hash 或 .toml 文件路径(TOML 是 gem 的默认数据格式)。
  # v0 覆盖:单页多标签、跨 run 标签、{{#each}} 页面克隆、{{#if}} 页面删除(§3.3)。
  def self.render(template_path, data:, strict: true)
    Render.new(template_path, data: DataLoading.coerce(data), strict: strict).call
  end

  # Result of {PowerTom.render}: the edited presentation plus render warnings.
  class RenderResult
    # @return [Array<String>] non-fatal warnings (unused fields, fallbacks, limitations).
    attr_reader :warnings

    def initialize(adapter, prs, warnings, tempfile: nil)
      @adapter = adapter
      @prs = prs
      @warnings = warnings
      @tempfile = tempfile
    end

    # Save the rendered deck.
    #
    # @param path [String] destination +.pptx+ path.
    # @return [String] the destination path.
    def save(path)
      @adapter.save(@prs, path)
      close
      path
    end

    # Remove the intermediate surgery file.
    #
    # Results that are never saved release it via the Tempfile finalizer when
    # garbage collected; calling this explicitly frees it right away.
    #
    # @return [nil]
    def close
      @tempfile&.close!
      @tempfile = nil
      nil
    end

    # Number of slides in the rendered deck (after cloning/removal).
    #
    # @return [Integer]
    def slide_count
      @prs.slides.size
    end
  end

  # 渲染管线(§4):扫描(标签+指令,语法校验)→ 编辑计划 → 结构手术(克隆/删页)
  # → 绑定(#each 页取迭代作用域)→ 保存。
  # 任何抛错都发生在写盘之前:产物要么完整要么不存在。
  class Render
    def initialize(template_path, data:, strict:)
      @template_path = template_path
      @data = data
      @strict = strict
    end

    def call
      adapter = Adapter::RubyPptxAdapter.new
      prs = adapter.open(@template_path)
      warnings = []

      contexts = adapter.paragraph_contexts(prs)
      # 正文与表格单元格的标签语法校验,手术前失败
      Scanner.scan(contexts + adapter.table_cell_contexts(prs))
      notes = adapter.notes_texts(prs)
      directives = Scanner.scan_directives(notes)
      binder = Binder.new(@data, strict: @strict, warnings: warnings)

      if directives.empty?
        work_prs = prs
        page_scopes = Hash.new { |_h, _k| { scope: nil, scope_root: nil } }
      else
        pages = build_page_plan(directives, binder, prs.slides.size)
        run_surgery(adapter, pages)
        work_prs = adapter.open(@work_path) # 手术产物重新打开,按新页序绑定
        # pages 与输出页一一对应(手术按计划顺序展开,不重排)
        page_scopes = Hash.new { |_h, _k| { scope: nil, scope_root: nil } }
        pages.each_with_index do |p, i|
          page_scopes[i] = { scope: p[:scope], scope_root: p[:scope_root] }
        end
      end

      # 表格行循环:按数组长度展开模板行,再采集单元格段落做绑定
      table_scopes = expand_table_rows(adapter, work_prs, page_scopes, binder)

      contexts = adapter.paragraph_contexts(work_prs) + adapter.table_cell_contexts(work_prs)
      contexts.each do |ctx|
        page = page_scopes[ctx[:slide_no] - 1]
        row_scopes = row_scopes_for(table_scopes, ctx)
        grid_scope = grid_scope_for(table_scopes, ctx)
        row_item = row_item_for(table_scopes, ctx)
        bctx = ctx.merge(scope: page[:scope], scope_root: page[:scope_root],
                         row_scopes: row_scopes, grid_scope: grid_scope,
                         row_item: row_item)
        new_texts = RunMerge.merge(
          ctx[:run_texts],
          ->(path, spec) { binder.render_label(path, bctx, spec: spec) }
        )
        adapter.write_paragraph_runs(ctx[:paragraph], new_texts) if new_texts
      end

      replace_images(adapter, work_prs, page_scopes, binder, warnings)
      bind_charts(adapter, work_prs, page_scopes, binder, warnings)
      report_chart_tags(adapter, work_prs, warnings)

      report_unused_fields(binder, warnings)
      report_notes_labels(notes, warnings)

      RenderResult.new(adapter, work_prs, warnings, tempfile: @work_temp)
    rescue StandardError
      cleanup_work_temp
      raise
    end

    private

    def cleanup_work_temp
      @work_temp&.close!
      @work_temp = nil
    end

    # §3.3:#each 按数组克隆(K=数组长度,空数组整组删除);#if 为假删页。
    # 返回 [{source:, iteration:, scope:, scope_root:}] 按输出顺序。
    def build_page_plan(directives, binder, slide_count)
      pages = []
      (1..slide_count).each do |no|
        directive = directives[no]
        ctx = { slide_no: no, shape: "(notes directive)" }
        if directive.nil?
          pages << { source: no, iteration: nil, scope: nil, scope_root: nil }
        elsif directive[:kind] == :if
          value = binder.value_at(directive[:path], ctx)
          pages << { source: no, iteration: nil, scope: nil, scope_root: nil } if truthy?(value)
        else
          value = binder.value_at(directive[:path], ctx)
          if value.nil?
            raise MissingDataError,
                  "slide #{no} notes {{#each #{directive[:path]}}}: " \
                  "data is missing '#{directive[:path]}', cannot determine the loop count"
          end
          unless value.is_a?(Array)
            raise PowerTom::Error,
                  "slide #{no} notes {{#each #{directive[:path]}}}: expected an array, got #{value.class}"
          end
          root = directive[:path].split(".").first[/\A[A-Za-z0-9_]+/]
          value.each_with_index do |item, k|
            pages << { source: no, iteration: k, scope: item, scope_root: root }
          end
        end
      end
      pages
    end

    def truthy?(value)
      !(value.nil? || value == false)
    end

    # 结构手术走字节级包操作:模板原文件 → 手术后的临时文件 → 重新打开绑定
    def run_surgery(_adapter, pages)
      @work_temp = Tempfile.new(["powertom_surgery", ".pptx"])
      @work_path = @work_temp.path
      @work_temp.close
      Adapter::PageSurgery.execute(@template_path, @work_path, pages)
    end

    # §5.3 图片替换:powertom:image:字段名 占位 → 数据里的图片文件。
    # 与文本一样作用域感知:#each 克隆页各自取本项的图片;缺字段(strict: false)
    # 时保留占位图并记 warning。
    def replace_images(adapter, prs, page_scopes, binder, warnings)
      adapter.picture_contexts(prs).each do |pctx|
        page = page_scopes[pctx[:slide_no] - 1]
        ctx = { slide_no: pctx[:slide_no], shape: pctx[:shape],
                scope: page[:scope], scope_root: page[:scope_root] }
        value = binder.value_at(pctx[:field], ctx, purpose: "picture placeholder; keeping the placeholder")
        next if value.nil? # missing (non-strict): keep the placeholder picture
        unless value.is_a?(String) && !value.empty?
          raise PowerTom::Error,
                "slide #{pctx[:slide_no]} picture field '#{pctx[:field]}' requires a String file path, " \
                "got #{value.class}"
        end
        unless File.file?(value)
          raise PowerTom::Error,
                "slide #{pctx[:slide_no]} picture field '#{pctx[:field]}' file does not exist: #{value}"
        end
        warn_image_aspect(adapter, pctx, value, warnings)
        adapter.replace_image(pctx[:slide], pctx[:picture], value)
      end
    end

    # 固定策略是"填满形状、居中裁切";比例差异大时提前提示设计师
    def warn_image_aspect(adapter, pctx, image_path, warnings)
      mismatch = adapter.image_aspect_mismatch(pctx[:picture], image_path)
      return unless mismatch

      warnings << "slide #{pctx[:slide_no]} picture '#{pctx[:field]}': " \
                  "image ratio #{format('%.2f',
                                        mismatch[:image_ratio])} differs significantly from placeholder shape " \
                  "#{format('%.2f', mismatch[:shape_ratio])}; it will be centre-cropped"
    end

    # §5.4 图表数据绑定:powertom:chart:字段名 占位 → ChartData 整体替换。
    # 克隆页共享 chart part,adapter 在绑定前为该形状深拷贝独立 part
    # (docs/chart-binding-design.md)。与图片一样作用域感知:#each 克隆页
    # 各自绑定本项的数据;缺字段(strict: false)时保留占位图表。
    def bind_charts(adapter, prs, page_scopes, binder, _warnings)
      adapter.chart_contexts(prs).each do |cctx|
        page = page_scopes[cctx[:slide_no] - 1]
        ctx = { slide_no: cctx[:slide_no], shape: cctx[:shape],
                scope: page[:scope], scope_root: page[:scope_root] }
        value = binder.value_at(cctx[:field], ctx, purpose: "chart placeholder; keeping the placeholder")
        next if value.nil? # 缺失(non-strict):保留占位图表

        if %i[XY BUBBLE].include?(cctx[:kind])
          validate_xy_chart_data!(value, cctx)
          validate_chart_series_count!(value, cctx)
        else
          if Adapter::RubyPptxAdapter.unsupported_chart_kind?(cctx[:kind])
            label = Adapter::RubyPptxAdapter.unsupported_chart_kind_label(cctx[:kind])
            raise PowerTom::Error,
                  "slide #{cctx[:slide_no]} chart '#{cctx[:shape]}' field '#{cctx[:field]}': " \
                  "#{label} charts are not supported for data binding " \
                  "(supported: column/bar, line, area, pie, doughnut, combo, scatter, bubble)"
          end
          validate_chart_data!(value, cctx)
          validate_chart_series_count!(value, cctx) if cctx[:kind] == :combo
        end
        adapter.replace_chart_data(prs, cctx[:chart_shape], cctx[:slide], value)
      end
    end

    # 数据形状:{categories: [String|Numeric, ...](非空),
    #          series: [{name:, values: [Numeric, ...]}](非空,长度与 categories 一致),
    #          number_format: String(可选)}
    def validate_chart_data!(value, cctx)
      where = "slide #{cctx[:slide_no]} chart '#{cctx[:shape]}' field '#{cctx[:field]}'"
      unless value.is_a?(Hash)
        raise PowerTom::Error,
              "#{where} requires an object with 'categories' and 'series', got #{value.class}"
      end

      categories = chart_field_value(value, "categories")
      unless categories.is_a?(Array) && !categories.empty? &&
             categories.all? { |c| c.is_a?(String) || c.is_a?(Numeric) }
        raise PowerTom::Error, "#{where} 'categories' must be a non-empty array of strings or numbers"
      end

      series = chart_field_value(value, "series")
      unless series.is_a?(Array) && !series.empty?
        raise PowerTom::Error, "#{where} 'series' must be a non-empty array of {name, values}"
      end

      series.each_with_index do |item, i|
        unless item.is_a?(Hash)
          raise PowerTom::Error,
                "#{where} series item #{i + 1} must be an object with 'name' and 'values', got #{item.class}"
        end
        values = chart_field_value(item, "values")
        next if values.is_a?(Array) && values.size == categories.size && values.all?(Numeric)

        name = chart_field_value(item, "name") || "##{i + 1}"
        raise PowerTom::Error,
              "#{where} series '#{name}' 'values' must be an array of #{categories.size} numbers"
      end

      number_format = chart_field_value(value, "number_format")
      return if number_format.nil? || number_format.is_a?(String)

      raise PowerTom::Error, "#{where} 'number_format' must be a String, got #{number_format.class}"
    end

    def chart_field_value(hash, key)
      hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]
    end

    # 绑定系列数守卫(设计文档 §9,combo/XY/BUBBLE 通用):上游对 combo 做
    # 跨 plot 扁平 zip,系列多了从最后 plot 克隆、少了会移除空 plot——两者
    # 都会静默改变设计师的组合结构;scatter/bubble 的适配层重写同样按数量
    # 守卫,所以要求恰好提供模板的系列总数
    def validate_chart_series_count!(value, cctx)
      count = chart_field_value(value, "series").size
      return if count == cctx[:series_count]

      raise PowerTom::Error,
            "slide #{cctx[:slide_no]} chart '#{cctx[:shape]}' field '#{cctx[:field]}': " \
            "chart template draws #{cctx[:distribution]} (#{cctx[:series_count]} series in " \
            "total); the data must provide exactly #{cctx[:series_count]} series in document " \
            "order, got #{count}"
    end

    # 散点/气泡数据形状:{series: [{name:, points: [{x:, y:(, size:)}]}]}。
    # 每个系列自带坐标对,没有共享 categories;误传 categories 视为形状错误
    def validate_xy_chart_data!(value, cctx)
      where = "slide #{cctx[:slide_no]} chart '#{cctx[:shape]}' field '#{cctx[:field]}'"
      unless value.is_a?(Hash)
        raise PowerTom::Error,
              "#{where} requires an object with 'series' (each with 'points'), got #{value.class}"
      end
      unless chart_field_value(value, "categories").nil?
        raise PowerTom::Error,
              "#{where}: scatter/bubble data has no 'categories'; each series carries its own 'points'"
      end

      series = chart_field_value(value, "series")
      unless series.is_a?(Array) && !series.empty?
        raise PowerTom::Error, "#{where} 'series' must be a non-empty array of {name, points}"
      end

      bubble = cctx[:kind] == :BUBBLE
      series.each_with_index do |item, i|
        unless item.is_a?(Hash)
          raise PowerTom::Error,
                "#{where} series item #{i + 1} must be an object with 'name' and 'points', got #{item.class}"
        end
        points = chart_field_value(item, "points")
        unless points.is_a?(Array) && !points.empty?
          name = chart_field_value(item, "name")
          raise PowerTom::Error,
                "#{where} series '#{name}' 'points' must be a non-empty array of {x, y#{', size' if bubble}}"
        end

        points.each_with_index do |point, k|
          validate_xy_point!(point, bubble, where, chart_field_value(item, "name"), k)
        end
      end
    end

    def validate_xy_point!(point, bubble, where, name, point_index)
      at = "series '#{name}' point #{point_index + 1}"
      unless point.is_a?(Hash)
        raise PowerTom::Error, "#{where} #{at} must be an object with 'x' and 'y', got #{point.class}"
      end

      (bubble ? %w[x y size] : %w[x y]).each do |key|
        value = chart_field_value(point, key)
        next if value.is_a?(Numeric)

        raise PowerTom::Error, "#{where} #{at} '#{key}' must be a number, got #{value.class}"
      end
    end

    # 图表数据可绑定(powertom:chart:*),但图表内的文本标签不支持:
    # 发现残留标签时温和告警,不修改文件
    def report_chart_tags(adapter, prs, warnings)
      adapter.chart_tags(prs).each do |chart|
        warnings << "slide #{chart[:slide_no]} chart '#{chart[:shape]}' contains tags " \
                    "#{chart[:tags].join(', ')}: text tags inside charts are not supported; tags were left as-is"
      end
    end

    # 表格循环:单级行 / 两级嵌套行 / 动态列;页级 #each 与表格循环不叠加
    def expand_table_rows(adapter, prs, page_scopes, binder)
      scopes = {}
      adapter.table_contexts(prs).each do |table|
        plan = table_plan(table)
        next unless plan

        page = page_scopes[table[:slide_no] - 1]
        if page[:scope]
          raise PowerTom::Error,
                "slide #{table[:slide_no]} table '#{table[:shape]}': " \
                "a page-level #each cannot be combined with table row loops (only one loop level is supported)"
        end

        scopes[[table[:slide_no], table[:shape]]] = case plan[:kind]
                                                    when :simple
                                                      expand_simple_rows(adapter, table, plan, binder)
                                                    when :nested
                                                      expand_nested_rows(adapter, table, plan, binder)
                                                    when :blocks
                                                      expand_block_rows(adapter, table, plan, binder)
                                                    else
                                                      expand_grid_rows(adapter, table, plan, binder)
                                                    end
      end
      scopes
    end

    # 结构错误(表内行号)补上页码与形状名,方便设计师定位
    def table_plan(table)
      TableLoop.plan(table[:rows], merged_rows: table[:merged_rows],
                                   columns: table[:columns])
    rescue TemplateSyntaxError => e
      raise TemplateSyntaxError, "slide #{table[:slide_no]} table '#{table[:shape]}': #{e.message}"
    end

    def expand_simple_rows(adapter, table, plan, binder)
      ctx = { slide_no: table[:slide_no], shape: table[:shape] }
      items = fetch_loop_array(binder, plan[:root], table, ctx)
      adapter.expand_table_row(table[:element], table[:frame], plan[:row], items.size)
      { kind: :simple, start: plan[:row], count: items.size,
        items: items, root: plan[:root] }
    end

    def expand_nested_rows(adapter, table, plan, binder)
      ctx = { slide_no: table[:slide_no], shape: table[:shape] }
      parents = fetch_loop_array(binder, plan[:parent][:path], table, ctx)
      children = parents.each_with_index.map do |parent, index|
        fetch_child_array(parent, plan[:child][:relative], table, ctx, index)
      end
      adapter.expand_table_rows_nested(table[:element], table[:frame], plan,
                                       children.map(&:size))

      rows = []
      children.each_with_index do |items, parent_index|
        rows << { parent: parent_index, child: nil }
        items.each_index { |child_index| rows << { parent: parent_index, child: child_index } }
      end

      { kind: :nested, start: plan[:parent][:marker], rows: rows,
        parents: parents, children: children,
        parent_prefix: plan[:parent][:prefix], child_prefix: plan[:child][:prefix] }
    end

    # 动态列(#grid):列按 cols 克隆(每一行),行按 rows 克隆;首列固定为行标题
    def expand_grid_rows(adapter, table, plan, binder)
      ctx = { slide_no: table[:slide_no], shape: table[:shape] }
      grid = plan[:grid]
      rows = fetch_loop_array(binder, grid[:rows_path], table, ctx)
      cols = fetch_loop_array(binder, grid[:cols_path], table, ctx)
      check_grid_columns!(cols, table, ctx)

      adapter.expand_grid_columns(table[:element], table[:frame], cols.size)
      adapter.strip_grid_marker(table[:element], grid[:header], 0)
      adapter.expand_table_row(table[:element], table[:frame], grid[:content], rows.size)

      { kind: :grid, header: grid[:header], content_start: grid[:content],
        rows: rows, cols: cols, value_path: grid[:value_path] }
    end

    # 列键提前校验:不要等渲染到一半才发现某列缺 key
    def check_grid_columns!(cols, table, ctx)
      cols.each_with_index do |col, index|
        GridValue.column_key(col)
      rescue MissingDataError => e
        raise MissingDataError,
              "slide #{ctx[:slide_no]} table '#{table[:shape]}': " \
              "column item #{index + 1}: #{e.message}"
      end
    end

    # v0.2.0 区块:配对行区块(多行记录、最多 3 级)+ 单列带(可写在区块内)
    def expand_block_rows(adapter, table, plan, binder)
      ctx = { slide_no: table[:slide_no], shape: table[:shape] }
      band = plan[:cols]
      cols = []
      column_plan = []
      if band
        cols = fetch_loop_array(binder, band[:path], table, ctx)
        check_grid_columns!(cols, table, ctx)
        visibility = column_visibility(band, cols)
        column_plan = build_column_plan(band, cols, visibility)
        # 先剥离标记,再复制列:否则标记会被复制到每一列
        adapter.strip_column_markers(table[:element], band[:row], band[:first_col], band[:last_col])
        adapter.expand_column_band(table[:element], table[:frame],
                                   band[:first_col], band[:last_col], cols.size)
        remove_hidden_columns(adapter, table, band, visibility)
      end

      # 行索引在列克隆后不变,先捕获顶层区块的开闭行元素
      roots = plan[:blocks].map do |block|
        { block: block,
          open_el: adapter.table_row_element(table[:element], block[:open]),
          close_el: adapter.table_row_element(table[:element], block[:close]),
          items: fetch_loop_array(binder, block[:path], table, ctx) }
      end
      roots.each do |node|
        node[:children_by_item] = resolve_block_children(node[:block], {}, node[:items], table, ctx)
        node[:if_values_by_item] = node[:items].map do |item|
          block_if_values(node[:block], item, {})
        end
      end

      records = build_block_row_records(roots, table[:rows].size)
      roots.each do |node|
        node[:groups] = adapter.clone_table_row_range(
          table[:element], node[:open_el], node[:close_el], node[:items].size
        )
        expand_block_children(adapter, table, node)
      end
      adapter.refresh_table_height(table[:element], table[:frame])

      { kind: :blocks, records: records, cols: cols, band: band,
        column_plan: column_plan }
    end

    # 列条件:按列项求值,返回 [item][template_column] 的可见矩阵
    def column_visibility(band, cols)
      width = band[:width]
      return cols.map { Array.new(width, true) } if band[:ifs].nil? || band[:ifs].empty?

      cols.map do |col|
        values = band[:ifs].to_h do |node|
          [node, column_condition_truthy?(node[:path], col, band)]
        end
        Array.new(width) do |template_index|
          target = band[:first_col] + template_index
          node = band[:ifs].find { |n| target.between?(n[:open_col], n[:close_col]) }
          node.nil? || values[node]
        end
      end
    end

    def column_condition_truthy?(path, col, band)
      value = GridValue.column_condition_value(path, col, band[:path], @data)
      truthy?(value)
    rescue MissingDataError => e
      raise MissingDataError, "{{#if #{path}}} could not be evaluated: #{e.message}"
    end

    # 展开后的列计划:每个输出列对应哪个列项、哪个模板列
    def build_column_plan(band, cols, visibility)
      plan = []
      cols.each_with_index do |col, item_index|
        band[:width].times do |template_index|
          next unless visibility[item_index][template_index]

          plan << { col: col, template_index: template_index }
        end
      end
      plan
    end

    def remove_hidden_columns(adapter, table, band, visibility)
      hidden = []
      visibility.each_with_index do |item, item_index|
        item.each_with_index do |visible, template_index|
          next if visible

          hidden << (band[:first_col] + (item_index * band[:width]) + template_index)
        end
      end
      return if hidden.empty?

      adapter.remove_table_columns(table[:element], table[:frame], hidden)
    end

    # 子区块的数组依赖父项:按每个父项解析一次,供行计划与展开复用
    def resolve_block_children(block, parent_scope, items, table, ctx)
      items.each_with_index.map do |item, index|
        scope = parent_scope.merge(block[:prefix] => item)
        block[:children].map do |child|
          child_items = fetch_child_array(item, child[:relative], table, ctx, index)
          {
            block: child,
            items: child_items,
            if_values_by_item: child_items.map { |ci| block_if_values(child, ci, scope) },
            children_by_item: resolve_block_children(child, scope, child_items, table, ctx)
          }
        end
      end
    end

    def block_if_values(block, item, parent_scope)
      scope = parent_scope.merge(block[:prefix] => item)
      block[:ifs].to_h do |node|
        [node, condition_truthy?(node[:path], item, scope)]
      end
    end

    # #if 求值:含 [] 时按作用域栈;否则先看当前记录,再看整页数据
    def condition_truthy?(path, item, scope)
      value = if path.include?("[]")
                prefix = scope.keys.select { |key| path == key || path.start_with?("#{key}.") }
                              .max_by(&:length)
                raise PowerTom::Error, "{{#if #{path}}} is not inside the current row block scope" unless prefix

                remainder = path.delete_prefix(prefix).delete_prefix(".")
                remainder.empty? ? scope[prefix] : PathResolver.resolve(scope[prefix], remainder)
              else
                begin
                  PathResolver.resolve(item, path)
                rescue MissingDataError
                  PathResolver.resolve(@data, path)
                end
              end
      truthy?(value)
    rescue MissingDataError => e
      raise MissingDataError, "{{#if #{path}}} could not be evaluated: #{e.message}"
    end

    # 展开后的行作用域计划:下标与最终行号一一对应;静态行为 nil
    def build_block_row_records(roots, row_count)
      records = []
      cursor = 0
      roots.each do |node|
        (cursor...node[:block][:open]).each { records << nil }
        append_block_records(node, {}, records)
        cursor = node[:block][:close] + 1
      end
      (cursor...row_count).each { records << nil }
      records
    end

    def append_block_records(node, parent_scope, records)
      block = node[:block]
      node[:items].each_with_index do |item, index|
        scope = parent_scope.merge(block[:prefix] => item)
        record = { scopes: scope, row_item: item }
        append_block_template_records(block, node[:children_by_item][index], scope, records, record,
                                      node[:if_values_by_item][index])
      end
    end

    # 区块内:条件范围按真假取舍,子区块范围由子区块计划替代,其余行各输出一条记录
    def append_block_template_records(block, children, scope, records, record, if_values)
      row = block[:open] + 1
      while row < block[:close]
        if_node = block[:ifs].find { |node| node[:open] == row }
        if if_node
          ((if_node[:open] + 1)...if_node[:close]).each { records << record } if if_values[if_node]
          row = if_node[:close] + 1
          next
        end

        child = children.find { |node| node[:block][:open] == row }
        if child
          append_block_records(child, scope, records)
          row = child[:block][:close] + 1
        else
          records << record
          row += 1
        end
      end
    end

    # 递归展开子区块:先裁剪条件范围,再按模板相对偏移展开子区块
    def expand_block_children(adapter, table, node)
      block = node[:block]
      node[:items].each_index do |index|
        group = node[:groups][index]
        prune_block_ifs(adapter, table, group, block, node[:if_values_by_item][index])

        block[:children].each do |child|
          child_node = node[:children_by_item][index].find { |cn| cn[:block] == child }
          open_el = group[child[:open] - block[:open] - 1]
          close_el = group[child[:close] - block[:open] - 1]
          child_node[:groups] = adapter.clone_table_row_range(
            table[:element], open_el, close_el, child_node[:items].size
          )
          expand_block_children(adapter, table, child_node)
        end
      end
    end

    def prune_block_ifs(adapter, table, group, block, if_values)
      block[:ifs].each do |node|
        open_el = group[node[:open] - block[:open] - 1]
        close_el = group[node[:close] - block[:open] - 1]
        adapter.prune_table_row_range(table[:element], open_el, close_el,
                                      keep_content: if_values[node])
      end
    end

    def fetch_loop_array(binder, path, table, ctx)
      items = binder.value_at(path, ctx)
      return items if items.is_a?(Array)

      raise PowerTom::Error,
            "slide #{table[:slide_no]} table '#{table[:shape]}': " \
            "{{#{path}}} requires an array, got #{items.nil? ? 'nil' : items.class}"
    end

    def fetch_child_array(parent, relative, table, ctx, index)
      value = PathResolver.resolve(parent, relative)
      return value if value.is_a?(Array)

      raise PowerTom::Error,
            "slide #{ctx[:slide_no]} table '#{table[:shape]}': parent item #{index + 1} field " \
            "'#{relative}' requires an array, got #{value.class}"
    rescue MissingDataError => e
      raise MissingDataError,
            "slide #{ctx[:slide_no]} table '#{table[:shape]}': parent item #{index + 1} " \
            "is missing child array '#{relative}' (#{e.message})"
    end

    # 该段落属于哪一行作用域:返回 {"groups[]" => 父项, "groups[].items[]" => 子项}
    def row_scopes_for(scopes, ctx)
      return nil unless ctx[:table_shape]

      scope = scopes[[ctx[:slide_no], ctx[:table_shape]]]
      return nil unless scope

      if scope[:kind] == :blocks
        record = scope[:records][ctx[:row_index]]
        return record ? record[:scopes] : nil
      end
      return nil if scope[:kind] == :grid

      offset = ctx[:row_index] - scope[:start]
      return nil if offset.negative?

      if scope[:kind] == :simple
        return nil if offset >= scope[:count]

        { "#{scope[:root]}[]" => scope[:items][offset] }
      else
        row = scope[:rows][offset]
        return nil unless row

        result = { scope[:parent_prefix] => scope[:parents][row[:parent]] }
        result[scope[:child_prefix]] = scope[:children][row[:parent]][row[:child]] if row[:child]
        result
      end
    end

    # #grid / 区块列带的单元格作用域:{col: 列项, row: 行项, cell: 行列交叉值}
    def grid_scope_for(scopes, ctx)
      return nil unless ctx[:table_shape]

      scope = scopes[[ctx[:slide_no], ctx[:table_shape]]]
      return nil unless scope
      return block_grid_scope(scope, ctx) if scope[:kind] == :blocks
      return nil unless scope[:kind] == :grid

      col_index = ctx[:col_index].to_i
      col = col_index.positive? ? scope[:cols][col_index - 1] : nil
      offset = ctx[:row_index] - scope[:content_start]
      row = offset >= 0 && offset < scope[:rows].size ? scope[:rows][offset] : nil

      grid = {}
      grid[:col] = col if col
      grid[:row] = row if row
      grid[:cell] = -> { GridValue.cell_value(row, col, scope[:value_path]) } if row && col
      grid.empty? ? nil : grid
    end

    def block_grid_scope(scope, ctx)
      band = scope[:band]
      return nil unless band

      col_index = ctx[:col_index].to_i
      start = band[:first_col]
      return nil if col_index < start

      entry = scope[:column_plan][col_index - start]
      return nil unless entry

      col = entry[:col]
      template_index = entry[:template_index]
      value_path = GridValue.band_value_path(band[:value_paths], template_index)
      record = scope[:records][ctx[:row_index]]
      row = record && record[:row_item]

      grid = { col: col }
      if row
        grid[:row] = row
        grid[:cell] = -> { GridValue.cell_value(row, col, value_path) }
      end
      grid
    end

    # 行区块里的当前记录(供 {{row.*}} 使用)
    def row_item_for(scopes, ctx)
      return nil unless ctx[:table_shape]

      scope = scopes[[ctx[:slide_no], ctx[:table_shape]]]
      return nil unless scope && scope[:kind] == :blocks

      record = scope[:records][ctx[:row_index]]
      record && record[:row_item]
    end

    # §2.3 数据有模板未使用的字段 → warning(v0 只追踪顶层字段)
    def report_unused_fields(binder, warnings)
      return unless @data.is_a?(Hash)

      unused = @data.keys.map(&:to_s) - binder.used_root_keys.to_a
      unused.each { |key| warnings << "data field '#{key}' is not used by the template" }
    end

    # §3.3 备注里的普通文本标签 v0 不渲染,记 warning(页级指令除外)
    def report_notes_labels(notes, warnings)
      notes.each do |note|
        Scanner.scan_notes(note[:text], note[:slide_no]).each do |found|
          next if found[:tag] =~ /\{\{\s*#/

          warnings << "slide #{found[:slide_no]} notes contain tag #{found[:tag]}; v0 does not render notes, ignored"
        end
      end
    end
  end
end
