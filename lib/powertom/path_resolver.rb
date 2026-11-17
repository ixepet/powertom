# frozen_string_literal: true

module PowerTom
  # 路径解析(§3.2:点路径与下标)。Binder 与 Validator 共用同一套取值语义,
  # 保证"校验时说的"和"渲染时做的"永远一致。
  #
  # 抛出的 MissingDataError 只含原因短语(如"数据里没有字段 'x'"),
  # 页码/形状/标签等定位信息由调用方补充。
  module PathResolver
    SEGMENT_RE = /\A([A-Za-z0-9_]+)(?:\[(\d+)\])?\z/.freeze

    module_function

    def resolve(data, path)
      current = data
      path.split(".").each do |segment|
        m = segment.match(SEGMENT_RE)
        unless m
          raise MissingDataError,
                "路径段 '#{segment}' 不合法,只支持 字段 与 字段[下标]"
        end
        current = fetch_field(current, m[1], path)
        current = fetch_index(current, m[2]&.to_i, path) if m[2]
      end
      current
    end

    def fetch_field(current, name, path)
      case current
      when Hash
        if current.key?(name)
          current[name]
        elsif current.key?(name.to_sym)
          current[name.to_sym]
        else
          raise MissingDataError, "数据里没有字段 '#{name}'"
        end
      when Array
        raise MissingDataError, "路径 '#{path}' 在数组上取字段 '#{name}',数组只能用 [下标]"
      else
        raise MissingDataError, "路径 '#{path}' 在标量 #{current.class} 上继续取字段 '#{name}'"
      end
    end

    def fetch_index(current, index, path)
      unless current.is_a?(Array) && index < current.size
        raise MissingDataError, "下标 [#{index}] 越界或不在数组上"
      end
      current[index]
    end
  end
end
