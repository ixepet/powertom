# frozen_string_literal: true

# 微型 TOML 序列化器(tomlrb 只负责解析,写出侧由 fixture 工具自带)。
# 只需覆盖 manifest 的结构:标量 / 嵌套表 / 表数组 / 内联数组。
module PowerTomDev
  module TomlWriter
    BARE_KEY = /\A[A-Za-z0-9_-]+\z/.freeze

    module_function

    def dump(hash)
      io = StringIO.new
      write_table(io, hash, [])
      io.string
    end

    def write_table(io, table, path)
      scalars = {}
      subtables = {}
      table_arrays = {}
      table.each do |k, v|
        case v
        when Hash then subtables[k] = v
        when Array
          if v.is_a?(Array) && !v.empty? && v.all?(Hash)
            table_arrays[k] = v
          else
            scalars[k] = v
          end
        else
          scalars[k] = v
        end
      end

      scalars.each { |k, v| io << "#{key(k)} = #{value(v)}\n" }
      subtables.each do |k, v|
        io << "\n[#{header(path + [k])}]\n"
        write_table(io, v, path + [k])
      end
      table_arrays.each do |k, entries|
        entries.each do |entry|
          io << "\n[[#{header(path + [k])}]]\n"
          write_table(io, entry, path + [k])
        end
      end
    end

    def header(path)
      path.map { |k| key(k) }.join(".")
    end

    def key(k)
      k = k.to_s
      k.match?(BARE_KEY) ? k : %("#{escape(k)}")
    end

    def value(v)
      case v
      when String then %("#{escape(v)}")
      when Integer, Float then v.to_s
      when true, false then v.to_s
      when nil then raise "TOML 没有 null:manifest 不应含 nil 值"
      when Array then "[" + v.map { |x| value(x) }.join(", ") + "]"
      else raise "TOML writer 不支持 #{v.class}"
      end
    end

    def escape(str)
      str.gsub("\\", "\\\\\\\\")
         .gsub('"', '\\"')
         .gsub("\n", "\\n")
         .gsub("\r", "\\r")
         .gsub("\t", "\\t")
         .gsub("\b", "\\b")
         .gsub("\f", "\\f")
         .gsub(/[\x00-\x1F]/) { |c| format("\\u%04X", c.ord) }
    end
  end
end
