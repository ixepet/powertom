# frozen_string_literal: true

# 公开金样本生成器:生成提交在库内的微型模板 spec/fixtures/mini/template.pptx,
# 覆盖 split-run 合并(§5.1)、一段多标签、#each 页克隆、#if 条件页、图片占位(§5.3)
# 与 LibreOffice 保真(§5.5)的端到端路径。与私有 hai_mate 金样本互不影响。
#
#   bundle exec ruby tools/build_mini_golden.rb [输出路径]
require "fileutils"
require "powertom"
require_relative File.expand_path("../spec/support/image_factory", __dir__)

module PowerTomDev
  # 微型金样本:4 类页面,结构在 spec/powertom/mini_golden_spec.rb 中逐条断言
  module MiniGolden
    PLACEHOLDER_PNG = [120, 80].freeze # 1.5 比例,与 3x2 in 形状一致,不触发比例告警

    module_function

    def build(out_path)
      prs = Pptx::Presentation.new_default
      prs.slide_width = Pptx.inches(13.333)
      prs.slide_height = Pptx.inches(7.5)
      layout = prs.slide_layouts["Blank"]

      # P1 封面:单 run 标签 / 跨 run 标签(§5.1)/ 一段多标签
      cover = prs.slides.add(layout)
      textbox(cover, "mini-title", 0.5, 0.5, 8, 1) { |frame| frame.text = "{{title}}" }
      textbox(cover, "mini-split", 0.5, 2.0, 8, 1) do |frame|
        para = frame.paragraphs.first
        para.add_run("Before {{spl")
        para.add_run("it_title}} after")
      end
      textbox(cover, "mini-pair", 0.5, 3.5, 8, 1) { |frame| frame.text = "{{first}} 和 {{second}}" }

      # P2 图片:占位比例与数据图一致(1.5),替换后零裁切
      picture_slide = prs.slides.add(layout)
      placeholder = PowerTomDev::ImageFactory.write_png(File.join(Dir.mktmpdir, "placeholder.png"),
                                                        *PLACEHOLDER_PNG)
      pic = picture_slide.shapes.add_picture(placeholder,
                                             at: [Pptx.inches(1), Pptx.inches(1)],
                                             width: Pptx.inches(3), height: Pptx.inches(2))
      pic.name = "powertom:image:cover"
      textbox(picture_slide, "mini-caption", 1.0, 3.5, 6, 0.6) { |frame| frame.text = "{{caption}}" }

      # P3 循环页:#each 克隆;detail 故意拆成两个 run,验证克隆页内的 run 合并
      each_slide = prs.slides.add(layout)
      each_slide.notes = "{{#each items}}"
      textbox(each_slide, "mini-headline", 0.5, 0.5, 8, 1) { |frame| frame.text = "{{headline}}" }
      textbox(each_slide, "mini-detail", 0.5, 2.0, 8, 1) do |frame|
        para = frame.paragraphs.first
        para.add_run("{{de")
        para.add_run("tail}}")
      end

      # P4 条件页:#if 为假删页
      if_slide = prs.slides.add(layout)
      if_slide.notes = "{{#if show_extra}}"
      textbox(if_slide, "mini-extra", 0.5, 0.5, 8, 1) { |frame| frame.text = "{{extra_note}}" }

      # P5 静态尾页:克隆/删除后仍应保留
      closing = prs.slides.add(layout)
      textbox(closing, "mini-end", 0.5, 3.0, 8, 1) { |frame| frame.text = "THE END" }

      FileUtils.mkdir_p(File.dirname(out_path))
      prs.save(out_path)
      verify(out_path)
      out_path
    end

    def textbox(slide, name, left, top, width, height)
      box = slide.shapes.add_textbox(at: [Pptx.inches(left), Pptx.inches(top)],
                                     size: [Pptx.inches(width), Pptx.inches(height)])
      box.name = name
      yield box.text_frame
      box
    end

    # 生成后重读,守卫 run 结构与占位命名(与 mini_golden_spec 的断言一一对应)
    def verify(path)
      adapter = PowerTom::Adapter::RubyPptxAdapter.new
      prs = adapter.open(path)
      contexts = adapter.paragraph_contexts(prs)
      runs = ->(shape) { contexts.find { |c| c[:shape] == shape }.fetch(:run_texts) }
      raise "mini-split 必须是 2 个 run" unless runs.call("mini-split").size == 2
      raise "mini-detail 必须是 2 个 run" unless runs.call("mini-detail").size == 2

      pictures = adapter.picture_contexts(prs)
      raise "缺少 powertom:image:cover 占位" unless pictures.any? { |c| c[:field] == "cover" }
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || "spec/fixtures/mini/template.pptx"
  puts "mini golden generated: #{PowerTomDev::MiniGolden.build(out)}"
end
