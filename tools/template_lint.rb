# frozen_string_literal: true

require "tomlrb"
require "powertom"

module PowerTomDev
  # 模板结构自检(项目工具,不随 gem 发布)。
  #
  # 按「模板契约」核对交付的 pptx:页数、每页应有哪些形状名、哪些标签、
  # 哪条备注指令、哪些图片占位。契约换一个场景只需换一份 TOML,不改代码:
  #   examples/score_report/template_contract.toml
  #
  # 与 PowerTom.check 的分工:本工具查"模板有没有按施工图做",
  # check 查"模板标签与样例数据对不对得上";提供 data 时一并跑 check。
  module TemplateLint
    Entry = Struct.new(:level, :page, :message, keyword_init: true)

    class Result
      attr_reader :entries, :check, :template_name, :contract_name

      def initialize(template_name:, contract_name:, entries:, check: nil)
        @template_name = template_name
        @contract_name = contract_name
        @entries = entries
        @check = check
      end

      def errors = entries.select { |e| e.level == :error }

      def warnings = entries.select { |e| e.level == :warning }

      def ok? = errors.empty?

      def exit_code = ok? ? 0 : 1

      def report
        lines = ["PowerTom 模板自检 — #{template_name}", "契约:#{contract_name}"]
        entries.each { |e| lines << line(e.level, e.page, e.message) }
        unless check.nil?
          lines << ""
          lines << "—— 数据对账(powertom:check)——"
          check.entries.each { |e| lines << line(e.level, e.slide_no, e.message, shape: e.shape) }
        end
        lines << "-" * 48
        lines << summary
        lines.join("\n")
      end

      private

      def line(level, page, message, shape: nil)
        head = []
        head << "P#{page}" if page
        head << "形状'#{shape}'" if shape
        format("[%-7s] %s%s", level, head.empty? ? "" : "#{head.join(' ')} ", message)
      end

      def summary
        base = "结构检查:#{errors.size} 个 error,#{warnings.size} 个 warning"
        return base unless check
        "#{base};数据对账:#{check.errors.size} 个 error,#{check.warnings.size} 个 warning"
      end
    end

    module_function

    def run(template:, contract:, data: nil)
      spec = Tomlrb.load_file(contract)
      pages = spec["pages"]
      unless pages.is_a?(Array) && !pages.empty?
        raise ArgumentError, "契约缺少 [[pages]](每页一项:index / shapes / labels / images / directive)"
      end

      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(template)
      entries = []
      slide_count = prs.slides.size

      expected = spec["slide_count"]
      if expected && expected.to_i != slide_count
        entries << Entry.new(level: :error, message: "页数不符:契约 #{expected} 页,实际 #{slide_count} 页")
      end

      notes_by_slide, directives = collect_directives(adapter, prs, entries)
      labels_by_slide = collect_labels(adapter, prs, entries)
      names_by_slide = adapter.shape_names_by_slide(prs)
                               .to_h { |s| [s[:slide_no], s[:names]] }
      images_by_slide = collect_images(adapter, prs)

      declared_pages = pages.map { |p| p["index"] }.compact

      pages.each do |page|
        no = page["index"]
        unless no.is_a?(Integer) && no.between?(1, slide_count)
          entries << Entry.new(level: :error,
                               message: "契约里的页码 #{no.inspect} 不合法(现有 #{slide_count} 页)")
          next
        end
        check_shapes(page, no, names_by_slide[no], entries)
        check_labels(page, no, labels_by_slide[no], entries)
        check_images(page, no, names_by_slide[no], images_by_slide[no], entries)
        check_directive(page, no, directives[no], entries)
      end

      check_container_tags(adapter, prs, entries)
      check_notes_tags(notes_by_slide, declared_pages, entries)

      Result.new(
        template_name: File.basename(template),
        contract_name: File.basename(contract),
        entries: entries,
        check: data ? PowerTom.check(template, data: data) : nil
      )
    end

    # ---- 采集 ----

    def collect_directives(adapter, prs, entries)
      notes = {}
      directives = {}
      adapter.notes_texts(prs).each do |note|
        no = note[:slide_no]
        notes[no] = note[:text].to_s
        begin
          directive = PowerTom::Scanner.directive_for(note)
          directives[no] = directive ? "#{directive[:kind]} #{directive[:path]}" : nil
        rescue PowerTom::TemplateSyntaxError => e
          entries << Entry.new(level: :error, page: no, message: "备注指令语法错误:#{strip_location(e.message)}")
        end
      end
      [notes, directives]
    end

    def collect_labels(adapter, prs, entries)
      labels = Hash.new { |h, k| h[k] = [] }
      contexts = adapter.paragraph_contexts(prs) + adapter.table_cell_contexts(prs)
      contexts.each do |ctx|
        PowerTom::Scanner.scan([ctx]).each do |label|
          labels[ctx[:slide_no]] << (label[:spec] ? "#{label[:path]}:#{label[:spec]}" : label[:path])
        end
        # {{#rows}} / {{#grid}} 不是可绑定标签,但契约里应能声明它们
        next unless ctx[:in_table]

        ctx[:run_texts].join.scan(PowerTom::Scanner::TAG_RE).each do |tag|
          raw = tag[/\{\{\s*([^{}]*?)\s*\}\}/, 1].to_s
          labels[ctx[:slide_no]] << raw if raw.match?(/\A#(rows|grid)\s/)
        end
      rescue PowerTom::TemplateSyntaxError => e
        entries << Entry.new(level: :error, page: ctx[:slide_no],
                             message: "标签语法错误(形状'#{ctx[:shape]}'):#{strip_location(e.message)}")
      end
      labels.transform_values(&:uniq)
    end

    # 图片占位统一成「powertom:image:字段」,name 与 alt text 两种写法学等价
    def collect_images(adapter, prs)
      adapter.picture_contexts(prs).group_by { |p| p[:slide_no] }
             .transform_values { |list| list.map { |p| "powertom:image:#{p[:field]}" }.uniq }
    end

    # ---- 核对 ----

    def check_shapes(page, no, actual_names, entries)
      Array(page["shapes"]).each do |name|
        next if actual_names.include?(name)
        entries << Entry.new(level: :error, page: no, message: "缺少形状:'#{name}'")
      end
    end

    def check_labels(page, no, actual, entries)
      actual = Array(actual)
      declared = Array(page["labels"])
      declared.each do |label|
        next if actual.include?(label)
        entries << Entry.new(level: :error, page: no, message: "缺少标签:{{#{label}}}")
      end
      (actual - declared).each do |extra|
        entries << Entry.new(level: :warning, page: no,
                             message: "契约外标签:{{#{extra}}}(若为有意新增,请同步契约)")
      end
    end

    def check_images(page, no, actual_names, actual_images, entries)
      actual_names = Array(actual_names)
      actual_images = Array(actual_images)
      declared = Array(page["images"])
      declared.each do |name|
        next if actual_images.include?(name)
        if actual_names.include?(name)
          entries << Entry.new(level: :error, page: no,
                               message: "形状'#{name}'存在但不是图片:图片占位必须挂在图片形状上")
        else
          entries << Entry.new(level: :error, page: no, message: "缺少图片占位:'#{name}'")
        end
      end
      (actual_images - declared).each do |extra|
        entries << Entry.new(level: :warning, page: no,
                             message: "契约外图片占位:'#{extra}'(不会被使用,命名可能拼错)")
      end
    end

    def check_directive(page, no, actual, entries)
      expected = page["directive"]
      return if expected.to_s == actual.to_s
      format_directive = ->(value) { value ? "{{##{value}}}" : "无" }
      entries << Entry.new(
        level: :error, page: no,
        message: "备注指令不符:契约 #{format_directive.call(expected)},实际 #{format_directive.call(actual)}"
      )
    end

    def check_container_tags(adapter, prs, entries)
      adapter.container_texts(prs).each do |entry|
        tags = entry[:text].scan(PowerTom::Scanner::TAG_RE).uniq
        next if tags.empty?
        entries << Entry.new(
          level: :error,
          message: "#{entry[:container]} 形状'#{entry[:shape]}'含标签 #{tags.join('、')}:" \
                   "母版/版式上的标签不会生效"
        )
      end
    end

    def check_notes_tags(notes_by_slide, declared_pages, entries)
      notes_by_slide.each do |no, text|
        next unless declared_pages.include?(no)
        tags = text.scan(PowerTom::Scanner::TAG_RE).reject { |t| t.match?(/\{\{\s*#/) }.uniq
        tags.each do |tag|
          entries << Entry.new(level: :warning, page: no,
                               message: "备注含标签 #{tag},不会渲染(备注只用于页级指令)")
        end
      end
    end

    def strip_location(message)
      message.sub(/\A第 \d+ 页 形状'[^']*':/, "").sub(/\A第 \d+ 页:?/, "")
    end
  end
end
