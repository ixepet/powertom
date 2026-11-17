# frozen_string_literal: true

# 成绩分析报告 · 结构脚手架生成器(项目工具)。
#
# 按《成绩分析报告模板制作单》与 template_contract.toml 生成一份 7 页的
# 结构模板:形状名、标签、备注指令、图片占位全部符合契约,但**没有视觉设计**。
# 用途:
#   1. 设计师在它上面做视觉,只改配色/字体/位置,不动形状名与标签;
#   2. 工程师在设计师交付前就能跑通 lint → check → render 全链路。
#
# 用法:
#   ruby tools/build_score_report_template.rb [输出路径]
#   默认输出 examples/score_report/template_scaffold.pptx

require "ruby_pptx"
require "fileutils"

module PowerTomDev
  module ScoreReportScaffold
    WIDE = 40.0 / 3 # 13.333in,16:9
    HIGH = 7.5
    ASSETS = "examples/score_report/assets"
    # 占位字体:设计师替换为品牌字体;服务器渲染需安装同名或可回退的中文字体
    FONT = "PingFang SC"

    module_function

    def build(path = "examples/score_report/template_scaffold.pptx")
      prs = Pptx::Presentation.new_default
      prs.slide_width = Pptx.inches(WIDE)
      prs.slide_height = Pptx.inches(HIGH)
      blank = prs.slide_layouts["Blank"]

      cover(prs, blank)
      overview(prs, blank)
      class_comparison(prs, blank)
      class_detail(prs, blank)
      subject(prs, blank)
      tips(prs, blank)
      appendix(prs, blank)

      FileUtils.mkdir_p(File.dirname(path))
      prs.save(path)
      path
    end

    # ---- 各页 ----

    def cover(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "封面-标题", 1.0, 0.9, 11.3, 1.6, "{{report_title}}", 40, bold: true)
      text(slide, "封面-副标题", 1.0, 2.7, 11.3, 0.8, "{{school_name}} · {{exam_name}}", 22)
      text(slide, "封面-日期", 1.0, 6.2, 6.0, 0.5, "{{report_date:date.cn}}", 16)
    end

    def overview(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "总览-标题", 0.6, 0.35, 8.0, 0.7, "整体表现", 28, bold: true)
      4.times do |i|
        left = 0.6 + (i * 3.1)
        text(slide, "卡#{i + 1}-标签", left, 1.35, 2.9, 0.4, "{{kpis[#{i}].label}}", 14)
        text(slide, "卡#{i + 1}-数值", left, 1.75, 2.9, 1.0, "{{kpis[#{i}].value}}", 40, bold: true)
        text(slide, "卡#{i + 1}-变化", left, 2.85, 2.9, 0.4, "{{kpis[#{i}].delta}}", 16)
      end
      picture(slide, "powertom:image:overview_chart", "#{ASSETS}/overview.png",
              3.5, 3.6, 6.3, 3.54)
    end

    def class_comparison(prs, layout)
      slide = prs.slides.add(layout)
      picture(slide, "powertom:image:class_rank_chart", "#{ASSETS}/class_rank.png",
              3.5, 1.2, 6.3, 3.54)
      text(slide, "对比-结论", 1.0, 5.2, 11.3, 0.8, "{{class_comparison_note}}", 16)
    end

    def class_detail(prs, layout)
      slide = prs.slides.add(layout)
      slide.notes = "{{#each classes}}"
      text(slide, "班级-标题", 0.8, 0.6, 5.2, 0.9, "{{name}}", 32, bold: true)
      text(slide, "班级-均分", 0.8, 1.7, 3.0, 1.2, "{{avg_score}}", 48, bold: true)
      text(slide, "班级-排名", 4.0, 2.0, 2.0, 0.5, "{{rank}}", 20)
      text(slide, "班级-薄弱学科", 0.8, 3.3, 5.2, 0.5, "薄弱学科:{{weak_subject}}", 18)
      text(slide, "班级-重点关注", 0.8, 3.9, 5.2, 0.5, "重点关注:{{focus_students}}", 18)
      picture(slide, "powertom:image:chart", "#{ASSETS}/class_3.png", 6.4, 1.5, 6.0, 4.5)
    end

    def subject(prs, layout)
      slide = prs.slides.add(layout)
      picture(slide, "powertom:image:subject_chart", "#{ASSETS}/subject.png",
              3.5, 1.0, 6.3, 3.54)
      text(slide, "学科-结论", 1.0, 5.0, 11.3, 0.8, "{{subject_note}}", 16)
    end

    def tips(prs, layout)
      slide = prs.slides.add(layout)
      5.times do |i|
        text(slide, "建议#{i + 1}", 0.9, 0.9 + (i * 1.15), 11.5, 0.8,
             "{{tips[#{i}].text}}", 18)
      end
    end

    def appendix(prs, layout)
      slide = prs.slides.add(layout)
      slide.notes = "{{#if show_appendix}}"
      text(slide, "附录-数据来源", 0.9, 1.4, 11.0, 0.6, "{{data_source}}", 16)
      text(slide, "附录-口径说明", 0.9, 2.4, 11.0, 1.5,
           "优秀线为年级前 30%,及格线为 60 分;统计口径以教务系统导出为准。", 14)
    end

    # ---- 小工具 ----

    def text(slide, name, left, top, width, height, content, size, bold: false)
      box = slide.shapes.add_textbox(
        at: [Pptx.inches(left), Pptx.inches(top)],
        size: [Pptx.inches(width), Pptx.inches(height)]
      )
      box.name = name
      frame = box.text_frame
      frame.text = content
      run = frame.paragraphs.first.runs.first
      run.font.name = FONT
      run.font.size = Pptx.pt(size)
      run.font.bold = true if bold
      box
    end

    def picture(slide, name, file, left, top, width, height)
      pic = slide.shapes.add_picture(
        file,
        at: [Pptx.inches(left), Pptx.inches(top)],
        width: Pptx.inches(width),
        height: Pptx.inches(height)
      )
      pic.name = name
      pic
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || "examples/score_report/template_scaffold.pptx"
  path = PowerTomDev::ScoreReportScaffold.build(out)
  puts "scaffold template generated: #{path}"
end
