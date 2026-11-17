# frozen_string_literal: true

require_relative "path_resolver"

module PowerTom
  # #grid 动态列的取值语义(Binder 与 Validator 共用,保证校验与渲染一致)。
  #
  # 列项:Hash 取 key 字段作为列键;标量列直接作为列键。
  # 交叉值:有 value 参数时取 row[value][col_key],否则取 row[col_key]。
  module GridValue
    module_function

    def column_key(col)
      return col unless col.is_a?(Hash)

      key = col.key?(:key) ? col[:key] : col["key"]
      raise MissingDataError, "missing 'key' field" if key.nil?

      key
    end

    # 列带里第 template_index 个模板列对应的取值字段:
    #   未声明 value → nil(row[col.key])
    #   声明 1 个   → 所有模板列共用
    #   声明多个     → 与模板列一一对应(数量由 TableLoop 校验)
    def band_value_path(value_paths, template_index)
      return nil if value_paths.nil? || value_paths.empty?

      value_paths.size == 1 ? value_paths.first : value_paths[template_index]
    end

    # 列条件取值:优先当前列项,缺失时回退整页数据(支持 subjects[].show 完整路径)
    def column_condition_value(path, col, band_path, data)
      relative = path.start_with?("#{band_path}[].") ? path.delete_prefix("#{band_path}[].") : path
      begin
        PathResolver.resolve(col, relative)
      rescue MissingDataError
        PathResolver.resolve(data, relative)
      end
    end

    def cell_value(row, col, value_path)
      key = column_key(col)
      container = value_path ? PathResolver.resolve(row, value_path) : row
      unless container.is_a?(Hash)
        label = value_path ? "row field '#{value_path}'" : "row data"
        raise MissingDataError, "#{label} must be a Hash, got #{container.class}"
      end

      fetch(container, key)
    end

    def fetch(container, key)
      return container[key] if container.key?(key)

      name = key.to_s
      return container[name] if container.key?(name)
      return container[name.to_sym] if container.key?(name.to_sym)

      raise MissingDataError, "data has no field '#{name}'"
    end
  end
end
