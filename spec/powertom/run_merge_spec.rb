# frozen_string_literal: true

# RunMerge 纯单元测试:§5.1 段落级 run 合并替换。
# 用例取材自 hai_mate manifest 里记录的真实 run 分裂形态(CJK 输入法切分)。
RSpec.describe PowerTom::RunMerge do
  def resolver_with(data)
    ->(path, _spec) { data.fetch(path.to_sym) { raise PowerTom::MissingDataError, path } }
  end

  it "标签完整落在单个 run 时直接替换" do
    result = described_class.merge(["{{page_title}}"], resolver_with(page_title: "学生工作台"))
    expect(result).to eq(["学生工作台"])
  end

  it "标签跨 run 分裂时也能替换(§5.1 头号坑)" do
    # 真实样例:P2 圆角矩形 4 的段落被拆成 [前导空格][文字] 两个 run,
    # 这里把标签人为切进两个 run,模拟输入法组合的产物
    result = described_class.merge(["    {{wor", "kload}}"], resolver_with(workload: "教学负担"))
    expect(result).to eq(["    教学负担", ""])
  end

  it "多 run 段落替换后:文本并入首个 run,其余 run 清空但保留占位" do
    # 真实样例:P10 标题 [场景二][  ][专业备课]
    result = described_class.merge(
      ["场景二", "  ", "{{page_title}}"], resolver_with(page_title: "学生工作台")
    )
    expect(result).to eq(["场景二  学生工作台", "", ""])
  end

  it "一个段落里有多个标签时全部替换" do
    result = described_class.merge(
      ["{{first}} 与 {{second}} 双标签"], resolver_with(first: "备课", second: "批改")
    )
    expect(result).to eq(["备课 与 批改 双标签"])
  end

  it "允许标签前后留白:{{ x }} 形式" do
    result = described_class.merge(["{{ page_title }}"], resolver_with(page_title: "学生工作台"))
    expect(result).to eq(["学生工作台"])
  end

  it "段落没有标签时返回 nil,调用方跳过写回" do
    expect(described_class.merge(["现状痛点"], resolver_with({}))).to be_nil
    expect(described_class.merge(["    ", "工作复杂"], resolver_with({}))).to be_nil
  end

  it "空 run 列表返回 nil" do
    expect(described_class.merge([], resolver_with({}))).to be_nil
    expect(described_class.merge(nil, resolver_with({}))).to be_nil
  end

  it "孤立的大括号不算标签,原样保留" do
    expect(described_class.merge(["单 { 个大括号"], resolver_with({}))).to be_nil
  end

  it "非标签形态(如正文里的 {{#each}})不进入 resolver,返回 nil 跳过写回" do
    # 语法错误由 Scanner 在渲染前拦截,merge 层只需保证不误替换
    expect(described_class.merge(["{{#each x}}"], ->(*_a) { raise "不应被调用" })).to be_nil
  end
end
