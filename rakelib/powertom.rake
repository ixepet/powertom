# frozen_string_literal: true

# 模板校验器任务(§7,差异化核心)
#
# 用法:
#   rake powertom:check TEMPLATE=/path/to/模板.pptx [DATA=/path/to/样例数据.toml]
#
# DATA 省略时只做语法与结构检查;提供样例数据后追加字段对账与溢出预警。
# error 阻断渲染(CI 里任务以非零码退出),warning 不阻断。

require "powertom"

namespace :powertom do
  desc "模板校验:对账模板标签与样例数据,输出人话报告(error 阻断渲染)"
  task :check do
    template = ENV.fetch("TEMPLATE", nil)
    if template.nil? || template.empty?
      abort "用法: rake powertom:check TEMPLATE=/path/to/模板.pptx [DATA=/path/to/样例数据.toml]"
    end
    data = ENV.fetch("DATA", nil)
    data = nil if data.nil? || data.empty?

    result = PowerTom.check(template, data: data)
    puts result.report
    exit result.exit_code
  end

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
