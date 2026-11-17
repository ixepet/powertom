# frozen_string_literal: true

require "date"

module PowerTom
  # §3.4 Formatter:{{path:name}} / {{path:name.arg}}
  # 冒号后的词映射到注册的 proc;proc 收到 (value, arg),返回值 to_s 后落盘。
  #
  # 内置 currency / percent / number / date 四族;
  # 自定义:PowerTom.register_formatter("rmb_upper") { |value, arg| ... }
  module Formatter
    class << self
      def register(name, &block)
        raise ArgumentError, "formatter 名不能为空" if name.nil? || name.to_s.empty?
        raise ArgumentError, "formatter 需要接收 (value, arg) 的 block" unless block

        registry[name.to_s] = block
        name.to_s
      end

      def registered?(name)
        registry.key?(name.to_s)
      end

      def unregister_formatter(name)
        registry.delete(name.to_s)
      end

      def registered_names
        registry.keys.sort
      end

      # spec:"currency" / "percent.1" / "date.year_month";nil → nil(无格式化)
      def apply(value, spec)
        return nil if spec.nil?

        name, arg = parse_spec(spec)
        proc = registry[name]
        unless proc
          raise PowerTom::Error,
                "未注册的 formatter '#{name}'(可用:#{registered_names.join(', ')})"
        end
        proc.call(value, arg).to_s
      end

      def parse_spec(spec)
        parts = spec.split(".")
        arg = parts.length > 1 ? parts[1..].join(".") : nil
        [parts.first, arg]
      end

      private

      def registry
        @registry ||= {}
      end
    end

    # ---- 内置四族(§3.4)----

    module_function

    def numeric!(value, name)
      return value if value.is_a?(Numeric)

      raise PowerTom::Error, "formatter '#{name}' 要求数字,得到 #{value.class}"
    end

    def thousands(int_str)
      int_str.gsub(/\B(?=(\d{3})+(?!\d))/, ",")
    end

    def format_decimal(value, precision)
      formatted = format("%.#{precision}f", value)
      sign = formatted.start_with?("-") ? "-" : ""
      int_part, dot, frac = formatted.delete_prefix("-").partition(".")
      "#{sign}#{thousands(int_part)}#{dot}#{frac}"
    end

    register("currency") do |value, arg|
      v = PowerTom::Formatter.numeric!(value, "currency")
      decimals = arg ? arg.to_i.clamp(0, 6) : 2
      "¥#{PowerTom::Formatter.format_decimal(v, decimals)}"
    end

    # 比例值 ×100:0.297 → "29.7%"(percent.1);0.297 → "30%"(percent)
    register("percent") do |value, arg|
      v = PowerTom::Formatter.numeric!(value, "percent")
      decimals = arg ? arg.to_i.clamp(0, 6) : 0
      "#{PowerTom::Formatter.format_decimal(v * 100, decimals)}%"
    end

    register("number") do |value, arg|
      v = PowerTom::Formatter.numeric!(value, "number")
      decimals = arg ? arg.to_i.clamp(0, 6) : 0
      PowerTom::Formatter.format_decimal(v, decimals)
    end

    DATE_PATTERNS = {
      nil => "%Y-%m-%d",
      "year_month" => "%Y年%m月",
      "cn" => "%Y年%m月%d日",
      "short" => "%m/%d"
    }.freeze

    register("date") do |value, arg|
      raise PowerTom::Error, "formatter 'date' 要求 Date/Time,得到 #{value.class}" unless value.respond_to?(:strftime)

      pattern = DATE_PATTERNS.fetch(arg) do
        raise PowerTom::Error,
              "formatter 'date' 不支持 '#{arg}'(可用:nil, #{DATE_PATTERNS.keys.compact.join(', ')})"
      end
      value.strftime(pattern)
    end
  end
end
