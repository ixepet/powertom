# frozen_string_literal: true

require "fileutils"
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

  class RenderResult
    attr_reader :warnings

    def initialize(adapter, prs, warnings, temp_path: nil)
      @adapter = adapter
      @prs = prs
      @warnings = warnings
      @temp_path = temp_path
    end

    def save(path)
      @adapter.save(@prs, path)
      FileUtils.remove_entry(@temp_path, true) if @temp_path
      path
    end

    # 成品页数(埋点与断言用;克隆/删页之后的结果)
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
        page_scopes = {}
        pages.each_with_index do |p, i|
          page_scopes[i] = { scope: p[:scope], scope_root: p[:scope_root] }
        end
        page_scopes.default = { scope: nil, scope_root: nil }
      end

      # 表格行循环:按数组长度展开模板行,再采集单元格段落做绑定
      table_scopes = expand_table_rows(adapter, work_prs, page_scopes, binder)

      contexts = adapter.paragraph_contexts(work_prs) + adapter.table_cell_contexts(work_prs)
      contexts.each do |ctx|
        page = page_scopes[ctx[:slide_no] - 1]
        row_scopes = row_scopes_for(table_scopes, ctx)
        grid_scope = grid_scope_for(table_scopes, ctx)
        bctx = ctx.merge(scope: page[:scope], scope_root: page[:scope_root],
                         row_scopes: row_scopes, grid_scope: grid_scope)
        new_texts = RunMerge.merge(
          ctx[:run_texts],
          ->(path, spec) { binder.render_label(path, bctx, spec: spec) }
        )
        adapter.write_paragraph_runs(ctx[:paragraph], new_texts) if new_texts
      end

      replace_images(adapter, work_prs, page_scopes, binder)

      report_unused_fields(binder, warnings)
      report_notes_labels(notes, warnings)

      RenderResult.new(adapter, work_prs, warnings,
                       temp_path: directives.empty? ? nil : @work_path)
    end

    private

    # §3.3:#each 按数组克隆(K=数组长度,空数组整组删除);#if 为假删页。
    # 返回 [{source:, iteration:, scope:, scope_root:}] 按输出顺序。
    def build_page_plan(directives, binder, slide_count)
      pages = []
      (1..slide_count).each do |no|
        directive = directives[no]
        ctx = { slide_no: no, shape: "(备注指令)" }
        if directive.nil?
          pages << { source: no, iteration: nil, scope: nil, scope_root: nil }
        elsif directive[:kind] == :if
          value = binder.value_at(directive[:path], ctx)
          pages << { source: no, iteration: nil, scope: nil, scope_root: nil } if truthy?(value)
        else
          value = binder.value_at(directive[:path], ctx)
          if value.nil?
            raise MissingDataError,
                  "第 #{no} 页备注 {{#each #{directive[:path]}}}:数据缺少 #{directive[:path]},无法确定循环次数"
          end
          unless value.is_a?(Array)
            raise PowerTom::Error,
                  "第 #{no} 页备注 {{#each #{directive[:path]}}}:取到 #{value.class},必须为数组"
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
    def run_surgery(adapter, pages)
      tmp = Tempfile.create(["powertom_surgery", ".pptx"])
      tmp.close
      @work_path = tmp.path
      Adapter::PageSurgery.execute(@template_path, @work_path, pages)
    end

    # §5.3 图片替换:powertom:image:字段名 占位 → 数据里的图片文件。
    # 与文本一样作用域感知:#each 克隆页各自取本项的图片;缺字段(strict: false)
    # 时保留占位图并记 warning。
    def replace_images(adapter, prs, page_scopes, binder)
      adapter.picture_contexts(prs).each do |pctx|
        page = page_scopes[pctx[:slide_no] - 1]
        ctx = { slide_no: pctx[:slide_no], shape: pctx[:shape],
                scope: page[:scope], scope_root: page[:scope_root] }
        value = binder.value_at(pctx[:field], ctx, purpose: "图片占位,保留占位图")
        next if value.nil? # 缺失(non-strict):保留占位图
        unless value.is_a?(String) && !value.empty?
          raise PowerTom::Error,
                "第 #{pctx[:slide_no]} 页 图片字段 '#{pctx[:field]}' 需要 String 文件路径," \
                "得到 #{value.class}"
        end
        unless File.file?(value)
          raise PowerTom::Error,
                "第 #{pctx[:slide_no]} 页 图片字段 '#{pctx[:field]}' 的文件不存在:#{value}"
        end
        adapter.replace_image(pctx[:slide], pctx[:picture], value)
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
                "第 #{table[:slide_no]} 页 表格'#{table[:shape]}':" \
                "页级 #each 与表格行循环暂不支持叠加(只支持一层循环)"
        end

        scopes[[table[:slide_no], table[:shape]]] = case plan[:kind]
                                                    when :simple
                                                      expand_simple_rows(adapter, table, plan, binder)
                                                    when :nested
                                                      expand_nested_rows(adapter, table, plan, binder)
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
      raise TemplateSyntaxError, "第 #{table[:slide_no]} 页 表格'#{table[:shape]}':#{e.message}"
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
              "第 #{ctx[:slide_no]} 页 表格'#{table[:shape]}':" \
              "列数据第 #{index + 1} 项#{e.message}"
      end
    end

    def fetch_loop_array(binder, path, table, ctx)
      items = binder.value_at(path, ctx)
      return items if items.is_a?(Array)

      raise PowerTom::Error,
            "第 #{table[:slide_no]} 页 表格'#{table[:shape]}':" \
            "{{#{path}}} 需要数组,得到 #{items.nil? ? '空值' : items.class}"
    end

    def fetch_child_array(parent, relative, table, ctx, index)
      value = PathResolver.resolve(parent, relative)
      return value if value.is_a?(Array)

      raise PowerTom::Error,
            "第 #{ctx[:slide_no]} 页 表格'#{table[:shape]}':父级第 #{index + 1} 项的" \
            "'#{relative}' 需要数组,得到 #{value.class}"
    rescue MissingDataError => e
      raise MissingDataError,
            "第 #{ctx[:slide_no]} 页 表格'#{table[:shape]}':父级第 #{index + 1} 项" \
            "缺少子数组 '#{relative}'(#{e.message})"
    end

    # 该段落属于哪一行作用域:返回 {"groups[]" => 父项, "groups[].items[]" => 子项}
    def row_scopes_for(scopes, ctx)
      return nil unless ctx[:table_shape]

      scope = scopes[[ctx[:slide_no], ctx[:table_shape]]]
      return nil unless scope
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
        if row[:child]
          result[scope[:child_prefix]] = scope[:children][row[:parent]][row[:child]]
        end
        result
      end
    end

    # #grid 单元格作用域:{col: 列项, row: 行项, cell: 行列交叉值}
    # 首列没有 col;非内容行没有 row。交叉值延迟到真正使用 {{cell}} 时计算。
    def grid_scope_for(scopes, ctx)
      return nil unless ctx[:table_shape]

      scope = scopes[[ctx[:slide_no], ctx[:table_shape]]]
      return nil unless scope && scope[:kind] == :grid

      col_index = ctx[:col_index].to_i
      col = col_index.positive? ? scope[:cols][col_index - 1] : nil
      offset = ctx[:row_index] - scope[:content_start]
      row = offset >= 0 && offset < scope[:rows].size ? scope[:rows][offset] : nil

      grid = {}
      grid[:col] = col if col
      grid[:row] = row if row
      if row && col
        grid[:cell] = -> { GridValue.cell_value(row, col, scope[:value_path]) }
      end
      grid.empty? ? nil : grid
    end

    # §2.3 数据有模板未使用的字段 → warning(v0 只追踪顶层字段)
    def report_unused_fields(binder, warnings)
      return unless @data.is_a?(Hash)
      unused = @data.keys.map(&:to_s) - binder.used_root_keys.to_a
      unused.each { |key| warnings << "数据字段 '#{key}' 未被模板使用" }
    end

    # §3.3 备注里的普通文本标签 v0 不渲染,记 warning(页级指令除外)
    def report_notes_labels(notes, warnings)
      notes.each do |note|
        Scanner.scan_notes(note[:text], note[:slide_no]).each do |found|
          next if found[:tag] =~ /\{\{\s*#/
          warnings << "第 #{found[:slide_no]} 页备注含标签 #{found[:tag]},v0 不渲染备注,已忽略"
        end
      end
    end
  end
end
