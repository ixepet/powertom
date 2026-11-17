# frozen_string_literal: true

module PowerTom
  # §5.1 段落级 run 合并替换(纯 Ruby,不碰 XML)。
  #
  # PowerPoint 会把 {{title}} 存成多个 run(输入法组合、拼写检查、反复编辑都会触发)。
  # 解法:把段落内所有 run 的文本拼接成完整字符串,匹配标签做替换,
  # 结果写回首个 run,其余 run 清空文本但保留节点本身(样式引用不破坏)。
  module RunMerge
    module_function

    # run_texts: [String];resolver: path(String), spec(String|nil) → 渲染后的文本
    # 返回新的 run 文本数组;段落里没有可替换标签时返回 nil(调用方跳过写入)
    def merge(run_texts, resolver)
      return nil if run_texts.nil? || run_texts.empty?

      joined = run_texts.join
      return nil unless joined.include?("{{")
      return nil unless joined.match?(PowerTom::Scanner::LABEL_RE)

      replaced = joined.gsub(PowerTom::Scanner::LABEL_RE) do
        resolver.call(Regexp.last_match(1), Regexp.last_match(2))
      end
      [replaced] + Array.new(run_texts.size - 1, "")
    end
  end
end
