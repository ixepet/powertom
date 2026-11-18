# frozen_string_literal: true

# 仓库内专用任务:模板结构自检(依赖 tools/template_lint,不随 gem 发布)。
# 公开的 powertom:check 在 lib/powertom/tasks.rb(gem 用户 require 即可用)。
#
# 用法:
#   rake powertom:lint TEMPLATE=/path/to/模板.pptx CONTRACT=/path/to/模板契约.toml [DATA=/path/to/样例数据.toml]

namespace :powertom do
  desc "模板结构自检:按契约核对页数/形状/标签/备注指令/图片占位"
  task :lint do
    template = ENV.fetch("TEMPLATE", nil)
    contract = ENV.fetch("CONTRACT", nil)
    if template.nil? || template.empty? || contract.nil? || contract.empty?
      abort "用法: rake powertom:lint TEMPLATE=模板.pptx CONTRACT=模板契约.toml [DATA=样例数据.toml]"
    end
    data = ENV.fetch("DATA", nil)
    data = nil if data.nil? || data.empty?

    require_relative "../tools/template_lint"
    result = PowerTomDev::TemplateLint.run(template: template, contract: contract, data: data)
    puts result.report
    exit result.exit_code
  end
end
