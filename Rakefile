# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
# 公开发布的模板校验任务;gem 用户在自己的 Rakefile 里同样 require 这一行
require "powertom/tasks"

RSpec::Core::RakeTask.new(:spec)

task default: :spec
