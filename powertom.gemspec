# frozen_string_literal: true

require_relative "lib/powertom/version"

Gem::Specification.new do |spec|
  spec.name = "powertom"
  spec.version = PowerTom::VERSION
  spec.authors = ["PowerTom contributors"]
  spec.summary = "PowerTom — PowerPoint template engine for Ruby"
  spec.description = <<~DESC.strip
    PowerTom is a PowerPoint template engine for Ruby. Designers keep the template in PowerPoint; engineers pass a Ruby Hash or a TOML file and get a finished deck. Layout, fonts, colours, masters and theme stay under the designer's control.
  DESC
  spec.license = "MIT"
  spec.homepage = "https://github.com/ixepet/powertom"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}/blob/main/docs/usage.md",
    "rubygems_mfa_required" => "true"
  }
  # ruby_pptx 0.3 与 tomlrb 3.0 均要求 >= 3.3
  spec.required_ruby_version = ">= 3.3"

  spec.bindir = "exe"
  spec.executables = ["powertom"]
  spec.files = Dir["lib/**/*.rb"] + Dir["exe/*"] + %w[README.md LICENSE CHANGELOG.md]
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.require_paths = ["lib"]

  # 适配层隔离上游变动:约束放宽到 < 1.0,下游可直接获得 0.x 的修复;
  # 破坏性变更由 CI(锁当前 minor)+ 适配层吸收。
  # 下限 0.3.0:散点/气泡绑定依赖上游 replace_data(XyChartData/BubbleChartData)
  # (0.2.x 会把类别图表数据写进 XY 系列,产 PowerPoint 需修复的文件)
  spec.add_dependency "ruby_pptx", ">= 0.3.0", "< 1.0"
  # 数据文件默认格式 TOML(解析);tomlrb 只负责读,写出侧由 fixture 工具自带微型序列化器
  spec.add_dependency "tomlrb", "~> 3.0"
end
