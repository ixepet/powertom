# frozen_string_literal: true

require "date"
require "powertom"

module ScoreReport
  # 把成绩分析服务的结构化结果转换成 v2 模板契约数据。
  #
  # v2 对齐真实 9 页 deck:班级/学科/分数段/关注学生都是表格行循环,不再有图片。
  # 职责边界:
  #   - 只做「组装 + 格式化 + 一致性校验」,不碰 pptx
  #   - 固定条数:KPI 4 个、措施 3 条、关注学生最多 10 人
  #   - 结论文案可由 analysis[:notes] 覆盖,缺省按数据自动生成
  #   - 缺数据、分布与人数对不上,抛人类可读错误
  class DataBuilder
    class Error < StandardError; end

    KPI_COUNT = 4
    MEASURE_COUNT = 3
    STUDENT_LIMIT = 10

    def initialize(analysis:)
      @analysis = analysis
    end

    def build
      class_stats = fetch_array!(:class_stats, "缺少班级成绩数据,无法生成报告")
      subjects = fetch_array!(:subjects, "缺少学科成绩数据,无法生成报告")
      distribution = fetch_array!(:distribution, "缺少分数段分布数据,无法生成报告")
      students = Array(@analysis[:focus_students])
      validate_distribution!(distribution, class_stats)

      totals = totals(class_stats, distribution, subjects)
      {
        report_title: report_title,
        school_name: fetch!(fetch!(@analysis, :school), :name),
        grade_name: fetch!(fetch!(@analysis, :grade), :name),
        exam_name: fetch!(fetch!(@analysis, :exam), :name),
        report_date: fetch!(fetch!(@analysis, :exam), :date),
        kpis: kpis,
        kpi_note: note(:kpi, ""),
        class_comparison_note: note(:class_comparison, default_class_note(class_stats)),
        classes: class_stats.map { |row| class_entry(row) },
        class_note: note(:class, "优秀线为总分得分率 ≥ 85%,及格线为 ≥ 60%"),
        subjects: subjects.map { |row| subject_entry(row) },
        subject_note: note(:subject, default_subject_note(subjects)),
        distribution: distribution.map { |row| distribution_entry(row) },
        distribution_note: note(:distribution, default_distribution_note(distribution)),
        students: students.first(STUDENT_LIMIT).map { |row| student_entry(row) },
        student_note: note(:student, default_student_note(students)),
        measures: measures,
        totals: totals,
        show_appendix: @analysis.fetch(:appendix, true) != false,
        data_source: @analysis[:data_source] || "教务系统#{fetch!(fetch!(@analysis, :exam), :name)}成绩"
      }
    end

    private

    def report_title
      @analysis[:title] ||
        "#{fetch!(fetch!(@analysis, :grade), :name)}#{fetch!(fetch!(@analysis, :exam), :name)}成绩分析"
    end

    # ---- 指标卡 ----

    def kpis
      overall = fetch!(@analysis, :overall)
      previous = overall[:previous] || {}
      [
        kpi("平均分", decimal(fetch!(overall, :average)),
            signed_delta(subtract(overall[:average], previous[:average]), " 分")),
        kpi("优秀率(≥85%)", percent(fetch!(overall, :excellent_rate)),
            signed_delta(percentage_points(overall[:excellent_rate], previous[:excellent_rate]), "pt")),
        kpi("及格率(≥60%)", percent(fetch!(overall, :pass_rate)),
            signed_delta(percentage_points(overall[:pass_rate], previous[:pass_rate]), "pt")),
        kpi("参考人数", fetch!(overall, :student_count).to_s,
            signed_delta(subtract(overall[:student_count], previous[:student_count]), " 人", precision: 0))
      ]
    end

    def kpi(label, value, delta)
      { label: label, value: value, delta: delta }
    end

    # ---- 表格行 ----

    def class_entry(row)
      average = fetch!(row, :average)
      previous = row[:previous_average]
      {
        name: fetch!(row, :name),
        count: fetch!(row, :count),
        avg: decimal(average),
        excellent: percent(fetch!(row, :excellent_rate)),
        pass: percent(fetch!(row, :pass_rate)),
        delta: signed_delta(previous.nil? ? nil : average - previous),
        rank: fetch!(row, :rank)
      }
    end

    def subject_entry(row)
      full = fetch!(row, :full_score)
      average = fetch!(row, :average)
      {
        name: fetch!(row, :name),
        full: full,
        avg: decimal(average),
        rate: percent(average.to_f / full),
        top: fetch!(row, :top_class),
        weak: fetch!(row, :weak_point)
      }
    end

    def distribution_entry(row)
      {
        name: fetch!(row, :name),
        excellent: fetch!(row, :excellent),
        good: fetch!(row, :good),
        pass: fetch!(row, :pass),
        fail: fetch!(row, :fail),
        count: fetch!(row, :count)
      }
    end

    def student_entry(row)
      {
        name: fetch!(row, :name),
        class_name: fetch!(row, :class_name),
        total: fetch!(row, :total),
        weak: join_list(row[:weak_subjects], "无明显薄弱学科"),
        advice: row[:advice] || "—"
      }
    end

    # ---- 合计行:由明细汇总,不信任手工输入 ----

    def totals(class_stats, distribution, subjects)
      overall = fetch!(@analysis, :overall)
      full_score = subjects.sum { |row| fetch!(row, :full_score).to_i }
      {
        class_count: class_stats.sum { |row| fetch!(row, :count).to_i },
        avg: decimal(fetch!(overall, :average)),
        excellent: percent(fetch!(overall, :excellent_rate)),
        pass: percent(fetch!(overall, :pass_rate)),
        full_score: full_score,
        rate: percent(fetch!(overall, :average).to_f / full_score),
        excellent_count: distribution.sum { |row| fetch!(row, :excellent).to_i },
        good_count: distribution.sum { |row| fetch!(row, :good).to_i },
        pass_count: distribution.sum { |row| fetch!(row, :pass).to_i },
        fail_count: distribution.sum { |row| fetch!(row, :fail).to_i }
      }
    end

    # 每行四个分数段之和必须等于参考人数,否则模板出来会自相矛盾
    def validate_distribution!(distribution, class_stats)
      distribution.each do |row|
        sum = %i[excellent good pass fail].sum { |key| fetch!(row, key).to_i }
        count = fetch!(row, :count).to_i
        next if sum == count

        raise Error,
              "分数段数据不一致:#{fetch!(row, :name)} 四段合计 #{sum} 人,参考人数 #{count} 人"
      end
      dist_total = distribution.sum { |row| fetch!(row, :count).to_i }
      class_total = class_stats.sum { |row| fetch!(row, :count).to_i }
      return if dist_total == class_total

      raise Error,
            "分数段与班级人数不一致:班级合计 #{class_total} 人,分数段合计 #{dist_total} 人"
    end

    # ---- 结论文案:优先用分析服务给的,缺省自动生成 ----

    def note(key, fallback)
      notes = @analysis[:notes] || {}
      value = notes[key]
      value.nil? || value.to_s.empty? ? fallback : value.to_s
    end

    def default_class_note(class_stats)
      best = class_stats.max_by { |row| fetch!(row, :average) }
      worst = class_stats.min_by { |row| fetch!(row, :average) }
      "#{fetch!(best, :name)} 领先,#{fetch!(worst, :name)} 低于年级均分"
    end

    def default_subject_note(subjects)
      weakest = subjects.min_by { |row| fetch!(row, :average).to_f / fetch!(row, :full_score) }
      rate = percent(fetch!(weakest, :average).to_f / fetch!(weakest, :full_score))
      "#{fetch!(weakest, :name)} 是共性短板,得分率 #{rate}"
    end

    def default_distribution_note(distribution)
      fails = distribution.sum { |row| fetch!(row, :fail).to_i }
      total = distribution.sum { |row| fetch!(row, :count).to_i }
      "未及格 #{fails} 人,占 #{percent(fails.to_f / total)}"
    end

    def default_student_note(students)
      if students.size > STUDENT_LIMIT
        "节选前 #{STUDENT_LIMIT} 人,共 #{students.size} 人触发预警"
      else
        "共 #{students.size} 人触发预警"
      end
    end

    # ---- 措施 ----

    def measures
      list = Array(@analysis[:measures])
      if list.size > MEASURE_COUNT
        raise Error, "改进措施最多 #{MEASURE_COUNT} 条(模板固定 3 条),当前 #{list.size} 条"
      end
      texts = list.map { |item| item.is_a?(Hash) ? fetch!(item, :text) : item.to_s }
      texts += ["暂无"] * (MEASURE_COUNT - texts.size)
      texts.map { |text| { text: text } }
    end

    # ---- 格式化 ----

    def decimal(value, precision = 1)
      format("%.#{precision}f", value)
    end

    def percent(rate)
      PowerTom::Formatter.apply(rate, "percent.1")
    end

    def subtract(current, previous)
      previous.nil? ? nil : current - previous
    end

    def percentage_points(current, previous)
      previous.nil? ? nil : (current - previous) * 100
    end

    def signed_delta(value, suffix = "", precision: 1)
      return "" if value.nil?
      rounded = value.round(precision)
      sign = rounded.positive? ? "+" : ""
      "#{sign}#{decimal(rounded, precision)}#{suffix}"
    end

    def join_list(list, fallback)
      items = Array(list).map(&:to_s).reject(&:empty?)
      items.empty? ? fallback : items.join("、")
    end

    # ---- 取值 ----

    def fetch_array!(key, message)
      value = @analysis[key]
      raise Error, message unless value.is_a?(Array) && !value.empty?

      value
    end

    def fetch!(hash, key)
      unless hash.is_a?(Hash) && hash.key?(key)
        raise Error, "缺少必要数据:#{key}"
      end
      hash[key]
    end
  end
end
