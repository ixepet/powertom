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
      # 注册一个 formatter。
      #
      # @param name [String] formatter 名(模板里冒号后的词)。
      # @param args [Array<String>, nil] 该 formatter 支持的**枚举**参数白名单;
      #   nil 表示"参数任意"(自定义 formatter 默认)。内置族会显式声明,
      #   让 check 阶段能在没有样例数据时报出参数写错。
      # @param numeric_arg [Boolean] 参数是数字精度(0..6)而非枚举名。
      # @yieldparam value [Object] 待格式化的值。
      # @yieldparam arg [String, nil] 模板里冒号后的参数部分。
      def register(name, args: nil, numeric_arg: false, &block)
        raise ArgumentError, "formatter name cannot be empty" if name.nil? || name.to_s.empty?
        raise ArgumentError, "formatter requires a block receiving (value, arg)" unless block

        registry[name.to_s] = block
        arg_rules[name.to_s] = if numeric_arg
                                 { type: :numeric }
                               elsif args
                                 # nil 表示"不写参数"也合法,内部统一用 "" 表示
                                 { type: :enum, values: args.map(&:to_s).freeze }
                               end
        name.to_s
      end

      def registered?(name)
        registry.key?(name.to_s)
      end

      def unregister_formatter(name)
        registry.delete(name.to_s)
        arg_rules.delete(name.to_s)
      end

      def registered_names
        registry.keys.sort
      end

      # 校验一个 formatter 规格能否用于给定的值。
      #
      # check 阶段用它提前报错:渲染期 Formatter.apply 对非法参数/类型会抛
      # PowerTom::Error,若等到渲染才发现,坏模板就绕过了 CI 门禁。
      # 这里复用 apply 本身(而不是另写一份规则),保证"校验时说的"与
      # "渲染时做的"永远是同一条规则。
      #
      # @param value [Object] 待格式化的值。
      # @param spec [String] formatter 规格,如 "currency" / "date.year_month"。
      # @return [String, nil] nil 表示规格可用;否则返回错误描述。
      def validate(value, spec)
        apply(value, spec)
        nil
      rescue PowerTom::Error => e
        e.message
      end

      # 只校验规格本身(参数是否被支持),不看值的类型。
      #
      # 参数合法性是模板自身的属性({{d:date.bogus}} 无论数据是什么都是错的),
      # 因此可以在没有样例数据时检查;值类型则必须拿到真实数据才能判。
      # 两者分开,避免用 nil 探针把"类型不对"误报成"参数不对"。
      #
      # @param spec [String] formatter 规格。
      # @return [String, nil] nil 表示参数合法;否则返回错误描述。
      def validate_spec(spec)
        return nil if spec.nil?

        name, arg = parse_spec(spec)
        unless registry.key?(name)
          raise PowerTom::Error,
                "unregistered formatter '#{name}' (available: #{registered_names.join(', ')})"
        end

        validate_spec_argument(name, arg)
      end

      # 参数规则由注册方声明;未声明(自定义 formatter)则不限制参数。
      #
      # :enum   —— 参数必须在白名单里(如 date 的 year_month/cn/short)
      # :numeric —— 参数是 0..6 的小数位数(如 currency.2)
      def validate_spec_argument(name, arg)
        rule = arg_rules[name]
        return nil if rule.nil? # 未声明规则:参数任意

        case rule[:type]
        when :enum
          allowed = rule[:values]
          # 白名单里的 "" 表示"不写参数"也合法(注册时用 nil 表示)
          return nil if arg.nil? && allowed.include?("")
          return nil if arg && allowed.include?(arg)

          raise PowerTom::Error,
                "formatter '#{name}' does not support '#{arg}' " \
                "(available: #{allowed.reject(&:empty?).join(', ')})"
        when :numeric
          return nil if arg.nil?
          return nil if arg.match?(/\A\d+\z/)

          raise PowerTom::Error,
                "formatter '#{name}' expects a decimal precision between 0 and 6, got '#{arg}'"
        end
        nil
      end

      # spec:"currency" / "percent.1" / "date.year_month";nil → nil(无格式化)
      def apply(value, spec)
        return nil if spec.nil?

        name, arg = parse_spec(spec)
        proc = registry[name]
        unless proc
          raise PowerTom::Error,
                "unregistered formatter '#{name}' (available: #{registered_names.join(', ')})"
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

      # 每个 formatter 声明支持的参数规则
      def arg_rules
        @arg_rules ||= {}
      end
    end

    # ---- 内置四族(§3.4)----

    module_function

    def numeric!(value, name)
      return value if value.is_a?(Numeric)

      raise PowerTom::Error, "formatter '#{name}' requires a number, got #{value.class}"
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

    # currency / percent / number 的参数是小数位数(0..6),不是枚举名。
    # 参数写错时 arg.to_i 会静默变成 0,渲染期不报错;check 阶段用
    # numeric_arg 显式要求参数是数字,把静默容错变成可见的 error。
    register("currency", numeric_arg: true) do |value, arg|
      v = PowerTom::Formatter.numeric!(value, "currency")
      decimals = arg ? arg.to_i.clamp(0, 6) : 2
      "¥#{PowerTom::Formatter.format_decimal(v, decimals)}"
    end

    # 比例值 ×100:0.297 → "29.7%"(percent.1);0.297 → "30%"(percent)
    register("percent", numeric_arg: true) do |value, arg|
      v = PowerTom::Formatter.numeric!(value, "percent")
      decimals = arg ? arg.to_i.clamp(0, 6) : 0
      "#{PowerTom::Formatter.format_decimal(v * 100, decimals)}%"
    end

    register("number", numeric_arg: true) do |value, arg|
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

    register("date", args: DATE_PATTERNS.keys) do |value, arg|
      unless value.respond_to?(:strftime)
        raise PowerTom::Error,
              "formatter 'date' requires a Date/Time value, got #{value.class}"
      end

      pattern = DATE_PATTERNS.fetch(arg) do
        raise PowerTom::Error,
              "formatter 'date' does not support '#{arg}' (available: nil, #{DATE_PATTERNS.keys.compact.join(', ')})"
      end
      value.strftime(pattern)
    end
  end
end
