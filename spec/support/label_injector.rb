# frozen_string_literal: true

# 测试工具:向模板的指定段落注入 {{标签}},只经 PowerTom::Adapter 读写,
# 顺带验证适配层写回路径对任意段落可用。生成物写入 tmp 目录,不进 fixtures。
module PowerTomDev
  module LabelInjector
    module_function

    # replacements: [{slide_no:, shape:, old_text:, runs:[新 run 文本]}]
    # 以 段落原文 精确定位(原文含空格,取自 manifest),run 数必须与现有结构一致。
    # notes_assignments: {slide_no => 备注文本}(整页替换,用于注入 {{#each}} / {{#if}} 指令)
    # renames: [{slide_no:, old_name:, new_name:}](改形状名,如 powertom:image:xxx 占位)
    def inject(src, dst, replacements, notes_assignments: {}, renames: [])
      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(src)
      contexts = adapter.paragraph_contexts(prs)

      replacements.each do |rep|
        ctx = contexts.find do |c|
          c[:slide_no] == rep[:slide_no] &&
            c[:shape] == rep[:shape] &&
            c[:run_texts].join == rep[:old_text]
        end
        raise "注入目标未找到: P#{rep[:slide_no]} #{rep[:shape]} #{rep[:old_text].inspect}" unless ctx
        if ctx[:run_texts].size != rep[:runs].size
          raise "注入 run 数不匹配: P#{rep[:slide_no]} #{rep[:shape]} " \
                "现有 #{ctx[:run_texts].size},传入 #{rep[:runs].size}"
        end
        adapter.write_paragraph_runs(ctx[:paragraph], rep[:runs])
      end

      renames.each do |r|
        shape = adapter.find_shape(prs, r[:slide_no], r[:old_name])
        raise "改名目标未找到: P#{r[:slide_no]} #{r[:old_name].inspect}" unless shape

        shape.name = r[:new_name]
      end

      notes_assignments.each do |slide_no, text|
        prs.slides[slide_no - 1].notes = text
      end

      adapter.save(prs, dst)
      dst
    end
  end
end
