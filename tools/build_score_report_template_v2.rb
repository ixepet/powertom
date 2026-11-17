# frozen_string_literal: true

# 成绩分析报告 · v2 结构脚手架(对齐真实 9 页 deck:4 张表格 + 文本指标)。
# 与 v1 的区别:班级/学科/分数段/关注学生改为表格行循环,不再"每班一页 + 图表 PNG"。
#
# 用法: ruby tools/build_score_report_template_v2.rb [输出路径]

require "ruby_pptx"
require "fileutils"
require_relative "build_score_report_template"

module PowerTomDev
  module ScoreReportScaffoldV2
    WIDE = 40.0 / 3
    HIGH = 7.5
    FONT = PowerTomDev::ScoreReportScaffold::FONT

    module_function

    def build(path = "examples/score_report/template_scaffold_v2.pptx")
      prs = Pptx::Presentation.new_default
      prs.slide_width = Pptx.inches(WIDE)
      prs.slide_height = Pptx.inches(HIGH)
      blank = prs.slide_layouts["Blank"]

      cover(prs, blank)
      overview(prs, blank)
      comparison(prs, blank)
      class_table(prs, blank)
      subject_table(prs, blank)
      distribution_table(prs, blank)
      student_table(prs, blank)
      measures(prs, blank)
      appendix(prs, blank)

      FileUtils.mkdir_p(File.dirname(path))
      prs.save(path)
      path
    end

    # ---- P1 封面 ----
    def cover(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "封面-标题", 1.0, 0.9, 11.3, 1.6, "{{report_title}}", 40, bold: true)
      text(slide, "封面-副标题", 1.0, 2.7, 11.3, 0.8, "{{grade_name}} · {{exam_name}}", 24)
      text(slide, "封面-学校", 1.0, 3.6, 11.3, 0.7, "{{school_name}}", 20)
      text(slide, "封面-日期", 1.0, 6.2, 6.0, 0.5, "{{report_date:date.cn}}", 16)
    end

    # ---- P2 整体表现 ----
    def overview(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "总览-标题", 0.6, 0.35, 8.0, 0.7, "整体表现", 28, bold: true)
      4.times do |i|
        left = 0.6 + (i * 3.1)
        text(slide, "卡#{i + 1}-标签", left, 1.35, 2.9, 0.4, "{{kpis[#{i}].label}}", 14)
        text(slide, "卡#{i + 1}-数值", left, 1.75, 2.9, 1.0, "{{kpis[#{i}].value}}", 40, bold: true)
        text(slide, "卡#{i + 1}-变化", left, 2.85, 2.9, 0.4, "{{kpis[#{i}].delta}}", 16)
      end
      text(slide, "总评", 0.9, 4.4, 11.5, 0.9, "{{kpi_note}}", 16)
    end

    # ---- P3 班级均分对比(表格行循环,班级数量可变) ----
    def comparison(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "对比-标题", 0.6, 0.35, 8.0, 0.7, "班级均分对比", 28, bold: true)
      table(
        slide, "班级均分表",
        %w[班级 平均分],
        ["{{classes[].name}}", "{{classes[].avg}}"],
        nil,
        at: [0.8, 1.3], width: 11.5
      )
      text(slide, "对比-结论", 0.9, 5.9, 11.5, 0.9, "{{class_comparison_note}}", 16)
    end

    # ---- P4 班级成绩明细 ----
    def class_table(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "明细-标题", 0.5, 0.3, 8.0, 0.6, "班级成绩明细", 28, bold: true)
      table(
        slide, "班级明细表",
        %w[班级 参考人数 平均分 优秀率 及格率 环比上次 排名],
        ["{{classes[].name}}", "{{classes[].count}}", "{{classes[].avg}}",
         "{{classes[].excellent}}", "{{classes[].pass}}", "{{classes[].delta}}",
         "{{classes[].rank}}"],
        ["年级合计 / 平均", "{{totals.class_count}}", "{{totals.avg}}",
         "{{totals.excellent}}", "{{totals.pass}}", "—", "—"],
        at: [0.4, 1.05], width: 12.5
      )
      text(slide, "明细-口径", 0.5, 6.15, 12.3, 0.5, "{{class_note}}", 12)
    end

    # ---- P5 学科分析 ----
    def subject_table(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "学科-标题", 0.5, 0.3, 8.0, 0.6, "学科分析", 28, bold: true)
      table(
        slide, "学科分析表",
        %w[学科 满分 年级平均分 得分率 最高班级 主要失分点],
        ["{{subjects[].name}}", "{{subjects[].full}}", "{{subjects[].avg}}",
         "{{subjects[].rate}}", "{{subjects[].top}}", "{{subjects[].weak}}"],
        ["总分", "{{totals.full_score}}", "{{totals.avg}}", "{{totals.rate}}", "—", "—"],
        at: [0.4, 1.05], width: 12.5
      )
      text(slide, "学科-结论", 0.5, 6.15, 12.3, 0.5, "{{subject_note}}", 12)
    end

    # ---- P6 分数段分布 ----
    def distribution_table(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "分数段-标题", 0.5, 0.3, 9.0, 0.6, "总分分数段分布", 28, bold: true)
      table(
        slide, "分数段表",
        ["班级", "≥629 优秀", "555–628", "444–554", "<444 未及格", "参考人数"],
        ["{{distribution[].name}}", "{{distribution[].excellent}}", "{{distribution[].good}}",
         "{{distribution[].pass}}", "{{distribution[].fail}}", "{{distribution[].count}}"],
        ["年级合计", "{{totals.excellent_count}}", "{{totals.good_count}}",
         "{{totals.pass_count}}", "{{totals.fail_count}}", "{{totals.class_count}}"],
        at: [0.4, 1.05], width: 12.5
      )
      text(slide, "分数段-结论", 0.5, 6.15, 12.3, 0.5, "{{distribution_note}}", 12)
    end

    # ---- P7 重点关注学生 ----
    def student_table(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "学生-标题", 0.5, 0.3, 9.0, 0.6, "重点关注学生(学业预警)", 28, bold: true)
      table(
        slide, "学生预警表",
        %w[学生 班级 总分 薄弱学科 关注建议],
        ["{{students[].name}}", "{{students[].class_name}}", "{{students[].total}}",
         "{{students[].weak}}", "{{students[].advice}}"],
        nil,
        at: [0.4, 1.05], width: 12.5
      )
      text(slide, "学生-说明", 0.5, 6.5, 12.3, 0.5, "{{student_note}}", 12)
    end

    # ---- P8 改进措施 ----
    def measures(prs, layout)
      slide = prs.slides.add(layout)
      text(slide, "措施-标题", 0.6, 0.35, 9.0, 0.7, "改进措施与下一步", 28, bold: true)
      3.times do |i|
        text(slide, "措施#{i + 1}", 0.9, 1.5 + (i * 1.35), 11.5, 1.0,
             "{{measures[#{i}].text}}", 18)
      end
    end

    # ---- P9 附录 ----
    def appendix(prs, layout)
      slide = prs.slides.add(layout)
      slide.notes = "{{#if show_appendix}}"
      text(slide, "附录-标题", 0.6, 0.35, 9.0, 0.7, "附录:统计口径", 28, bold: true)
      text(slide, "附录-数据来源", 0.9, 1.5, 11.5, 0.6, "{{data_source}}", 16)
      text(slide, "附录-口径", 0.9, 2.5, 11.5, 2.2,
           "总分 740 分；优秀线为总分得分率 ≥ 85%（≥629 分）；及格线为 ≥ 60%（≥444 分）。" \
           "单科优秀线同为得分率 ≥ 85%，统计口径以教务系统导出为准。", 14)
    end

    # ---- 工具 ----

    def text(slide, name, left, top, width, height, content, size, bold: false)
      PowerTomDev::ScoreReportScaffold.text(
        slide, name, left, top, width, height, content, size, bold: bold
      )
    end

    def table(slide, name, headers, template_row, total_row, at:, width:)
      rows = total_row ? 3 : 2
      frame = slide.shapes.add_table(
        rows, headers.size,
        at: [Pptx.inches(at[0]), Pptx.inches(at[1])],
        size: [Pptx.inches(width), Pptx.inches(1.0)]
      )
      frame.name = name
      table = frame.table
      headers.each_with_index { |value, c| fill_cell(table, 0, c, value, 12, bold: true) }
      template_row.each_with_index { |value, c| fill_cell(table, 1, c, value, 12) }
      total_row&.each_with_index { |value, c| fill_cell(table, 2, c, value, 12, bold: true) }

      heights = total_row ? [0.55, 0.45, 0.55] : [0.55, 0.45]
      heights.each_with_index { |inches, i| table.rows[i].element.set("h", Pptx.inches(inches).emu.to_s) }
      ext = frame.element.xpath("./p:xfrm/a:ext").first
      ext&.set("cy", heights.sum { |h| Pptx.inches(h).emu }.to_s)
      frame
    end

    def fill_cell(table, row, col, value, size, bold: false)
      cell = table.cell(row, col)
      cell.text = value
      run = cell.text_frame.paragraphs.first.runs.first
      return unless run

      run.font.name = FONT
      run.font.size = Pptx.pt(size)
      run.font.bold = true if bold
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  out = ARGV[0] || "examples/score_report/template_scaffold_v2.pptx"
  puts "v2 scaffold generated: #{PowerTomDev::ScoreReportScaffoldV2.build(out)}"
end
