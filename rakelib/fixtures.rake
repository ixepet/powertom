# frozen_string_literal: true

# 金样本 fixture 的生成与校验任务
#
# 用法:
#   rake fixtures:generate TEMPLATE=/path/to/模板.pptx [OUT=spec/fixtures/hai_mate]
#       生成 template.pptx(瘦身)+ manifest.toml(结构快照)
#       KEEP_FONTS=1 / KEEP_MEDIA=1 可关闭对应的剥离
#   rake fixtures:check [OUT=spec/fixtures/hai_mate]
#       校验 manifest.toml 与 template.pptx 解剖结果一致

require "tomlrb"
require_relative "../spec/support/fixture_generator"

namespace :fixtures do
  desc "从 pptx 生成金样本 fixture(瘦身模板 + manifest.toml)"
  task :generate do
    src = ENV.fetch("TEMPLATE", nil)
    abort "用法: rake fixtures:generate TEMPLATE=/path/to/模板.pptx [OUT=spec/fixtures/<name>]" if src.nil? || src.empty?
    out = ENV["OUT"] || "spec/fixtures/hai_mate"
    PowerTomDev::FixtureGenerator.generate(
      pptx_path: src,
      out_dir: out,
      strip_fonts: ENV["KEEP_FONTS"] != "1",
      strip_media: ENV["KEEP_MEDIA"] != "1"
    )
    puts "生成完成: #{out}/template.pptx + manifest.toml"
  end

  desc "校验 manifest.toml 与 template.pptx 解剖结果一致"
  task :check do
    dir = ENV["OUT"] || "spec/fixtures/hai_mate"
    manifest_path = File.join(dir, "manifest.toml")
    template_path = File.join(dir, "template.pptx")
    abort "缺少 #{manifest_path}" unless File.file?(manifest_path)
    abort "缺少 #{template_path}(用 rake fixtures:generate TEMPLATE=... 生成)" unless File.file?(template_path)

    manifest = Tomlrb.load_file(manifest_path)
    live = PowerTomDev::Anatomy.manifest(
      PowerTomDev::Anatomy.analyze(template_path),
      source_name: manifest["source"], generated_at: nil
    )
    mismatch = %w[template stats slides].reject { |section| manifest[section] == live[section] }
    if mismatch.empty?
      puts "OK: manifest 与 template.pptx 一致(#{manifest['template']['slide_count']} 页)"
    else
      abort "不一致的 section: #{mismatch.join(', ')} — 请重跑 rake fixtures:generate"
    end
  end
end
