# frozen_string_literal: true

require "set"
require_relative "scanner"
require_relative "table_loop"
require_relative "grid_value"
require_relative "path_resolver"
require_relative "formatter"

module PowerTom
  # 校验条目:level(:error 阻断渲染 / :warning 不阻断)、定位(页码/形状/标签)、原因
  CheckEntry = Struct.new(:level, :slide_no, :shape, :label, :message, keyword_init: true)

  # 校验结果与人话报告(§7):每条问题给出"第 X 页、形状 Y、标签 Z、期望的数据路径"。
  class CheckResult
    attr_reader :entries

    def initialize(template_name, entries)
      @template_name = template_name
      @entries = entries
    end

    def errors = entries.select { |e| e.level == :error }

    def warnings = entries.select { |e| e.level == :warning }

    def ok? = errors.empty?

    def exit_code = ok? ? 0 : 1

    def report
      lines = ["PowerTom 模板校验 — #{@template_name}"]
      entries.each do |e|
        head = head_of(e)
        body = head.empty? ? e.message : "#{head} #{e.message}"
        lines << format("[%-7s] %s", e.level, body)
      end
      lines << "-" * 48
      summary = "#{errors.size} 个 error,#{warnings.size} 个 warning"
      summary += "(error 阻断渲染,修正后再调用 PowerTom.render)" unless ok?
      lines << summary
      lines.join("\n")
    end

    alias to_s report

    private

    def head_of(entry)
      head = []
      head << "第 #{entry.slide_no} 页" if entry.slide_no
      head << "形状'#{entry.shape}'" if entry.shape
      head << "{{#{entry.label}}}" if entry.label
      head.join(" ")
    end
  end

  # 对账器(§7,差异化核心):模板标签 vs 样例数据结构。纯 Ruby,不碰 XML。
  #
  # 与 render 的区别:check 报告问题而不抛异常 —— 语法错误也作为 error 条目输出,
  # CI 通过 exit code 判定。报告分级:
  #   error   引用不存在的字段、指令语法错 → 阻断渲染
  #   warning 未使用字段、占位文本疑似超长、空数组、备注残留标签 → 不阻断
  module Validator
    OVERFLOW_MIN_LENGTH = 20 # 绑定后文本达到该长度才考虑溢出预警
    OVERFLOW_RATIO = 2.0     # 且超过占位标签长度的 2 倍

    module_function

    # contexts: [{slide_no:, shape:, run_texts:}](Adapter 采集)
    # tables:   [{slide_no:, shape:, run_texts:, in_table:}](表格单元格段落)
    # table_structures: [{slide_no:, shape:, rows:, merged_rows:}](表格结构,校验行循环)
    # notes:    [{slide_no:, text:}]
    # pictures: [{slide_no:, shape:, field:}](powertom:image 占位)
    # data:     Hash 或 nil(nil → 跳过字段对账,只做语法与结构检查)
    def check(contexts:, notes:, data:, pictures: [], tables: [], table_structures: [],
              template_name: "template.pptx")
      entries = []
      used_roots = Set.new

      # 1. 备注指令:逐页解析,语法错收集为 error;合法指令做结构对账
      directives = {}
      notes.each do |note|
        directive = begin
          Scanner.directive_for(note)
        rescue TemplateSyntaxError => e
          entries << error_entry(note[:slide_no], "(备注)", nil, strip_location(e.message))
          nil
        end
        next unless directive
        directives[note[:slide_no]] = directive
        used_roots << root_of(directive[:path])
      end

      # 2. 正文标签:逐段校验语法;合法标签按页归组
      labels_by_page = Hash.new { |h, k| h[k] = [] }
      contexts.each do |ctx|
        labels = begin
          Scanner.scan([ctx])
        rescue TemplateSyntaxError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], nil, strip_location(e.message))
          next
        end
        labels.each { |l| labels_by_page[ctx[:slide_no]] << l }
      end

      # 2.2 表格单元格标签(行循环标签在这里出现)
      tables.each do |ctx|
        labels = begin
          Scanner.scan([ctx])
        rescue TemplateSyntaxError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], nil, strip_location(e.message))
          next
        end
        labels.each { |l| labels_by_page[ctx[:slide_no]] << l }
      end

      # 2.3 表格循环结构:#rows/#grid 标记位置、层级、作用域、合并单元格
      table_plans = {}
      table_structures.each do |table|
        plan = TableLoop.plan(table[:rows], merged_rows: table[:merged_rows],
                                            columns: table[:columns])
        table_plans[[table[:slide_no], table[:shape]]] = plan if plan
      rescue TemplateSyntaxError => e
        entries << error_entry(table[:slide_no], table[:shape], nil, e.message)
      end

      # 2.5 formatter 注册对账(§3.4):不依赖样例数据
      labels_by_page.each_value do |labels|
        labels.each do |l|
          next unless l[:spec]
          name = l[:spec].split(".").first
          next if Formatter.registered?(name)
          entries << error_entry(l[:context][:slide_no], l[:context][:shape], l[:path],
                                 "未注册的 formatter '#{name}'" \
                                 "(可用:#{Formatter.registered_names.join(', ')})")
        end
      end

      # 3. 字段对账与溢出预警(需要样例数据)
      if data.nil?
        entries << CheckEntry.new(level: :warning, slide_no: nil, shape: nil, label: nil,
                                  message: "未提供样例数据(DATA),已跳过字段对账与溢出检查")
      else
        directives.each do |slide_no, directive|
          reconcile_directive(directive, slide_no, data, entries)
        end
        labels_by_page.each_value do |labels|
          labels.each do |l|
            grid = grid_plan_for(table_plans, l[:context])
            if grid && grid_variable_path?(l[:path])
              reconcile_grid_label(l, grid, data, entries)
            elsif l[:path].include?("[]")
              reconcile_row_label(l, data, entries)
            else
              reconcile_label(l, directives[l[:context][:slide_no]], data, entries)
            end
          end
        end
        pictures.each do |pctx|
          reconcile_picture(pctx, directives[pctx[:slide_no]], data, entries)
        end
        labels_by_page.each_value do |labels|
          labels.each do |l|
            next if l[:path].include?("[]")
            next if grid_plan_for(table_plans, l[:context]) && grid_variable_path?(l[:path])

            overflow_check(l, directives[l[:context][:slide_no]], data, entries)
          end
        end
        # 未使用字段:#each 页的标签根是数据项字段,不计;指令路径根计入;
        # 图片字段同样计入(image 字段通常是顶层键)
        pictures.each { |pctx| used_roots << root_of(pctx[:field]) }
        labels_by_page.each_value do |labels|
          labels.each do |l|
            directive = directives[l[:context][:slide_no]]
            next if directive && directive[:kind] == :each
            next if grid_plan_for(table_plans, l[:context]) && grid_variable_path?(l[:path])

            used_roots << root_of(l[:path])
          end
        end
        table_plans.each_value do |plan|
          next unless plan[:kind] == :grid

          used_roots << root_of(plan[:grid][:rows_path])
          used_roots << root_of(plan[:grid][:cols_path])
        end
        unused = data.keys.map(&:to_s) - used_roots.to_a
        unused.each do |key|
          entries << CheckEntry.new(level: :warning, slide_no: nil, shape: nil, label: nil,
                                    message: "数据字段 '#{key}' 未被模板使用")
        end
      end

      # 4. 备注残留的普通文本标签(§3.3:v0 不渲染备注)
      notes.each do |note|
        Scanner.scan_notes(note[:text], note[:slide_no]).each do |found|
          next if found[:tag] =~ /\{\{\s*#/
          entries << CheckEntry.new(level: :warning, slide_no: note[:slide_no], shape: "(备注)",
                                    label: nil, message: "备注含标签 #{found[:tag]},v0 不渲染备注,已忽略")
        end
      end

      CheckResult.new(template_name, entries)
    end

    # ---- 内部 ----

    # 指令结构对账:#each 要数组(空数组 → 删组预警);#if 假值 → 删页预警
    def reconcile_directive(directive, slide_no, data, entries)
      path = directive[:path]
      value = begin
        PathResolver.resolve(data, path)
      rescue MissingDataError => e
        entries << error_entry(slide_no, "(备注)", path, e.message)
        return
      end
      if directive[:kind] == :each
        unless value.is_a?(Array)
          entries << error_entry(slide_no, "(备注)", path, "取到 #{value.class},必须为数组")
          return
        end
        if value.empty?
          entries << CheckEntry.new(level: :warning, slide_no: slide_no, shape: "(备注)", label: path,
                                    message: "数组 '#{path}' 为空(0 项):渲染时该组页面将被整组删除")
        end
      elsif value.nil? || value == false
        entries << CheckEntry.new(level: :warning, slide_no: slide_no, shape: "(备注)", label: path,
                                  message: "条件 #{path} 为假:渲染时该页将被删除")
      end
    end

    # 标签对账:普通页对根数据;#each 页对数组的每一项(缺哪项报哪项)
    def reconcile_label(label, directive, data, entries)
      path = label[:path]
      ctx = label[:context]
      if directive && directive[:kind] == :each
        items = begin
          PathResolver.resolve(data, directive[:path])
        rescue MissingDataError
          return # 指令级 error 已单独报告
        end
        return unless items.is_a?(Array)
        items.each_with_index do |item, k|
          begin
            PathResolver.resolve(item, path)
          rescue MissingDataError => e
            entries << error_entry(
              ctx[:slide_no], ctx[:shape], path,
              "数组 '#{directive[:path]}' 第 #{k + 1} 项:#{e.message}" \
              "(期望:#{directive[:path]}[#{k}].#{path})"
            )
          end
        end
      else
        begin
          PathResolver.resolve(data, path)
        rescue MissingDataError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], path, e.message)
        end
      end
    end

    # 溢出预警(§7):autofit 关闭时文字溢出不裁,绑定值显著长于占位标签时提醒
    def overflow_check(label, directive, data, entries)
      ctx = label[:context]
      # 多项循环的标签取首项检查,避免同类警告刷屏
      source = directive && directive[:kind] == :each ? begin
        PathResolver.resolve(data, directive[:path])[0]
      rescue MissingDataError
        nil
      end : data
      return unless source

      value = begin
        PathResolver.resolve(source, label[:path])
      rescue MissingDataError
        return
      end
      return unless value.is_a?(String) || value.is_a?(Numeric)

      rendered = value.to_s.length
      placeholder = label[:path].length + 4 # "{{x}}" 形态的占位长度
      return unless rendered >= OVERFLOW_MIN_LENGTH && rendered >= placeholder * OVERFLOW_RATIO

      entries << CheckEntry.new(
        level: :warning, slide_no: ctx[:slide_no], shape: ctx[:shape], label: label[:path],
        message: "绑定后 #{rendered} 字,是占位标签(#{placeholder} 字)的 " \
                 "#{(rendered.to_f / placeholder).round(1)} 倍,文字可能溢出" \
                 "(autofit 关闭时不裁剪,建议精简文案或加长占位标签)"
      )
    end

    # 图片字段对账(§5.3):与文本标签同一套 #each/普通 语义;额外检查
    # 值必须是 String 且文件真实存在(设计师漏传图是最常见的交付事故)
    def reconcile_picture(pctx, directive, data, entries)
      path = pctx[:field]
      ctx = { slide_no: pctx[:slide_no], shape: pctx[:shape] }
      if directive && directive[:kind] == :each
        items = begin
          PathResolver.resolve(data, directive[:path])
        rescue MissingDataError
          return # 指令级 error 已单独报告
        end
        return unless items.is_a?(Array)
        items.each_with_index do |item, k|
          value = begin
            PathResolver.resolve(item, path)
          rescue MissingDataError => e
            entries << error_entry(
              ctx[:slide_no], ctx[:shape], path,
              "数组 '#{directive[:path]}' 第 #{k + 1} 项:#{e.message}" \
              "(期望:#{directive[:path]}[#{k}].#{path})"
            )
            next
          end
          check_image_value(value, ctx, path, entries, k)
        end
      else
        value = begin
          PathResolver.resolve(data, path)
        rescue MissingDataError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], path, e.message)
          return
        end
        check_image_value(value, ctx, path, entries)
      end
    end

    def check_image_value(value, ctx, path, entries, item_index = nil)
      return if value.nil?
      where = item_index ? "第 #{item_index + 1} 项:" : ""
      unless value.is_a?(String) && !value.empty?
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}图片字段需要 String 文件路径,得到 #{value.class}")
        return
      end
      return if File.file?(value)
      entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                             "#{where}图片文件不存在:#{value}")
    end

    # #grid 变量对账:col.* 对每个列项,row.* 对每个行项,cell 对行列交叉
    def reconcile_grid_label(label, plan, data, entries)
      path = label[:path]
      ctx = label[:context]
      grid = plan[:grid]
      rows = resolve_grid_array(grid[:rows_path], ctx, data, entries)
      cols = resolve_grid_array(grid[:cols_path], ctx, data, entries)
      return if rows.nil? || cols.nil?

      if path == "cell"
        reconcile_grid_cells(ctx, rows, cols, grid[:value_path], entries)
      elsif path.start_with?("row.")
        reconcile_grid_items(path, "row", grid[:rows_path], rows, ctx, entries)
      elsif path.start_with?("col.")
        reconcile_grid_items(path, "col", grid[:cols_path], cols, ctx, entries)
      end
    end

    def resolve_grid_array(path, ctx, data, entries)
      value = begin
        PathResolver.resolve(data, path)
      rescue MissingDataError => e
        entries << error_entry(ctx[:slide_no], ctx[:shape], path, e.message)
        return nil
      end

      unless value.is_a?(Array)
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "取到 #{value.class},grid 需要数组")
        return nil
      end
      if value.empty?
        entries << CheckEntry.new(level: :warning, slide_no: ctx[:slide_no], shape: ctx[:shape],
                                  label: path,
                                  message: "数组 '#{path}' 为空:渲染时该方向的单元格会被移除")
      end
      value
    end

    # {{row.字段}} / {{col.字段}}:逐项对账,指出第几项与期望路径
    def reconcile_grid_items(path, prefix, array_path, items, ctx, entries)
      remainder = path.delete_prefix(prefix).delete_prefix(".")
      items.each_with_index do |item, k|
        PathResolver.resolve(item, remainder)
      rescue MissingDataError => e
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "数组 '#{array_path}' 第 #{k + 1} 项:#{e.message}" \
                               "(期望:#{array_path}[#{k}].#{remainder})")
      end
    end

    # {{cell}}:逐个行列交叉检查取值(有 value: 时先下钻到嵌套 Hash)
    def reconcile_grid_cells(ctx, rows, cols, value_path, entries)
      rows.each_with_index do |row, r|
        cols.each_with_index do |col, c|
          GridValue.cell_value(row, col, value_path)
        rescue MissingDataError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], "cell",
                                 "第 #{r + 1} 行 × 第 #{c + 1} 列:#{e.message}")
        end
      end
    end

    def grid_plan_for(plans, context)
      return nil unless context[:table_shape]

      plan = plans[[context[:slide_no], context[:table_shape]]]
      plan && plan[:kind] == :grid ? plan : nil
    end

    def grid_variable_path?(path)
      path == "cell" || path == "row" || path.start_with?("row.") ||
        path == "col" || path.start_with?("col.")
    end

    # 表格行循环标签:{{数组[].字段}} / {{父[].子[].字段}} 逐级对账;
    # 空数组提醒行会被移除,缺字段指出第几项与期望的具体路径
    def reconcile_row_label(label, data, entries)
      path = label[:path]
      ctx = label[:context]
      reconcile_loop_level(path, data, "", "", ctx, entries, path)
    end

    # path: 剩余路径;data: 当前层数据;concrete: 已展开的具体路径前缀;
    # where: 错误消息前缀(如 "数组 'classes' 第 1 项:")
    def reconcile_loop_level(path, data, concrete, where, ctx, entries, original)
      return PathResolver.resolve(data, path) unless path.include?("[]")

      root, rest = path.split("[]", 2)
      rest = rest.to_s.sub(/\A\./, "")

      array = begin
        PathResolver.resolve(data, root)
      rescue MissingDataError => e
        entries << error_entry(ctx[:slide_no], ctx[:shape], original, "#{where}#{e.message}")
        return
      end

      unless array.is_a?(Array)
        entries << error_entry(ctx[:slide_no], ctx[:shape], original,
                               "#{where}取到 #{array.class},行循环需要数组")
        return
      end
      if array.empty?
        entries << CheckEntry.new(level: :warning, slide_no: ctx[:slide_no], shape: ctx[:shape],
                                  label: original,
                                  message: "#{where}数组 '#{root}' 为空:渲染时表格循环行会被移除")
        return
      end
      return if rest.empty?

      array.each_with_index do |item, k|
        reconcile_loop_level(
          rest, item, "#{concrete}#{root}[#{k}].",
          "#{where}数组 '#{root}' 第 #{k + 1} 项:", ctx, entries, original
        )
      end
    rescue MissingDataError => e
      entries << error_entry(ctx[:slide_no], ctx[:shape], original,
                             "#{where}#{e.message}(期望:#{concrete}#{path})")
    end

    def error_entry(slide_no, shape, label, message)
      CheckEntry.new(level: :error, slide_no: slide_no, shape: shape, label: label, message: message)
    end

    def root_of(path)
      path.split(".").first[/\A[A-Za-z0-9_]+/] || path
    end

    # Scanner 的错误消息自带页码/形状前缀,条目里已有定位字段,剥掉避免重复
    def strip_location(message)
      message.sub(/\A第 \d+ 页 形状'[^']*':/, "").sub(/\A第 \d+ 页备注:?/, "").sub(/\A第 \d+ 页:?/, "")
    end
  end
end
