# frozen_string_literal: true

require_relative "deck_exporter"

module ScoreReport
  # 异步导出任务(阶段 1 参考实现,Rails 侧包一层 ActiveJob 即可)。
  #
  # 设计:不依赖具体队列。perform 返回 Outcome,由队列适配器按协议执行:
  #   :succeeded       成功,result 里是 URL 与埋点数据
  #   :retry_scheduled 可重试失败,按 retry_in 秒后再入队,attempt + 1
  #   :failed          终态失败,已通知,不再重试
  #
  # 重试策略:
  #   - 可重试:上传失败(UploadError)、渲染兜底失败(Error)→ 指数退避 10s / 20s / 40s(封顶 300s)
  #   - 不重试:数据不完整(DataError)、模板异常(TemplateError)、数据组装失败、未知异常
  #     —— 这些重试多少次结果都一样,重试只会拖慢给老师的反馈
  class ReportDeckJob
    DEFAULT_MAX_ATTEMPTS = 3
    BASE_RETRY_SECONDS = 10
    MAX_RETRY_SECONDS = 300

    Outcome = Struct.new(:status, :result, :error, :attempt, :max_attempts, :retry_in,
                         keyword_init: true) do
      def succeeded? = status == :succeeded

      def retry_scheduled? = status == :retry_scheduled

      def failed? = status == :failed

      # 给老师看的消息;技术细节在 error.message / error 的原始消息里
      def user_message
        return nil unless error

        error.respond_to?(:user_message) ? error.user_message : error.message
      end
    end

    # builder:  ->(analysis) { contract_hash }
    # exporter: 响应 call(data:)
    # notifier: ->(event, payload) { ... },event 为 :succeeded / :retrying / :failed
    def initialize(builder:, exporter:, notifier: nil, max_attempts: DEFAULT_MAX_ATTEMPTS)
      @builder = builder
      @exporter = exporter
      @notifier = notifier
      @max_attempts = max_attempts
    end

    def perform(analysis:, attempt: 1)
      data = @builder.call(analysis)
      result = @exporter.call(data: data)

      notify(:succeeded, attempt: attempt, url: result.url, slide_count: result.slide_count)
      Outcome.new(status: :succeeded, result: result, attempt: attempt,
                  max_attempts: @max_attempts)
    rescue DeckExporter::DataError, DeckExporter::TemplateError => e
      fail_outcome(e, attempt, retryable: false)
    rescue DeckExporter::UploadError, DeckExporter::Error => e
      fail_outcome(e, attempt, retryable: true)
    rescue StandardError => e
      # 数据组装失败或未预期异常:不重试,避免无意义地重复消耗
      fail_outcome(e, attempt, retryable: false)
    end

    # 指数退避:10s、20s、40s……封顶 300s
    def retry_in(attempt)
      [BASE_RETRY_SECONDS * (2**(attempt - 1)), MAX_RETRY_SECONDS].min
    end

    private

    def fail_outcome(error, attempt, retryable:)
      if retryable && attempt < @max_attempts
        wait = retry_in(attempt)
        notify(:retrying, attempt: attempt, next_attempt: attempt + 1,
                          retry_in: wait, user_message: message_of(error))
        Outcome.new(status: :retry_scheduled, error: error, attempt: attempt,
                    max_attempts: @max_attempts, retry_in: wait)
      else
        notify(:failed, attempt: attempt, user_message: message_of(error))
        Outcome.new(status: :failed, error: error, attempt: attempt,
                    max_attempts: @max_attempts)
      end
    end

    def message_of(error)
      error.respond_to?(:user_message) ? error.user_message : error.message
    end

    def notify(event, payload)
      @notifier&.call(event, payload)
    end
  end
end
