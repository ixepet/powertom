# frozen_string_literal: true

require "rake"
require_relative "../powertom"

# 模板校验任务(§7)。gem 用户在自己的 Rakefile 里 require 本文件:
#   require "powertom/tasks"
# 仓库根目录的 Rakefile 也只 require 本文件,保证 powertom:check 只有一处定义。
namespace :powertom do
  desc "Validate a template against sample data (errors block rendering)"
  task :check do
    template = ENV.fetch("TEMPLATE", nil)
    if template.nil? || template.empty?
      abort "usage: rake powertom:check TEMPLATE=/path/to/template.pptx [DATA=/path/to/sample.toml]"
    end

    data = ENV.fetch("DATA", nil)
    data = nil if data.nil? || data.empty?

    result = PowerTom.check(template, data: data)
    puts result.report
    exit result.exit_code
  end
end
