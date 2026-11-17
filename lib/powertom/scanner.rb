# frozen_string_literal: true

module PowerTom
  # §3 模板语法 v0:
  #   - 文本标签 {{path}} / {{path:formatter}}(§3.4),路径只支持点路径与下标
  #   - 页级指令 {{#each}} / {{#if}} 只允许写在幻灯片备注(§3.3),出现在正文 = 语法错误
  module Scanner
    # 宽松的"疑似标签"正则,用于语法校验兜底:任何 {{...}} 都必须能通过严格校验
    TAG_RE = /\{\{[^{}]*\}\}/.freeze

    # 严格的文本标签正则:点路径与下标 + 可选 formatter 规格(§3.4)
    LABEL_RE = /\{\{\s*([A-Za-z0-9_\[\]]+(?:\.[A-Za-z0-9_\[\]]+)*)(?::([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*))?\s*\}\}/.freeze

    # 合法的路径段:字段名或 字段名[下标]
    SEGMENT_RE = /\A[A-Za-z0-9_]+(?:\[\d+\])?\z/.freeze

    # formatter 规格:词 + 可选 .参数(percent.1 / date.year_month)
    FORMAT_SPEC_RE = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\z/.freeze

    module_function

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
              "第 #{slide_no} 页备注含 #{directives_in_notes.size} 条页级指令 " \
              "(#{directives_in_notes.join(', ')}),一页只允许一条(§3.3)"
      end

      raw = directives_in_notes.first[/\{\{\s*#\s*([^{}]*?)\s*\}\}/, 1].to_s
      m = raw.match(/\A(each|if)\s+([A-Za-z0-9_\[\]\.]+)\z/)
      unless m
        raise TemplateSyntaxError,
              "第 #{slide_no} 页备注指令 {{##{raw}}} 不合法,只支持 {{#each 路径}} 与 {{#if 路径}}"
      end
      { kind: m[1].to_sym, path: m[2] }
    end

    def validate!(raw, tag, ctx)
      where = "第 #{ctx[:slide_no]} 页 形状'#{ctx[:shape]}'"
      if raw.start_with?("#") || raw.start_with?("/")
        if ctx[:in_table] && (raw.match?(/\A#rows\s+\S/) || raw.start_with?("#grid"))
          validate_table_directive!(raw, tag, where)
          return
        end
        raise TemplateSyntaxError,
              "#{where}:#{tag} 是页级指令,必须写在幻灯片备注里,v0 正文不支持指令"
      end
      path, spec = raw.split(":", 2)
      validate_path!(path, tag, where, ctx)
      if spec && !spec.match?(FORMAT_SPEC_RE)
        raise TemplateSyntaxError,
              "#{where}:#{tag} 的 formatter 写法不合法,应为 {{路径:名字}} 或 {{路径:名字.参数}}"
      end
    end

    # 表格指令:{{#rows 路径}} / {{#grid rows: .. cols: ..}}。
    # 这里只做轻量语法校验,结构(层级/位置/作用域)由 TableLoop 校验。
    def validate_table_directive!(raw, tag, where)
      return validate_row_marker!(raw, tag, where) if raw.start_with?("#rows")

      unless raw.match?(/\A#grid\s+\S/)
        raise TemplateSyntaxError,
              "#{where}:#{tag} grid 标记不合法," \
              "应为 {{#grid rows: 数组 cols: 数组 [value: 字段]}}"
      end
    end

    # 表格行标记 {{#rows 路径}}:只校验路径写法,结构(层级/位置)由 TableLoop 校验
    def validate_row_marker!(raw, tag, where)
      unless raw.match?(/\A#rows\s+[A-Za-z0-9_\[\]\.]+\z/)
        raise TemplateSyntaxError,
              "#{where}:#{tag} 行标记不合法,应为 {{#rows 路径}}(路径只支持点路径与 [])"
      end
      if raw.scan("[]").size > 1
        raise TemplateSyntaxError,
              "#{where}:#{tag} 堆叠层级超过 2 级,只支持「父级 → 子级」两层"
      end
      return unless raw.match?(/\[\d+\]/)

      raise TemplateSyntaxError, "#{where}:#{tag} 行标记路径不支持下标,请用数组名 + []"
    end

    # 路径逐段校验:字段、字段[下标]、字段[](仅表格行循环)
    def validate_path!(path, tag, where, ctx)
      path.split(".").each do |segment|
        next if segment.match?(/\A[A-Za-z0-9_]+(?:\[\d+\])?\z/)

        if segment.match?(/\A[A-Za-z0-9_]+\[\]\z/)
          unless ctx[:in_table]
            raise TemplateSyntaxError,
                  "#{where}:#{tag} 的 [] 只能在表格行里使用(表格行循环),正文/备注请用具体下标"
          end
        else
          raise TemplateSyntaxError,
                "#{where}:#{tag} 不是合法标签,路径只支持点路径与下标(如 {{kpis[0].name}})"
        end
      end
    end
  end
end
