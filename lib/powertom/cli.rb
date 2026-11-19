# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../powertom"

module PowerTom
  # 命令行入口(v0.6.0 只读 check;0.7.0 增加 render)。
  # 退出码是唯一稳定契约:0 成功,1 模板/数据导致渲染失败,2 用法或输入错误。
  class CLI
    # 输入不可读/格式不支持 → 退出码 2
    class InputError < StandardError; end

    USAGE = <<~TEXT
      Usage:
        powertom check TEMPLATE [--data PATH]
        powertom render TEMPLATE --out PATH [--data PATH] [--no-strict]
        powertom version
        powertom help

      Exit codes:
        0  success (warnings allowed)
        1  template/data errors that block rendering
        2  usage error, unreadable template, data or asset
    TEXT

    def self.run(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv)
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    def run(argv)
      command = argv.first
      case command
      when "check" then check(argv.drop(1))
      when "render" then render(argv.drop(1))
      when "version", "--version", "-v" then version
      when "help", "--help", "-h" then help
      when nil then usage_error("missing command")
      else usage_error("unknown command: #{command}")
      end
    end

    private

    def version
      @out.puts "powertom #{PowerTom::VERSION}"
      0
    end

    def help
      @out.puts USAGE
      0
    end

    def check(args)
      options = { data: nil }
      parser = OptionParser.new do |o|
        o.banner = "Usage: powertom check TEMPLATE [--data PATH]"
        o.on("-d", "--data PATH", "sample data (.toml or .json)") { |path| options[:data] = path }
        o.on("-h", "--help") do
          @out.puts o
          return 0
        end
      end
      rest = parser.parse(args)

      if rest.empty?
        @err.puts "powertom: missing TEMPLATE"
        @err.puts parser
        return 2
      end
      if rest.size > 1
        @err.puts "powertom: unexpected arguments: #{rest.drop(1).join(' ')}"
        return 2
      end

      data = options[:data] ? load_data(options[:data]) : nil
      result = PowerTom.check(rest.first, data: data)
      @out.puts result.report
      result.exit_code
    rescue OptionParser::ParseError => e
      @err.puts "powertom: #{e.message}"
      @err.puts parser
      2
    rescue PowerTom::Error => e
      @err.puts "powertom: #{e.message}"
      2
    rescue StandardError => e
      # check 的契约是"报告问题而不抛异常";若检查器自身崩了,也不能把
      # Ruby 栈回溯甩给 CI 用户。退出码 2 = 用法/输入错误(工具故障)。
      @err.puts "powertom: internal check error: #{e.class}: #{e.message}"
      2
    end

    def render(args)
      options = { data: nil, out: nil, strict: true }
      parser = OptionParser.new do |o|
        o.banner = "Usage: powertom render TEMPLATE --out PATH [--data PATH] [--no-strict]"
        o.on("-d", "--data PATH", "data file (.toml or .json)") { |path| options[:data] = path }
        o.on("-o", "--out PATH", "output .pptx path") { |path| options[:out] = path }
        o.on("--no-strict", "fill missing fields with blanks and warn") { options[:strict] = false }
        o.on("-h", "--help") do
          @out.puts o
          return 0
        end
      end
      rest = parser.parse(args)

      if rest.empty?
        @err.puts "powertom: missing TEMPLATE"
        @err.puts parser
        return 2
      end
      if rest.size > 1
        @err.puts "powertom: unexpected arguments: #{rest.drop(1).join(' ')}"
        return 2
      end
      if options[:out].nil? || options[:out].empty?
        @err.puts "powertom: missing --out PATH"
        @err.puts parser
        return 2
      end

      result = PowerTom.render(
        rest.first,
        data: load_data(options[:data]) || {},
        strict: options[:strict]
      )
      result.save(options[:out])
      result.warnings.each { |warning| @err.puts "warning: #{warning}" }
      @out.puts "wrote #{options[:out]}"
      0
    rescue OptionParser::ParseError => e
      @err.puts "powertom: #{e.message}"
      @err.puts parser
      2
    rescue InputError => e
      @err.puts "powertom: #{e.message}"
      2
    rescue PowerTom::Error => e
      @err.puts "powertom: #{e.message}"
      1
    end

    # TOML 交给库的默认 loader;JSON 在 CLI 层解析成 Hash 后传入,
    # 保持库本身"Hash 或 TOML 路径"的契约不变
    def load_data(path)
      return nil if path.nil? || path.empty?
      raise InputError, "data file not found: #{path}" unless File.file?(path)

      case File.extname(path).downcase
      when ".toml" then path
      when ".json" then JSON.parse(File.read(path))
      else
        raise InputError,
              "unsupported data file #{path}: use .toml or .json " \
              "(for other formats pass a parsed Hash in Ruby)"
      end
    rescue JSON::ParserError => e
      raise InputError, "failed to parse JSON data file #{path}: #{e.message}"
    rescue SystemCallError => e
      raise InputError, "cannot read data file #{path}: #{e.message}"
    end

    def usage_error(message)
      @err.puts "powertom: #{message}"
      @err.puts USAGE
      2
    end
  end
end
