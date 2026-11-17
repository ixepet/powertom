# frozen_string_literal: true

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
    # @return [Array<PowerTom::CheckEntry>] all entries, errors and warnings.
    attr_reader :entries

    def initialize(template_name, entries)
      @template_name = template_name
      @entries = entries
    end

    # @return [Array<PowerTom::CheckEntry>] entries that block rendering.
    def errors = entries.select { |e| e.level == :error }

    # @return [Array<PowerTom::CheckEntry>] non-blocking entries.
    def warnings = entries.select { |e| e.level == :warning }

    # @return [Boolean] true when there is no error.
    def ok? = errors.empty?

    # @return [Integer] 0 when valid, 1 otherwise (for CI).
    def exit_code = ok? ? 0 : 1

    # @return [String] human-readable, one line per entry.
    def report
      lines = ["PowerTom template check — #{@template_name}"]
      entries.each do |e|
        head = head_of(e)
        body = head.empty? ? e.message : "#{head} #{e.message}"
        lines << format("[%-7s] %s", e.level, body)
      end
      lines << ("-" * 48)
      summary = "#{errors.size} error(s), #{warnings.size} warning(s)"
      summary += " (errors block rendering; fix them before calling PowerTom.render)" unless ok?
      lines << summary
      lines.join("\n")
    end

    alias to_s report

    private

    def head_of(entry)
      head = []
      head << "slide #{entry.slide_no}" if entry.slide_no
      head << "shape '#{entry.shape}'" if entry.shape
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
    def check(contexts:, notes:, data:, pictures: [], charts: [], tables: [], table_structures: [],
              chart_placeholders: [], template_name: "template.pptx")
      entries = []
      used_roots = Set.new

      # 1. 备注指令:逐页解析,语法错收集为 error;合法指令做结构对账
      directives = {}
      notes.each do |note|
        directive = begin
          Scanner.directive_for(note)
        rescue TemplateSyntaxError => e
          entries << error_entry(note[:slide_no], "(notes)", nil, strip_location(e.message))
          nil
        end
        next unless directive

        directives[note[:slide_no]] = directive
        used_roots << root_of(directive[:path])
      end

      # 2. 正文标签:逐段校验语法;合法标签按页归组
      labels_by_page = Hash.new { |h, k| h[k] = [] }
      labels_by_table_row = Hash.new { |h, k| h[k] = [] }
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
        labels.each do |l|
          labels_by_page[ctx[:slide_no]] << l
          labels_by_table_row[[ctx[:slide_no], ctx[:table_shape], ctx[:row_index]]] << l if ctx[:table_shape]
        end
      end

      # 2.3 表格循环结构:#rows/#grid/#cols 标记位置、层级、作用域、合并单元格
      table_plans = {}
      failed_tables = Set.new
      table_structures.each do |table|
        plan = TableLoop.plan(table[:rows], merged_rows: table[:merged_rows],
                                            columns: table[:columns])
        table_plans[[table[:slide_no], table[:shape]]] = plan if plan
      rescue TemplateSyntaxError => e
        failed_tables << [table[:slide_no], table[:shape]]
        entries << error_entry(table[:slide_no], table[:shape], nil, e.message)
      end
      block_row_stacks = {}
      table_plans.each do |key, plan|
        block_row_stacks[key] = TableLoop.build_row_stacks(plan[:blocks]) if plan[:kind] == :blocks
      end

      # 2.5 formatter 注册对账(§3.4):不依赖样例数据
      labels_by_page.each_value do |labels|
        labels.each do |l|
          next unless l[:spec]

          name = l[:spec].split(".").first
          next if Formatter.registered?(name)

          entries << error_entry(l[:context][:slide_no], l[:context][:shape], l[:path],
                                 "unregistered formatter '#{name}' " \
                                 "(available: #{Formatter.registered_names.join(', ')})")
        end
      end

      # 2.6 图表类型守卫:命名占位本身即声明绑定意图,不支持类型直接报 error
      # (combo/XY/BUBBLE 是支持的 kind,走 reconcile 阶段的系列数量规则)。
      # 这是模板属性,不依赖样例数据,与字段对账分开检查
      chart_placeholders.each do |cctx|
        kind = cctx[:kind]
        next unless unsupported_kind?(kind)

        entries << error_entry(
          cctx[:slide_no], cctx[:shape], cctx[:field],
          "#{kind_label(kind)} charts are not supported for data binding " \
          "(supported: column/bar, line, area, pie, doughnut, combo, scatter, bubble)"
        )
      end

      # 3. 字段对账与溢出预警(需要样例数据)
      if data.nil?
        entries << CheckEntry.new(level: :warning, slide_no: nil, shape: nil, label: nil,
                                  message: "no sample data (DATA) provided; " \
                                           "field reconciliation and overflow checks were skipped")
      else
        directives.each do |slide_no, directive|
          reconcile_directive(directive, slide_no, data, entries)
        end
        labels_by_page.each_value do |labels|
          labels.each do |l|
            ctx = l[:context]
            next if ctx[:table_shape] && failed_tables.include?([ctx[:slide_no], ctx[:table_shape]])
            next if block_row_stacks.dig([ctx[:slide_no], ctx[:table_shape]], ctx[:row_index])
            next if block_band_cell?(table_plans, ctx)

            grid = grid_plan_for(table_plans, ctx)
            if grid && grid_variable_path?(l[:path])
              reconcile_grid_label(l, grid, data, entries)
            elsif l[:path].include?("[]")
              reconcile_row_label(l, data, entries)
            else
              reconcile_label(l, directives[l[:context][:slide_no]], data, entries)
            end
          end
        end
        reconcile_block_tables(table_plans, labels_by_table_row, data, entries)
        pictures.each do |pctx|
          reconcile_picture(pctx, directives[pctx[:slide_no]], data, entries)
        end
        chart_placeholders.each do |cctx|
          reconcile_chart_placeholder(cctx, directives[cctx[:slide_no]], data, entries)
        end
        labels_by_page.each_value do |labels|
          labels.each do |l|
            next if l[:path].include?("[]")
            next if block_row_stacks.dig([l[:context][:slide_no], l[:context][:table_shape]],
                                         l[:context][:row_index])
            next if block_band_cell?(table_plans, l[:context])
            next if grid_plan_for(table_plans, l[:context]) && grid_variable_path?(l[:path])

            overflow_check(l, directives[l[:context][:slide_no]], data, entries)
          end
        end
        # 未使用字段:#each 页的标签根是数据项字段,不计;指令路径根计入;
        # 图片与图表字段同样计入(通常为顶层键)
        pictures.each { |pctx| used_roots << root_of(pctx[:field]) }
        chart_placeholders.each { |cctx| used_roots << root_of(cctx[:field]) }
        labels_by_page.each_value do |labels|
          labels.each do |l|
            directive = directives[l[:context][:slide_no]]
            next if directive && directive[:kind] == :each

            if block_row_stacks.dig([l[:context][:slide_no], l[:context][:table_shape]],
                                    l[:context][:row_index])
              used_roots << root_of(l[:path]) unless grid_variable_path?(l[:path])
              next
            end
            if block_band_cell?(table_plans, l[:context])
              used_roots << root_of(l[:path]) unless grid_variable_path?(l[:path])
              next
            end
            next if grid_plan_for(table_plans, l[:context]) && grid_variable_path?(l[:path])

            used_roots << root_of(l[:path])
          end
        end
        table_plans.each_value do |plan|
          case plan[:kind]
          when :grid
            used_roots << root_of(plan[:grid][:rows_path])
            used_roots << root_of(plan[:grid][:cols_path])
          when :blocks
            each_block(plan[:blocks]) do |block|
              used_roots << root_of(block[:path])
              block[:ifs].each { |node| used_roots << root_of(node[:path]) }
            end
            used_roots << root_of(plan[:cols][:path]) if plan[:cols]
          end
        end
        unused = data.keys.map(&:to_s) - used_roots.to_a
        unused.each do |key|
          entries << CheckEntry.new(level: :warning, slide_no: nil, shape: nil, label: nil,
                                    message: "data field '#{key}' is not used by the template")
        end
      end

      # 4. 备注残留的普通文本标签(§3.3:v0 不渲染备注)
      notes.each do |note|
        Scanner.scan_notes(note[:text], note[:slide_no]).each do |found|
          next if found[:tag] =~ /\{\{\s*#/

          entries << CheckEntry.new(level: :warning, slide_no: note[:slide_no], shape: "(notes)",
                                    label: nil,
                                    message: "notes contain tag #{found[:tag]}; v0 does not render notes, ignored")
        end
      end

      # 5. 图表不绑定数据:保留标签并告警,而不是静默忽略
      charts.each do |chart|
        entries << CheckEntry.new(
          level: :warning, slide_no: chart[:slide_no], shape: chart[:shape], label: nil,
          message: "chart contains tags #{chart[:tags].join(', ')}: " \
                   "text tags inside charts are not supported; tags are left as-is"
        )
      end

      CheckResult.new(template_name, entries)
    end

    # ---- 内部 ----

    # 与 adapter 的 SUPPORTED_PLOT_TYPES 判定保持一致(引用同一常量)
    def unsupported_kind?(kind)
      Adapter::RubyPptxAdapter.unsupported_chart_kind?(kind)
    end

    def kind_label(kind)
      Adapter::RubyPptxAdapter.unsupported_chart_kind_label(kind)
    end

    # 指令结构对账:#each 要数组(空数组 → 删组预警);#if 假值 → 删页预警
    def reconcile_directive(directive, slide_no, data, entries)
      path = directive[:path]
      value = begin
        PathResolver.resolve(data, path)
      rescue MissingDataError => e
        entries << error_entry(slide_no, "(notes)", path, e.message)
        return
      end
      if directive[:kind] == :each
        unless value.is_a?(Array)
          entries << error_entry(slide_no, "(notes)", path, "expected an array, got #{value.class}")
          return
        end
        if value.empty?
          entries << CheckEntry.new(level: :warning, slide_no: slide_no, shape: "(notes)", label: path,
                                    message: "array '#{path}' is empty (0 items): " \
                                             "the whole page group will be removed at render time")
        end
      elsif value.nil? || value == false
        entries << CheckEntry.new(level: :warning, slide_no: slide_no, shape: "(notes)", label: path,
                                  message: "condition #{path} is falsy: this page will be removed at render time")
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
          PathResolver.resolve(item, path)
        rescue MissingDataError => e
          entries << error_entry(
            ctx[:slide_no], ctx[:shape], path,
            "array '#{directive[:path]}' item #{k + 1}: #{e.message} " \
            "(expected: #{directive[:path]}[#{k}].#{path})"
          )
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
      source = if directive && directive[:kind] == :each
                 begin
                   PathResolver.resolve(data, directive[:path])[0]
                 rescue MissingDataError
                   nil
                 end
               else
                 data
               end
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
        message: "after binding, #{rendered} characters is " \
                 "#{(rendered.to_f / placeholder).round(1)}x the placeholder tag (#{placeholder} characters); " \
                 "text may overflow (autofit is off, so it will not be clipped; " \
                 "shorten the copy or lengthen the placeholder tag)"
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
              "array '#{directive[:path]}' item #{k + 1}: #{e.message} " \
              "(expected: #{directive[:path]}[#{k}].#{path})"
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

      where = item_index ? "item #{item_index + 1}: " : ""
      unless value.is_a?(String) && !value.empty?
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}picture field requires a String file path, got #{value.class}")
        return
      end
      return if File.file?(value)

      entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                             "#{where}picture file does not exist: #{value}")
    end

    # 图表占位对账(powertom:chart:*):与图片同一套 #each/普通语义,
    # 额外校验 {categories:, series: [{name:, values:}]} 的数据形状
    def reconcile_chart_placeholder(cctx, directive, data, entries)
      path = cctx[:field]
      ctx = { slide_no: cctx[:slide_no], shape: cctx[:shape] }
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
              "array '#{directive[:path]}' item #{k + 1}: #{e.message} " \
              "(expected: #{directive[:path]}[#{k}].#{path})"
            )
            next
          end
          check_chart_value(value, ctx, path, entries, k)
          check_chart_series_count(value, cctx, entries, k)
        end
      else
        value = begin
          PathResolver.resolve(data, path)
        rescue MissingDataError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], path, e.message)
          return
        end
        if %i[XY BUBBLE].include?(cctx[:kind])
          check_xy_chart_value(value, ctx, path, entries, cctx)
        else
          check_chart_value(value, ctx, path, entries)
        end
        check_chart_series_count(value, cctx, entries)
      end
    end

    # 绑定系列数守卫(check 侧,设计文档 §9):绑定系列数必须等于模板的
    # 系列总数,否则渲染时上游会静默增删 plot(与 render 同一规则);
    # combo 与 XY 家族(scatter/bubble)通用
    def check_chart_series_count(value, cctx, entries, item_index = nil)
      return if value.nil?
      return unless %i[combo XY BUBBLE].include?(cctx[:kind])

      series = value.key?(:series) ? value[:series] : value["series"]
      return unless series.is_a?(Array)

      return if series.size == cctx[:series_count]

      where = item_index ? "item #{item_index + 1}: " : ""
      entries << error_entry(
        cctx[:slide_no], cctx[:shape], cctx[:field],
        "#{where}chart template draws #{cctx[:distribution]} (#{cctx[:series_count]} series in " \
        "total); the data must provide exactly #{cctx[:series_count]} series in document " \
        "order, got #{series.size}"
      )
    end

    # 散点/气泡数据形状校验(check 侧,与 render 的 validate_xy_chart_data!
    # 同一规则):误传 categories、points 非坐标对、x/y/size 非数字都报 error
    def check_xy_chart_value(value, ctx, path, entries, cctx)
      return if value.nil?

      unless value.is_a?(Hash)
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "chart field requires an object with 'series' (each with 'points'), " \
                               "got #{value.class}")
        return
      end

      slide_no = ctx[:slide_no]
      shape = ctx[:shape]
      if value.key?(:categories) || value.key?("categories")
        entries << error_entry(slide_no, shape, path,
                               "scatter/bubble data has no 'categories'; each series carries its own 'points'")
        return
      end

      series = value.key?(:series) ? value[:series] : value["series"]
      unless series.is_a?(Array) && !series.empty?
        entries << error_entry(slide_no, shape, path,
                               "chart 'series' must be a non-empty array of {name, points}")
        return
      end

      bubble = cctx[:kind] == :BUBBLE
      series.each_with_index do |item, i|
        unless item.is_a?(Hash)
          entries << error_entry(slide_no, shape, path,
                                 "series item #{i + 1} must be an object with 'name' and 'points', " \
                                 "got #{item.class}")
          next
        end

        name = item.key?(:name) ? item[:name] : item["name"]
        points = item.key?(:points) ? item[:points] : item["points"]
        unless points.is_a?(Array) && !points.empty?
          entries << error_entry(slide_no, shape, path,
                                 "series '#{name}' 'points' must be a non-empty array of " \
                                 "{x, y#{', size' if bubble}}")
          next
        end

        points.each_with_index do |point, k|
          unless point.is_a?(Hash)
            entries << error_entry(slide_no, shape, path,
                                   "series '#{name}' point #{k + 1} must be an object with 'x' and 'y', " \
                                   "got #{point.class}")
            next
          end

          (bubble ? %w[x y size] : %w[x y]).each do |key|
            v = point.key?(key.to_sym) ? point[key.to_sym] : point[key.to_s]
            next if v.is_a?(Numeric)

            entries << error_entry(slide_no, shape, path,
                                   "series '#{name}' point #{k + 1} '#{key}' must be a number, got #{v.class}")
          end
        end
      end
    end

    def check_chart_value(value, ctx, path, entries, item_index = nil)
      return if value.nil? # 渲染(non-strict)时保留占位图表,与图片一致

      where = item_index ? "item #{item_index + 1}: " : ""
      unless value.is_a?(Hash)
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}chart field requires an object with 'categories' and " \
                               "'series', got #{value.class}")
        return
      end

      categories = value.key?(:categories) ? value[:categories] : value["categories"]
      unless categories.is_a?(Array) && !categories.empty? &&
             categories.all? { |c| c.is_a?(String) || c.is_a?(Numeric) }
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}chart 'categories' must be a non-empty array of strings or numbers")
        return
      end

      series = value.key?(:series) ? value[:series] : value["series"]
      unless series.is_a?(Array) && !series.empty?
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}chart 'series' must be a non-empty array of {name, values}")
        return
      end

      series.each_with_index do |item, i|
        unless item.is_a?(Hash)
          entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                                 "#{where}series item #{i + 1} must be an object with 'name' and " \
                                 "'values', got #{item.class}")
          next
        end
        values = item.key?(:values) ? item[:values] : item["values"]
        next if values.is_a?(Array) && values.size == categories.size && values.all?(Numeric)

        name = item.key?(:name) ? item[:name] : item["name"]
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}series '#{name || "##{i + 1}"}' 'values' must be an array " \
                               "of #{categories.size} numbers")
      end
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
                               "expected an array for the loop, got #{value.class}")
        return nil
      end
      if value.empty?
        entries << CheckEntry.new(level: :warning, slide_no: ctx[:slide_no], shape: ctx[:shape],
                                  label: path,
                                  message: "array '#{path}' is empty: " \
                                           "cells in this direction will be removed at render time")
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
                               "array '#{array_path}' item #{k + 1}: #{e.message} " \
                               "(expected: #{array_path}[#{k}].#{remainder})")
      end
    end

    # {{cell}}:逐个行列交叉检查取值(有 value: 时先下钻到嵌套 Hash)
    def reconcile_grid_cells(ctx, rows, cols, value_path, entries)
      rows.each_with_index do |row, r|
        cols.each_with_index do |col, c|
          GridValue.cell_value(row, col, value_path)
        rescue MissingDataError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], "cell",
                                 "row #{r + 1}, column #{c + 1}: #{e.message}")
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

    # 该单元格是否位于区块表格的列带范围内(含不在行区块内的表头行)
    def block_band_cell?(plans, context)
      return false unless context[:table_shape]

      plan = plans[[context[:slide_no], context[:table_shape]]]
      return false unless plan && plan[:kind] == :blocks && plan[:cols]

      band = plan[:cols]
      context[:col_index].to_i.between?(band[:first_col], band[:last_col])
    end

    # ---- v0.2.0:行区块 + 列带对账 ----

    def reconcile_block_tables(plans, labels_by_row, data, entries)
      plans.each do |(slide_no, shape), plan|
        next unless plan[:kind] == :blocks

        ctx = { slide_no: slide_no, shape: shape }
        cols = plan[:cols] ? (resolve_grid_array(plan[:cols][:path], ctx, data, entries) || []) : []
        reconcile_column_ifs(plan[:cols], cols, ctx, data, entries)
        reconcile_static_band_header(plan, cols, labels_by_row, ctx, data, entries)
        reconcile_blocks(plan[:blocks], {}, nil, cols, plan[:cols], labels_by_row, ctx, data, entries)
      end
    end

    # 列带表头若不在行区块内,其 {{col.*}} 也要单独对账
    def reconcile_static_band_header(plan, cols, labels_by_row, ctx, data, entries)
      band = plan[:cols]
      return unless band

      stacks = TableLoop.build_row_stacks(plan[:blocks])
      return unless stacks[band[:row]].nil?

      labels_by_row[[ctx[:slide_no], ctx[:shape], band[:row]]].each do |label|
        reconcile_block_label(label, {}, nil, cols, band, "column band", data, entries)
      end
    end

    # 列条件:每个列项都要能取到条件字段
    def reconcile_column_ifs(band, cols, ctx, data, entries)
      return unless band && band[:ifs]&.any?

      band[:ifs].each do |node|
        cols.each_with_index do |col, index|
          GridValue.column_condition_value(node[:path], col, band[:path], data)
        rescue MissingDataError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], node[:path],
                                 "column condition item #{index + 1}: #{e.message}")
        end
      end
    end

    # 与渲染同一套行计划:按区块逐项展开,再对每一行模板里的标签对账
    def reconcile_blocks(blocks, parent_scope, parent_item, cols, band,
                         labels_by_row, ctx, data, entries)
      blocks.each do |block|
        items = block_array(block, parent_item, ctx, data, entries)
        next if items.nil?

        if items.empty?
          entries << CheckEntry.new(level: :warning, slide_no: ctx[:slide_no], shape: ctx[:shape],
                                    label: block[:path],
                                    message: "array '#{block[:path]}' is empty: " \
                                             "this row block will be removed at render time")
          next
        end

        items.each_with_index do |item, index|
          scope = parent_scope.merge(block[:prefix] => item)
          where = "block #{block[:path]} item #{index + 1}"
          row = block[:open] + 1
          while row < block[:close]
            if_node = block[:ifs].find { |n| n[:open] == row }
            if if_node
              if block_condition_true?(if_node[:path], item, scope, ctx, data, entries, where)
                ((if_node[:open] + 1)...if_node[:close]).each do |r|
                  labels_by_row[[ctx[:slide_no], ctx[:shape], r]].each do |label|
                    reconcile_block_label(label, scope, item, cols, band, where, data, entries)
                  end
                end
              end
              row = if_node[:close] + 1
              next
            end

            child = block[:children].find { |c| c[:open] == row }
            if child
              reconcile_blocks([child], scope, item, cols, band, labels_by_row, ctx, data, entries)
              row = child[:close] + 1
            else
              labels_by_row[[ctx[:slide_no], ctx[:shape], row]].each do |label|
                reconcile_block_label(label, scope, item, cols, band, where, data, entries)
              end
              row += 1
            end
          end
        end
      end
    end

    def block_array(block, parent_item, ctx, data, entries)
      value = if parent_item
                PathResolver.resolve(parent_item, block[:relative])
              else
                PathResolver.resolve(data, block[:path])
              end
      unless value.is_a?(Array)
        entries << error_entry(ctx[:slide_no], ctx[:shape], block[:path],
                               "expected an array for the row block, got #{value.class}")
        return nil
      end
      value
    rescue MissingDataError => e
      message = parent_item ? "parent item is missing '#{block[:relative]}' (#{e.message})" : e.message
      entries << error_entry(ctx[:slide_no], ctx[:shape], block[:path], message)
      nil
    end

    # #if 条件求值:含 [] 走作用域栈;否则先看当前记录,再看整页数据
    def block_condition_true?(path, item, scope, ctx, data, entries, where)
      value = if path.include?("[]")
                prefix = scope.keys.select { |key| path == key || path.start_with?("#{key}.") }
                              .max_by(&:length)
                if prefix.nil?
                  entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                                         "#{where}: condition path is not inside the row block scope")
                  return false
                end
                remainder = path.delete_prefix(prefix).delete_prefix(".")
                remainder.empty? ? scope[prefix] : PathResolver.resolve(scope[prefix], remainder)
              else
                begin
                  PathResolver.resolve(item, path)
                rescue MissingDataError
                  PathResolver.resolve(data, path)
                end
              end
      !(value.nil? || value == false)
    rescue MissingDataError => e
      entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                             "#{where}: condition evaluation failed: #{e.message}")
      false
    end

    def reconcile_block_label(label, scope, row_item, cols, band, where, data, entries)
      path = label[:path]
      ctx = label[:context]
      if path == "cell"
        reconcile_block_cells(ctx, row_item, cols, band, where, entries)
      elsif path.start_with?("row.")
        reconcile_row_item_path(ctx, path, row_item, where, entries)
      elsif path.start_with?("col.")
        reconcile_col_item_path(ctx, path, cols, where, entries)
      elsif path.include?("[]")
        reconcile_block_scope_path(label, scope, where, entries)
      else
        reconcile_page_path(ctx, path, data, entries)
      end
    end

    def reconcile_row_item_path(ctx, path, row_item, where, entries)
      remainder = path.delete_prefix("row.")
      PathResolver.resolve(row_item, remainder)
    rescue MissingDataError => e
      entries << error_entry(ctx[:slide_no], ctx[:shape], path, "#{where}:#{e.message}")
    end

    def reconcile_col_item_path(ctx, path, cols, where, entries)
      remainder = path.delete_prefix("col.")
      cols.each_with_index do |col, index|
        PathResolver.resolve(col, remainder)
      rescue MissingDataError => e
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}, column #{index + 1}: #{e.message}")
      end
    end

    def reconcile_page_path(ctx, path, data, entries)
      PathResolver.resolve(data, path)
    rescue MissingDataError => e
      entries << error_entry(ctx[:slide_no], ctx[:shape], path, e.message)
    end

    def reconcile_block_cells(ctx, row_item, cols, band, where, entries)
      width = band[:width]
      cols.each_with_index do |col, col_index|
        width.times do |template_index|
          value_path = GridValue.band_value_path(band[:value_paths], template_index)
          GridValue.cell_value(row_item, col, value_path)
        rescue MissingDataError => e
          entries << error_entry(ctx[:slide_no], ctx[:shape], "cell",
                                 "#{where},#{cell_where(col_index, template_index, width)}:" \
                                 "#{e.message}")
        end
      end
    end

    def cell_where(col_index, template_index, width)
      return "column #{col_index + 1}" if width == 1

      "column item #{col_index + 1}, template column #{template_index + 1}"
    end

    # 完整路径:按作用域栈里最长的匹配前缀取值
    def reconcile_block_scope_path(label, scope, where, entries)
      path = label[:path]
      ctx = label[:context]
      prefix = scope.keys.select { |key| path == key || path.start_with?("#{key}.") }
                    .max_by(&:length)
      if prefix.nil?
        entries << error_entry(ctx[:slide_no], ctx[:shape], path,
                               "#{where}: path is not inside the row block scope")
        return
      end
      remainder = path.delete_prefix(prefix).delete_prefix(".")
      return if remainder.empty?

      PathResolver.resolve(scope[prefix], remainder)
    rescue MissingDataError => e
      entries << error_entry(ctx[:slide_no], ctx[:shape], label[:path], "#{where}:#{e.message}")
    end

    def each_block(blocks, &block)
      blocks.each do |item|
        block.call(item)
        each_block(item[:children], &block)
      end
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
                               "#{where}expected an array for the row loop, got #{array.class}")
        return
      end
      if array.empty?
        entries << CheckEntry.new(level: :warning, slide_no: ctx[:slide_no], shape: ctx[:shape],
                                  label: original,
                                  message: "#{where}array '#{root}' is empty: " \
                                           "the table loop row will be removed at render time")
        return
      end
      return if rest.empty?

      array.each_with_index do |item, k|
        reconcile_loop_level(
          rest, item, "#{concrete}#{root}[#{k}].",
          "#{where}array '#{root}' item #{k + 1}: ", ctx, entries, original
        )
      end
    rescue MissingDataError => e
      entries << error_entry(ctx[:slide_no], ctx[:shape], original,
                             "#{where}#{e.message} (expected: #{concrete}#{path})")
    end

    def error_entry(slide_no, shape, label, message)
      CheckEntry.new(level: :error, slide_no: slide_no, shape: shape, label: label, message: message)
    end

    def root_of(path)
      path.split(".").first[/\A[A-Za-z0-9_]+/] || path
    end

    # Scanner 的错误消息自带页码/形状前缀,条目里已有定位字段,剥掉避免重复
    def strip_location(message)
      message.sub(/\Aslide \d+ shape '[^']*': /, "")
             .sub(/\Aslide \d+ notes: /, "")
             .sub(/\Aslide \d+: /, "")
    end
  end
end
