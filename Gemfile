# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake"
  gem "rspec"
  # Ruby 3.x 起 REXML 属 bundled gem,显式声明保证 bundler 环境下可用
  gem "rexml"
  # 金样本生成器做 zip 手术用;未来也将经 ruby_pptx 间接依赖
  gem "rubyzip"
end

gem "tomlrb", "~> 3.0"
