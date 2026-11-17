# frozen_string_literal: true

require "securerandom"
require "tempfile"
require "powertom"

module ScoreReport
  # 导出编排(阶段 1 参考实现,Rails 侧复制到 app/services/reports/deck_exporter.rb)。
  #
  # 职责:预检 → 渲染 → 上传 → 观测数据,并把所有失败翻译成两类信息:
  #   user_message  给老师看的(不暴露技术细节)
  #   message/detail 给日志与告警看的(含原始错误)
  #
  # 预检策略:
  #   1. 先跑带数据的 PowerTom.check;通过则直接渲染(常见路径只检查一次)
  #   2. 不通过时再跑不带数据的 check,区分是模板问题还是数据问题
  #      —— 不靠错误文案猜分类
  class DeckExporter
    class Error < StandardError
      attr_reader :user_message

      def initialize(user_message, detail: nil)
        @user_message = user_message
        super(detail || user_message)
      end
    end

    # 数据不完整(老师可理解:稍后重试/联系班主任补数据)
    class DataError < Error; end

    # 模板问题(需要设计师/运维介入)
    class TemplateError < Error; end

    # 已生成但保存失败(可重试)
    class UploadError < Error; end

    Result = Struct.new(:url, :key, :warnings, :slide_count, :duration_ms, :template_version,
                        keyword_init: true)

    USER_MESSAGES = {
      data: "本次分析数据不完整,暂时无法生成报告",
      template: "报告模板异常,请联系管理员",
      render: "报告生成失败,请稍后重试",
      upload: "报告已生成但保存失败,请稍后重试"
    }.freeze

    # uploader: ->(local_path, object_key) { url }
    def initialize(template_path:, uploader:, template_version: nil,
                   key_prefix: "score-report", preflight: true, strict: true)
      @template_path = template_path
      @uploader = uploader
      @template_version = template_version
      @key_prefix = key_prefix
      @preflight = preflight
      @strict = strict
    end

    # data: ReportDataBuilder 产出的契约 Hash
    def call(data:)
      started = monotonic
      preflight!(data) if @preflight

      rendered = render!(data)
      key = object_key
      path = write_temp(rendered)
      begin
        url = upload(path, key)
      ensure
        File.delete(path) if File.exist?(path)
      end

      Result.new(
        url: url,
        key: key,
        warnings: rendered.warnings,
        slide_count: rendered.slide_count,
        duration_ms: ((monotonic - started) * 1000).round,
        template_version: @template_version
      )
    end

    private

    # ---- 预检 ----

    def preflight!(data)
      result = PowerTom.check(@template_path, data: data)
      return if result.ok?

      if template_broken?
        raise TemplateError.new(USER_MESSAGES[:template], detail: result.report)
      end

      raise DataError.new(USER_MESSAGES[:data], detail: result.report)
    end

    # 不带数据再查一次:能报错说明模板本身有问题(语法/未注册 formatter/指令)
    def template_broken?
      PowerTom.check(@template_path).errors.any?
    end

    # ---- 渲染 ----

    def render!(data)
      PowerTom.render(@template_path, data: data, strict: @strict)
    rescue PowerTom::MissingDataError => e
      raise DataError.new(USER_MESSAGES[:data], detail: e.message)
    rescue PowerTom::TemplateSyntaxError, PowerTom::InvalidTemplateError => e
      raise TemplateError.new(USER_MESSAGES[:template], detail: e.message)
    rescue PowerTom::Error => e
      raise Error.new(USER_MESSAGES[:render], detail: "#{e.class}: #{e.message}")
    end

    # ---- 落盘与上传 ----

    def write_temp(rendered)
      file = Tempfile.new(["score-report", ".pptx"])
      path = file.path
      file.close
      rendered.save(path)
      path
    rescue SystemCallError => e
      raise Error.new(USER_MESSAGES[:render], detail: "临时文件写入失败:#{e.message}")
    end

    def upload(path, key)
      @uploader.call(path, key)
    rescue StandardError => e
      raise UploadError.new(USER_MESSAGES[:upload], detail: "#{e.class}: #{e.message}")
    end

    def object_key
      "#{@key_prefix}/#{Time.now.strftime('%Y%m%d')}/#{SecureRandom.uuid}.pptx"
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
