# frozen_string_literal: true

module PowerTom
  # 0.9.1:表格区块的两处结构校验修复——列带冲突精确到列(放行静态行固定列合并),
  # 子块路径 relative 禁止再含 [](改写成多级嵌套区块)。
  # 0.9.0:Windows 文件锁修复(rubyzip 句柄泄漏 + Tempfile finalizer 竞态)、
  # check 契约修复(不抛异常,与 render 共享同一套规则集)、
  # ruby_pptx 0.3.1 版本门控;并含 0.8.0 的受限聚合与 AssetResolver
  VERSION = "0.9.1"
end
