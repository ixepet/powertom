# frozen_string_literal: true

require_relative "powertom/version"

module PowerTom
  class Error < StandardError; end

  # 模板引用了数据中不存在的字段(设计文档 §2.3)
  class MissingDataError < Error; end

  # 模板标签语法错误,如 {{each kpis}} 缺 #
  class TemplateSyntaxError < Error; end

  # ruby_pptx 打不开文件 / 不是合法 pptx
  class InvalidTemplateError < Error; end

  # 全局配置(0.7.0):图片等外部资源的解析钩子。
  # resolver.call(ref, context) 返回路径 String 或 {data:, extension:}
  class Configuration
    attr_accessor :asset_resolver
  end
end

require_relative "powertom/render"
require_relative "powertom/validator"

module PowerTom
  class << self
    # Global configuration; currently only +asset_resolver+.
    #
    # @return [PowerTom::Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # @example Resolve pictures from object storage
    #   PowerTom.configure do |config|
    #     config.asset_resolver = ->(ref, _context) { MyStore.fetch(ref) }
    #   end
    def configure
      yield configuration
    end

    # Register a custom formatter.
    #
    # @param name [String] formatter name used after the colon in a tag.
    # @yieldparam value [Object] value resolved from the data.
    # @yieldparam arg [String, nil] argument after the dot in the formatter spec.
    # @yieldreturn [Object] converted value (sent through +to_s+ when written).
    # @return [void]
    # @example
    #   PowerTom.register_formatter("rmb") { |value, _arg| "人民币#{value}元" }
    def register_formatter(name, &)
      Formatter.register(name, &)
    end

    # Remove a previously registered formatter.
    #
    # @param name [String]
    # @return [void]
    def unregister_formatter(name)
      Formatter.unregister_formatter(name)
    end

    # Render a template with the given data.
    #
    # @param template_path [String] path to a +.pptx+ template.
    # @param data [Hash, String] a Hash or a +.toml+ file path.
    # @param strict [Boolean] raise on missing fields when true; fill blanks and warn when false.
    # @param asset_resolver [Proc, nil] overrides PowerTom.configuration.asset_resolver.
    # @return [PowerTom::RenderResult]
    # @raise [PowerTom::MissingDataError] a field is missing in strict mode.
    # @raise [PowerTom::TemplateSyntaxError] an invalid tag, directive or table block.
    # @raise [PowerTom::InvalidTemplateError] the file is not a readable +.pptx+.
    # @example
    #   result = PowerTom.render("template.pptx", data: "data.toml")
    #   result.save("out.pptx")
    #   result.warnings.each { |warning| warn warning }
    def render(template_path, data:, strict: true, asset_resolver: configuration.asset_resolver)
      Render.new(template_path, data: DataLoading.coerce(data), strict: strict,
                                asset_resolver: asset_resolver).call
    end

    # Validate a template against optional sample data without raising.
    #
    # @param template_path [String] path to a +.pptx+ template.
    # @param data [Hash, String, nil] sample data Hash or +.toml+ path.
    # @param asset_resolver [Proc, nil] overrides PowerTom.configuration.asset_resolver.
    # @return [PowerTom::CheckResult]
    # @example
    #   result = PowerTom.check("template.pptx", data: "sample.toml")
    #   puts result.report
    def check(template_path, data: nil, asset_resolver: configuration.asset_resolver)
      data = DataLoading.coerce(data) if data
      adapter = Adapter::RubyPptxAdapter.new
      prs = adapter.open(template_path)
      Validator.check(
        contexts: adapter.paragraph_contexts(prs),
        tables: adapter.table_cell_contexts(prs),
        table_structures: adapter.table_contexts(prs),
        notes: adapter.notes_texts(prs),
        container_texts: adapter.container_texts(prs),
        pictures: adapter.picture_contexts(prs),
        conditionals: adapter.conditional_contexts(prs),
        charts: adapter.chart_tags(prs),
        chart_placeholders: adapter.chart_contexts(prs),
        data: data,
        asset_resolver: asset_resolver,
        template_name: File.basename(template_path)
      )
    end
  end
end
