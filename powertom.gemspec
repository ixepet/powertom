# frozen_string_literal: true

require_relative "lib/powertom/version"

Gem::Specification.new do |spec|
  spec.name = "powertom"
  spec.version = PowerTom::VERSION
  spec.authors = ["PowerTom contributors"]
  spec.summary = "PowerTom — PowerPoint template engine for Ruby"
  spec.description = <<~DESC.strip
    PowerTom is a PowerPoint template engine for Ruby. Designers keep the template in PowerPoint; engineers pass a Ruby Hash or a TOML file and get a finished deck. Layout, fonts, colours, masters and theme stay under the designer's control.

    PowerTom est un moteur de modèles PowerPoint pour Ruby. Les designers conservent le modèle dans PowerPoint ; les ingénieurs passent un Hash Ruby ou un fichier TOML et obtiennent un deck finalisé. La mise en page, les polices, les couleurs, les masques et le thème restent sous le contrôle du designer.

    设计师在 PowerPoint 里维护模板,工程师传一个 Ruby Hash 或 TOML 文件,产出成品 deck。排版、字体、配色、母版和主题完全由设计工具掌控。
  DESC
  spec.license = "MIT"
  spec.homepage = "https://github.com/ixepet/powertom"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "#{spec.homepage}/blob/main/docs/usage.md"
  }
  # ruby_pptx 0.2 与 tomlrb 3.0 均要求 >= 3.3
  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir["lib/**/*.rb"] + %w[README.md LICENSE]
  spec.extra_rdoc_files = %w[README.md LICENSE]
  spec.require_paths = ["lib"]

  # 设计文档 §4:上游依赖锁版本(0.x API 不稳定,锁到 0.2.x)
  spec.add_dependency "ruby_pptx", "~> 0.2.0"
  # 数据文件默认格式 TOML(解析);tomlrb 只负责读,写出侧由 fixture 工具自带微型序列化器
  spec.add_dependency "tomlrb", "~> 3.0"
end
