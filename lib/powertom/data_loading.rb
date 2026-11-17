# frozen_string_literal: true

require "date"
require "tomlrb"

module PowerTom
  # 数据装载。TOML 是 gem 的默认数据格式(约定优于配置):
  #   PowerTom.render("t.pptx", data: "data.toml")   # String → 按路径读 TOML
  #   PowerTom.render("t.pptx", data: { ... })       # 直接传 Hash
  module DataLoading
    module_function

    def coerce(data)
      return data unless data.is_a?(String)

      unless data.end_with?(".toml")
        raise InvalidTemplateError,
              "data file #{data} is not .toml: TOML is PowerTom's default data format; v0 only supports .toml"
      end
      raise InvalidTemplateError, "data file not found: #{data}" unless File.file?(data)

      normalize_dates(Tomlrb.load_file(data))
    rescue Tomlrb::ParseError => e
      raise InvalidTemplateError, "failed to parse TOML data file (#{data}): #{e.message}"
    end

    # tomlrb 把 TOML 日期时间解析成自己的 Tomlrb::LocalDate / LocalTime /
    # LocalDateTime,它们不响应 strftime,date formatter 无法处理。
    # 这里统一归一化为 Ruby 的 Date / Time,让 TOML 数据与 Hash 数据行为一致。
    def normalize_dates(value)
      case value
      when Hash then value.transform_values { |v| normalize_dates(v) }
      when Array then value.map { |v| normalize_dates(v) }
      when Tomlrb::LocalDate
        Date.new(value.year, value.month, value.day)
      when Tomlrb::LocalDateTime
        value.to_time
      when Tomlrb::LocalTime
        # 只有时刻没有日期,挂到 1970-01-01(TOML 本地时间的常见处理)
        Time.utc(1970, 1, 1, value.hour, value.min, value.sec)
      else value
      end
    end
  end
end
