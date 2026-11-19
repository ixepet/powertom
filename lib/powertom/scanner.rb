# frozen_string_literal: true

module PowerTom
  # §3 模板语法 v0:
  #   - 文本标签 {{path}} / {{path:formatter}}(§3.4),路径只支持点路径与下标
  #   - 页级指令 {{#each}} / {{#if}} 只允许写在幻灯片备注(§3.3),出现在正文 = 语法错误
  module Scanner
    # 宽松的"疑似标签"正则,用于语法校验兜底:任何 {{...}} 都必须能通过严格校验
    TAG_RE = /\{\{[^{}]*\}\}/

    # 严格的文本标签正则:点路径与下标 + 可选 formatter 规格(§3.4);
    # 循环变量(@index/@index1/@first/@last)同样是合法标签
    LABEL_RE = /
      \{\{\s*
      (@(?:index|index1|first|last)|[A-Za-z0-9_\[\]]+(?:\.[A-Za-z0-9_\[\]]+)*)
      (?::([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*))?
      \s*\}\}
    /x

    # 合法的路径段:字段名或 字段名[下标]
    SEGMENT_RE = /\A[A-Za-z0-9_]+(?:\[\d+\])?\z/

    # formatter 规格:词 + 可选 .参数(percent.1 / date.year_month)
    FORMAT_SPEC_RE = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\z/

    # 循环内只读变量(%3.3/%7):@index 0 基、@index1 1 基、
    # @first / @last 布尔。作用域在 render/check 阶段校验
    LOOP_VARIABLE_RE = /\A@(index|index1|first|last)\z/
    LOOP_VARIABLES = %w[@index @index1 @first @last].freeze

    # 受限聚合(0.8.0):{{array[].field:sum}} / {{array[]:count}}。
    # 只接受单层数组 + 数值字段,不支持表达式或排序
    AGGREGATORS = %w[sum avg min max count].freeze

    module_function

    def loop_variable?(path)
      LOOP_VARIABLE_RE.match?(path.to_s)
    end

    def aggregator_spec?(spec)
      AGGREGATORS.include?(spec.to_s)
    end

    def aggregation?(path, spec)
      path.to_s.include?("[]") && aggregator_spec?(spec)
    end

    # 扫描段落上下文,收集标签并校验语法。
    # contexts: [{slide_no:, shape:, run_texts:}]
    # 返回 [{path:, spec:, context:}](同一标签出现多次会分别记录)
    # {{#rows 路径}} 是表格行标记,只做语法校验,不作为可绑定标签返回。
    def scan(contexts)
      contexts.flat_map do |ctx|
        joined = ctx[:run_texts].join
        next [] unless joined.include?("{{")

        joined.scan(TAG_RE).flat_map do |tag|
          raw = tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
          validate!(raw, tag, ctx)
          next [] if raw.start_with?("#", "/")

          path, spec = raw.split(":", 2)
          [{ path: path, spec: spec, context: ctx }]
        end
      end
    end

    # 备注里的标签:v0 不渲染备注,发现即记 warning(§3.3)
    def scan_notes(notes_text, slide_no)
      return [] unless notes_text

      notes_text.scan(TAG_RE).map { |tag| { tag: tag, slide_no: slide_no } }
    end

    # 备注页级指令(§3.3):{{#each 路径}} 按数组克隆整页;{{#if 路径}} 为假删页。
    # 一页备注只允许一条指令;返回 {slide_no => {kind:, path:}}
    def scan_directives(notes_texts)
      notes_texts.each_with_object({}) do |note, directives|
        directive = directive_for(note)
        directives[note[:slide_no]] = directive if directive
      end
    end

    # 单页备注的指令解析:无指令返回 nil,语法问题抛 TemplateSyntaxError。
    # Validator 逐页调用以收集全部错误;render 走 scan_directives 一次性收集。
    def directive_for(note)
      slide_no = note[:slide_no]
      tags = note[:text].to_s.scan(TAG_RE)
      directives_in_notes = tags.select { |tag| tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s.start_with?("#") }
      return nil if directives_in_notes.empty?

      if directives_in_notes.size > 1
        raise TemplateSyntaxError,
              "slide #{slide_no} notes: #{directives_in_notes.size} page directives " \
              "(#{directives_in_notes.join(', ')}); only one is allowed per page (§3.3)"
      end

      raw = directives_in_notes.first[/\{\{\s*#\s*([^{}]*?)\s*\}\}/, 1].to_s
      m = raw.match(/\A(each|if)\s+([A-Za-z0-9_\[\].]+)\z/)
      unless m
        raise TemplateSyntaxError,
              "slide #{slide_no} notes: invalid page directive {{##{raw}}}; " \
              "only {{#each path}} and {{#if path}} are supported"
      end
      { kind: m[1].to_sym, path: m[2] }
    end

    def validate!(raw, tag, ctx)
      where = "slide #{ctx[:slide_no]} shape '#{ctx[:shape]}'"
      if raw.start_with?("#") || raw.start_with?("/")
        if ctx[:in_table] && raw.match?(%r{\A#(rows|grid|cols|if)\b|\A/(rows|cols|if)\z})
          validate_table_directive!(raw, tag, where)
          return
        end
        raise TemplateSyntaxError,
              "#{where}: #{tag} is a page directive and must be written in the slide notes; " \
              "v0 does not support directives in the body"
      end
      # 空标签({{}} / {{ }})不是合法路径:raw.split(":", 2) 对空串返回 [],
      # path 会是 nil,后续 path.split 会抛 NoMethodError 而非 TemplateSyntaxError。
      # 这里显式拦成语法错误,让 check 能报告它而不是崩栈。
      if raw.strip.empty?
        raise TemplateSyntaxError,
              "#{where}: #{tag} is not a valid tag; a tag needs a path, e.g. {{field}}"
      end

      path, spec = raw.split(":", 2)
      # 聚合标签允许在非表格位置使用 [],由 Binder/Validator 按数组路径处理
      ctx = ctx.merge(allow_array: true) if aggregation?(path, spec)
      validate_path!(path, tag, where, ctx)
      return unless spec && !spec.match?(FORMAT_SPEC_RE)

      raise TemplateSyntaxError,
            "#{where}: #{tag} has an invalid formatter form; use {{path:name}} or {{path:name.arg}}"
    end

    # 表格指令:{{#rows 路径}} / {{#grid ...}} / {{#cols ...}} / {{/rows}} / {{/cols}}。
    # 这里只做轻量语法校验,结构(层级/位置/作用域)由 TableLoop 校验。
    GRID_MARKER_RE = /\A#grid\s+.+\z/
    COLS_MARKER_RE = /\A#cols\s+[A-Za-z0-9_.]+(?:\s+value:\s*[A-Za-z0-9_.]+(?:\s*,\s*[A-Za-z0-9_.]+)*)?\z/
    IF_MARKER_RE = /\A#if\s+[A-Za-z0-9_\[\].]+\z/
    CLOSE_MARKER_RE = %r{\A/(rows|cols|if)\z}

    def validate_table_directive!(raw, tag, where)
      case raw
      when /\A#rows\s/
        validate_row_marker!(raw, tag, where)
      when GRID_MARKER_RE, COLS_MARKER_RE, IF_MARKER_RE, CLOSE_MARKER_RE
        nil
      else
        raise TemplateSyntaxError,
              "#{where}: #{tag} is an invalid table directive; only {{#rows path}} / {{#grid ...}} / " \
              "{{#cols ...}} / {{#if path}} / {{/rows}} / {{/cols}} / {{/if}} are supported"
      end
    end

    # 表格行标记 {{#rows 路径}}:只校验路径写法,结构与层级由 TableLoop 校验
    def validate_row_marker!(raw, tag, where)
      unless raw.match?(/\A#rows\s+[A-Za-z0-9_\[\].]+\z/)
        raise TemplateSyntaxError,
              "#{where}: #{tag} is an invalid row marker; use {{#rows path}} (paths only support dot paths and [])"
      end
      return unless raw.match?(/\[\d+\]/)

      raise TemplateSyntaxError, "#{where}: #{tag} row marker paths do not support indices; use the array name + []"
    end

    # 路径逐段校验:字段、字段[下标]、字段[](仅表格行循环)
    def validate_path!(path, tag, where, ctx)
      return if loop_variable?(path)

      path.split(".").each do |segment|
        next if segment.match?(/\A[A-Za-z0-9_]+(?:\[\d+\])?\z/)

        if segment.match?(/\A[A-Za-z0-9_]+\[\]\z/)
          unless ctx[:in_table] || ctx[:allow_array]
            raise TemplateSyntaxError,
                  "#{where}: #{tag} uses [] outside a table row; [] is only allowed in table row loops. " \
                  "Use explicit indices in the body and notes"
          end
        else
          raise TemplateSyntaxError,
                "#{where}: #{tag} is not a valid tag; paths only support dot paths and indices (e.g. {{kpis[0].name}})"
        end
      end
    end
  end
end
