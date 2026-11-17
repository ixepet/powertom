# frozen_string_literal: true

require_relative "lib/powertom/version"

Gem::Specification.new do |spec|
  spec.name = "powertom"
  spec.version = PowerTom::VERSION
  spec.authors = ["PowerTom contributors"]
  spec.summary = "PowerTom — PowerPoint template engine for Ruby"
  spec.description = "设计师在 PowerPoint 里维护模板,工程师传一个 Ruby Hash,产出成品 deck。" \
                     "排版、字体、母版、主题完全由设计工具掌控,代码只负责扫描标签、绑定数据、克隆页面。"
  spec.license = "MIT"
  spec.homepage = "https://github.com/ixepet/powertom"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }
  # ruby_pptx 0.2 与 tomlrb 3.0 均要求 >= 3.3
  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir["lib/**/*.rb"] + %w[README.md LICENSE]
  spec.require_paths = ["lib"]

  # 设计文档 §4:上游依赖锁版本(0.x API 不稳定,锁到 0.2.x)
  spec.add_dependency "ruby_pptx", "~> 0.2.0"
  # 数据文件默认格式 TOML(解析);tomlrb 只负责读,写出侧由 fixture 工具自带微型序列化器
  spec.add_dependency "tomlrb", "~> 3.0"
end
