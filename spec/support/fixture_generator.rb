# frozen_string_literal: true

# PowerTom 金样本生成器(纯 Ruby)。
#
# 输入:设计师维护的原始模板 pptx(通常体积巨大,如 HaiMate 126MB)
# 输出:spec/fixtures/<name>/ 下的两个文件
#   - template.pptx   瘦身后的模板副本(剥嵌入字体、PNG/GIF 媒体换 1x1 占位图)
#   - manifest.toml   模板结构快照(进 git,作为回归断言基准;TOML 是默认数据格式)
#
# 瘦身保证:只动媒体字节与字体部件,不碰任何 slide XML;
#           生成后做剥离自检 —— 原文件与产物的 text_digest 必须逐字节相等。
#           manifest 另做 TOML round-trip 自检:dump 后经 tomlrb 解析必须与源 Hash 相等。
#
# 用法(rake 或独立运行,无需 bundler):
#   rake fixtures:generate TEMPLATE=/path/to/x.pptx [OUT=spec/fixtures/hai_mate]
#   ruby spec/support/fixture_generator.rb /path/to/x.pptx -o spec/fixtures/hai_mate [--keep-fonts] [--keep-media]

require "fileutils"
require "digest"
require "tomlrb"
require "zlib"
require "zip"
require_relative "anatomy"
require_relative "toml_writer"

module PowerTomDev
  module FixtureGenerator
    module_function

    # 经典 1x1 透明 GIF
    TINY_GIF = ["R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"].pack("m").freeze

    def generate(pptx_path:, out_dir:, strip_fonts: true, strip_media: true, source_name: nil)
      raise ArgumentError, "模板不存在: #{pptx_path}" unless File.file?(pptx_path)

      source_name ||= File.basename(pptx_path)
      FileUtils.mkdir_p(out_dir)
      out_template = File.join(out_dir, "template.pptx")

      strip_report = write_stripped(pptx_path, out_template,
                                    strip_fonts: strip_fonts, strip_media: strip_media)

      # 剥离自检:瘦身不得改变任何文本结构
      src_digest = Anatomy.text_digest(Anatomy.analyze(pptx_path))
      out_digest = Anatomy.text_digest(Anatomy.analyze(out_template))
      raise "剥离自检失败:剥离前后文本结构不一致,禁止使用该产物" unless src_digest == out_digest

      manifest = Anatomy.manifest(Anatomy.analyze(out_template),
                                  source_name: source_name, generated_at: Time.now.to_s)
      manifest["derived"] = {
        "stripped" => strip_report[:stripped],
        "media_replaced" => strip_report[:media_replaced],
        "fonts_removed" => strip_report[:fonts_removed],
        "bytes_source" => File.size(pptx_path),
        "bytes_fixture" => File.size(out_template),
        "source_sha256" => Digest::SHA256.file(pptx_path).hexdigest
      }
      manifest_toml = PowerTomDev::TomlWriter.dump(manifest)
      # round-trip 自检:TOML 解析回来必须与源 Hash 相等
      parsed = Tomlrb.parse(manifest_toml)
      raise "manifest TOML round-trip 失败:dump/parse 不一致" unless parsed == manifest

      File.write(File.join(out_dir, "manifest.toml"), manifest_toml)

      strip_report.merge(bytes_source: File.size(pptx_path), bytes_fixture: File.size(out_template))
    end

    # ---- zip 手术 ----

    def write_stripped(src, dst, strip_fonts:, strip_media:)
      stripped = []
      media_replaced = 0
      fonts_removed = 0
      tmp = "#{dst}.tmp"

      Zip::File.open(src) do |zin|
        Zip::OutputStream.open(tmp) do |zos|
          zin.entries.each do |entry|
            next if entry.directory?

            name = entry.name

            if strip_fonts && name.start_with?("ppt/fonts/")
              fonts_removed += 1
              stripped << "fonts"
              next
            end

            data = entry.get_input_stream(&:read)

            if strip_media && name.start_with?("ppt/media/")
              ext = name.downcase[/\.[^.]+\z/].to_s
              if ext == ".png"
                data = tiny_png
                media_replaced += 1
                stripped << "media"
              elsif ext == ".gif"
                data = TINY_GIF
                media_replaced += 1
                stripped << "media"
              end
              # jpeg / svg 等其他媒体原样保留
            end

            # 剥字体后的 XML 修复(正则做定点删除,避免 REXML 重序列化改变其余字节)
            if strip_fonts
              case name
              when "ppt/presentation.xml"
                data = fix_presentation_xml(data)
              when "ppt/_rels/presentation.xml.rels"
                data = fix_presentation_rels(data)
              when "[Content_Types].xml"
                data = fix_content_types(data)
              end
            end

            zos.put_next_entry(name)
            zos.write(data)
          end
        end
      end

      File.rename(tmp, dst)
      { stripped: stripped.uniq, media_replaced: media_replaced, fonts_removed: fonts_removed }
    end

    # 程序化构造合法 1x1 RGB PNG(不走 base64 常量,保证字节有效)
    def tiny_png(rgb = [255, 255, 255])
      signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C8")
      chunk = lambda do |type, payload|
        [payload.bytesize].pack("N") + type + payload + [Zlib.crc32(type + payload)].pack("N")
      end
      ihdr = [1, 1, 8, 2, 0, 0, 0].pack("NNCCCCC")
      idat = Zlib::Deflate.deflate([0, rgb[0], rgb[1], rgb[2]].pack("C4"))
      signature + chunk.call("IHDR", ihdr) + chunk.call("IDAT", idat) + chunk.call("IEND", "")
    end

    # presentation.xml:删除 embeddedFontLst 块与 embedTrueTypeFonts 属性
    def fix_presentation_xml(data)
      xml = data.dup.force_encoding(Encoding::UTF_8)
      xml = xml.sub(%r{<p:embeddedFontLst>.*?</p:embeddedFontLst>}m, "")
      xml = xml.sub(/\s+embedTrueTypeFonts="[^"]*"/, "")
      xml.force_encoding(Encoding::BINARY)
    end

    # presentation.xml.rels:删除指向 fonts/ 的关系
    def fix_presentation_rels(data)
      xml = data.dup.force_encoding(Encoding::UTF_8)
      xml = xml.gsub(%r{<Relationship\b[^>]*Target="fonts/[^"]*"[^>]*/>}, "")
      xml.force_encoding(Encoding::BINARY)
    end

    # [Content_Types].xml:删除 fntdata 类型声明(OOXML 嵌入字体固定扩展名)
    def fix_content_types(data)
      xml = data.dup.force_encoding(Encoding::UTF_8)
      xml = xml.sub(%r{<Default [^>]*Extension="fntdata"[^>]*/>}, "")
      xml.force_encoding(Encoding::BINARY)
    end

    # ---- 独立 CLI ----

    def cli(argv)
      require "optparse"
      options = { out: "spec/fixtures/hai_mate", strip_fonts: true, strip_media: true }
      parser = OptionParser.new do |o|
        o.banner = "用法: ruby #{File.basename($PROGRAM_NAME)} <template.pptx> [选项]"
        o.on("-o DIR", "--out DIR", "输出目录(默认 #{options[:out]})") { |v| options[:out] = v }
        o.on("--keep-fonts", "保留嵌入字体(默认剥离)") { options[:strip_fonts] = false }
        o.on("--keep-media", "保留 PNG/GIF 媒体(默认替换为占位图)") { options[:strip_media] = false }
      end
      parser.parse!(argv)
      raise OptionParser::MissingArgument, "缺少模板 pptx 路径" if argv.empty?

      report = generate(pptx_path: argv[0], out_dir: options[:out],
                        strip_fonts: options[:strip_fonts], strip_media: options[:strip_media])
      puts "生成完成: #{File.join(options[:out], 'template.pptx')} + manifest.toml"
      puts "  剥离: #{report[:stripped].join(', ').empty? ? '无' : report[:stripped].join(', ')} " \
           "| 媒体替换 #{report[:media_replaced]} 个 | 字体移除 #{report[:fonts_removed]} 个"
      puts format("  体积: %.1fMB -> %.1fMB",
                  report[:bytes_source] / 1024.0 / 1024, report[:bytes_fixture] / 1024.0 / 1024)
      report
    end

    cli(ARGV) if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  end
end
