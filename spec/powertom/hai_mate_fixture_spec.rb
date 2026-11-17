# frozen_string_literal: true

require "tomlrb"

# 金样本 hai_mate(HaiMate 教师工作台 deck)的回归测试。
#
# 设计意图(见设计文档 §8):
#   - manifest.toml 是模板结构的快照基准,进 git
#   - template.pptx 是瘦身后的模板副本,不进 git(体积与归属)
#   - 本 spec 保证两者始终一致:任何人本地重跑 fixture 都必须能复现 manifest
#   - M0 证据(跨 run 分裂)在案,供 Scanner/Binder 的段落级合并替换用例取材
RSpec.describe "金样本 fixture: hai_mate" do
  fixture_dir = File.expand_path("../fixtures/hai_mate", __dir__)
  template_path = File.join(fixture_dir, "template.pptx")
  manifest_path = File.join(fixture_dir, "manifest.toml")

  before do
    unless File.file?(template_path) && File.file?(manifest_path)
      skip "缺少 fixture 文件 — 放好原始 pptx 后运行: " \
           "rake fixtures:generate TEMPLATE=<路径> OUT=#{fixture_dir}"
    end
  end

  it "manifest 自洽:版本为 v1、页数与逐页记录一致、页序连续" do
    manifest = Tomlrb.load_file(manifest_path)
    aggregate_failures do
      expect(manifest["manifest_version"]).to eq(1)
      expect(manifest["slides"].size).to eq(manifest["template"]["slide_count"])
      expect(manifest["slides"].map { |s| s["index"] }).to eq((1..manifest["slides"].size).to_a)
    end
  end

  it "M0 证据在案:模板存在跨 run 分裂段落(§5.1 头号坑)" do
    stats = Tomlrb.load_file(manifest_path)["stats"]
    aggregate_failures do
      expect(stats["paragraphs"]).to be > 0
      expect(stats["split_paragraphs"]).to be > 0
    end
  end

  it "回归:manifest 与 template.pptx 的实际解剖结果完全一致" do
    manifest = Tomlrb.load_file(manifest_path)
    live = PowerTomDev::Anatomy.manifest(
      PowerTomDev::Anatomy.analyze(template_path),
      source_name: manifest["source"], generated_at: nil
    )
    aggregate_failures do
      %w[template stats slides].each do |section|
        expect(live[section]).to eq(manifest[section]),
                                 "#{section} 与 manifest.toml 不一致 — 请重跑 rake fixtures:generate"
      end
    end
  end
end
