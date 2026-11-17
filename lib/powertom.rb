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
end

require_relative "powertom/render"
require_relative "powertom/validator"

module PowerTom
  class << self
    # §3.4 注册自定义 formatter:proc 收到 (value, arg),返回值 to_s 后落盘。
    #   PowerTom.register_formatter("rmb") { |value, _arg| "人民币#{value}元" }
    def register_formatter(name, &block)
      Formatter.register(name, &block)
    end

    def unregister_formatter(name)
      Formatter.unregister_formatter(name)
    end
    # §2.1 渲染入口。
    #   result = PowerTom.render("templates/x.pptx", data: "data.toml", strict: true)
    #   result.save("out/x.pptx")
    #   result.warnings  # 未使用字段、缺失字段降级、备注标签等
    #
    # data 支持 Hash 或 .toml 文件路径(TOML 是 gem 的默认数据格式)。
    # v0 覆盖:单页多标签、跨 run 标签、{{#each}} 页面克隆、{{#if}} 页面删除(§3.3)。
    def render(template_path, data:, strict: true)
      Render.new(template_path, data: DataLoading.coerce(data), strict: strict).call
    end

    # §7 模板校验器:对账模板标签 vs 样例数据,报告问题而不抛异常
    # (语法错误也作为 error 条目输出)。返回 CheckResult:
    #   result.ok? / result.errors / result.warnings / result.exit_code / result.report
    #
    # data 支持 Hash 或 .toml 路径;缺省时只做语法与结构检查。
    def check(template_path, data: nil)
      data = DataLoading.coerce(data) if data
      adapter = Adapter::RubyPptxAdapter.new
      prs = adapter.open(template_path)
      Validator.check(
        contexts: adapter.paragraph_contexts(prs),
        tables: adapter.table_cell_contexts(prs),
        table_structures: adapter.table_contexts(prs),
        notes: adapter.notes_texts(prs),
        pictures: adapter.picture_contexts(prs),
        data: data,
        template_name: File.basename(template_path)
      )
    end
  end
end
