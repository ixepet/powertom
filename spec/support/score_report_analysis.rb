# frozen_string_literal: true

require "date"

# 成绩分析服务 v2 输入样例(多个 spec 共享)。
module PowerTomDev
  module ScoreReportAnalysis
    module_function

    def full(students: nil, measures: nil)
      students ||= [
        { name: "学生A", class_name: "初二(1)班", total: 398,
          weak_subjects: ["物理"], advice: "基础题过关训练" },
        { name: "学生B", class_name: "初二(2)班", total: 405,
          weak_subjects: %w[物理 数学], advice: "双科结对辅导" }
      ]
      {
        school: { name: "示例中学" },
        exam: { name: "期末统考", date: Date.new(2026, 1, 20) },
        grade: { name: "初二年级" },
        overall: {
          average: 83.4, excellent_rate: 0.323, pass_rate: 0.917, student_count: 121,
          previous: { average: 81.6, excellent_rate: 0.30, pass_rate: 0.905, student_count: 115 }
        },
        class_stats: [
          { name: "初二(1)班", count: 61, average: 81.5, excellent_rate: 0.279,
            pass_rate: 0.934, previous_average: 80.3, rank: 1 },
          { name: "初二(2)班", count: 60, average: 85.4, excellent_rate: 0.367,
            pass_rate: 0.900, previous_average: 83.0, rank: 2 }
        ],
        subjects: [
          { name: "语文", full_score: 120, average: 100.9, top_class: "初二(2)班",
            weak_point: "作文立意与议论文结构" },
          { name: "物理", full_score: 100, average: 73.8, top_class: "初二(1)班",
            weak_point: "实验设计与结论表述" }
        ],
        distribution: [
          { name: "初二(1)班", excellent: 17, good: 25, pass: 15, fail: 4, count: 61 },
          { name: "初二(2)班", excellent: 22, good: 20, pass: 12, fail: 6, count: 60 }
        ],
        focus_students: students,
        measures: measures || [
          "物理专题:每周一次实验训练",
          "数学规范:证明题步骤分训练",
          "班级帮扶:2 班结对,月度复盘"
        ],
        data_source: "教务系统期末统考成绩",
        appendix: true
      }
    end

    def many_students(count = 12)
      Array.new(count) do |i|
        { name: "学生#{i + 1}", class_name: "初二(1)班", total: 380 + i,
          weak_subjects: ["物理"], advice: "基础巩固" }
      end
    end
  end
end
