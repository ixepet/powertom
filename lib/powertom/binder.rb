# frozen_string_literal: true

require "date"
require_relative "path_resolver"
require_relative "formatter"

module PowerTom
  # 路径取值与标签渲染(§2.2 数据模型约定)。纯 Ruby,不碰 XML。
  # 取值语义统一走 PathResolver(与 Validator 对账共享)。
  #
  # - String / 数字 / Symbol / Date / Time 用 to_s
  # - nil → 空字符串
  # - Hash / Array 渲染为文本 = 错误(路径镜像了数据结构,取值应取到标量)
  class Binder
    attr_reader :used_root_keys

    def initialize(data, strict:, warnings:)
      @data = data
      @strict = strict
      @warnings = warnings
      @used_root_keys = Set.new
    end

    # 渲染一个标签路径。缺失字段:strict 抛 MissingDataError;否则填空并记 warning(§2.3)
    #
    # context 可携带作用域(§3.3 #each 页内标签取每次迭代的作用域):
    #   scope:      本次迭代的数据项(Hash);nil → 用根数据
    #   scope_root: #each 的根路径字段名,用于未使用字段统计
    # spec:formatter 规格(§3.4),如 "currency" / "percent.1";nil → 不格式化
    def render_label(path, context, spec: nil)
      record_root(path, context)
      value = resolve_label(path, context)
      # §2.2:nil 渲染为空字符串,formatter 不参与(避免 currency 之类的报错)
      return "" if value.nil?
      return Formatter.apply(value, spec) if spec

      to_text(value, path)
    rescue MissingDataError => e
      raise if @strict

      @warnings << "#{e.message}, filled with an empty string"
      ""
    end

    # 取原始值(不转文本),供 #each(要数组)/ #if(要真假)/ 图片字段(要路径)使用。
    # 遵循 strict 配置:strict 且缺失 → MissingDataError;非 strict → nil + warning。
    # 作用域语义与 render_label 一致(#each 页取迭代项);purpose 仅用于 warning 语境
    def value_at(path, context, purpose: "page directive")
      record_root(path, context)
      begin
        PathResolver.resolve(context[:scope] || @data, path)
      rescue MissingDataError => e
        raise MissingDataError, "slide #{context[:slide_no]}: {{#{path}}} #{e.message}"
      end
    rescue MissingDataError => e
      raise if @strict

      @warnings << "#{e.message} (#{purpose})"
      nil
    end

    private

    def record_root(path, context)
      return if (context[:grid_scope] || context[:row_item]) && grid_variable?(path)

      if context[:scope]
        @used_root_keys << context[:scope_root].to_s if context[:scope_root]
      else
        root_key = path.split(".").first[/\A[A-Za-z0-9_]+/]
        @used_root_keys << root_key if root_key
      end
    end

    # #grid 作用域变量:row.* / col.* / cell(不是顶层数据字段)
    def grid_variable?(path)
      path == "cell" || path == "row" || path.start_with?("row.") ||
        path == "col" || path.start_with?("col.")
    end

    def resolve(path, context)
      PathResolver.resolve(context[:scope] || @data, path)
    rescue MissingDataError => e
      raise MissingDataError, "#{describe(context)}:{{#{path}}} #{e.message}"
    end

    # 表格行标签:{{数组[].字段}} / {{父数组[].子数组[].字段}} 相对当前行作用域取值。
    # row_scopes: {"groups[]" => 父项, "groups[].items[]" => 子项}(当前行已展开的层级)
    # #grid 作用域另见 resolve_grid_label({{row.x}} / {{col.y}} / {{cell}})。
    def resolve_label(path, context)
      return resolve_grid_label(path, context) if context[:grid_scope]
      return resolve_row_item_label(path, context) if context[:row_item] && (path == "row" || path.start_with?("row."))
      return resolve(path, context) unless path.include?("[]")

      resolve_row_label(path, context)
    end

    # 行区块里的 {{row.*}}:指向当前记录的字段
    def resolve_row_item_label(path, context)
      item = context[:row_item]
      return item if path == "row"

      resolve_grid_item(item, path.delete_prefix("row."), path, context)
    end

    # #grid 单元格作用域:col(Hash/标量)、row(行数据)、cell(行列交叉值)
    def resolve_grid_label(path, context)
      scope = context[:grid_scope]
      return fetch_cell(scope, context) if path == "cell"

      if path == "row" || path.start_with?("row.")
        item = require_grid_scope!(scope, :row, path)
        return item if path == "row"

        return resolve_grid_item(item, path.delete_prefix("row."), path, context)
      end
      if path == "col" || path.start_with?("col.")
        item = require_grid_scope!(scope, :col, path)
        return item if path == "col"

        return resolve_grid_item(item, path.delete_prefix("col."), path, context)
      end

      resolve(path, context) # 其他标签仍从整页数据取(如静态合计)
    end

    def fetch_cell(scope, context)
      resolver = scope[:cell]
      unless resolver
        raise PowerTom::Error,
              "{{cell}} can only be used in data columns of a #grid content row " \
              "(both row and column data are required)"
      end
      begin
        resolver.call
      rescue MissingDataError => e
        raise MissingDataError, "#{describe(context)}:{{cell}} #{e.message}"
      end
    end

    def require_grid_scope!(scope, key, path)
      value = scope[key]
      return value unless value.nil?

      where = key == :row ? "a #grid content row" : "a #grid data column (outside the first column)"
      raise PowerTom::Error, "{{#{path}}} can only be used in #{where}"
    end

    def resolve_grid_item(item, remainder, path, context)
      PathResolver.resolve(item, remainder)
    rescue MissingDataError => e
      raise MissingDataError, "#{describe(context)}:{{#{path}}} #{e.message}"
    end

    def resolve_row_label(path, context)
      scopes = context[:row_scopes]
      if scopes.nil? || scopes.empty?
        raise PowerTom::Error,
              "table row tag {{#{path}}} is not inside an expanded loop row: " \
              "put the tag in a template row marked with []"
      end

      prefix = scopes.keys.select { |item| path == item || path.start_with?("#{item}.") }
                     .max_by(&:length)
      unless prefix
        expected = scopes.keys.map { |item| "{{#{item}.field}}" }.join(", ")
        raise PowerTom::Error,
              "table row tag {{#{path}}} does not match the loop array (current row scopes: #{expected})"
      end

      remainder = path.delete_prefix(prefix).delete_prefix(".")
      if remainder.include?("[]")
        raise PowerTom::Error,
              "table row tag {{#{path}}} references a child array that was not expanded " \
              "(this row expands only to #{prefix}; two levels maximum)"
      end
      item = scopes[prefix]
      return item if remainder.empty?

      begin
        PathResolver.resolve(item, remainder)
      rescue MissingDataError => e
        raise MissingDataError, "#{describe(context)}:{{#{path}}} #{e.message}"
      end
    end

    def describe(context)
      "slide #{context[:slide_no]} shape '#{context[:shape]}'"
    end

    def to_text(value, path)
      case value
      when nil then ""
      when String, Numeric, Symbol, Date, Time, DateTime, true, false then value.to_s
      else
        raise PowerTom::Error,
              "{{#{path}}} resolved to #{value.class}; v0 only renders scalars as text. " \
              "Use page cloning for arrays"
      end
    end
  end
end
