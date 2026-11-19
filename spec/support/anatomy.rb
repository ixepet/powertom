# frozen_string_literal: true

# PowerTom 金样本解剖器(纯 Ruby)。
#
# 职责:直接读取 pptx(zip 容器),提取与模板引擎相关的全部结构事实:
#   - 画布尺寸、页数、母版/布局/备注/tags/嵌入字体数量
#   - 逐页:引用布局、备注文本、形状构成、非空段落(含 run 分裂碎片)
#   - 汇总:跨 run 分裂率、run 字体分布(设计文档 §5.1 头号坑的量化证据)
#
# 约束:不依赖任何 XML 库之外的 gem(rexml 为 Ruby 内置,rubyzip 只做容器读取);
#       全部输出为 String key 的 Hash,可无损往返 YAML,供 manifest 断言使用。

require "rexml/document"
require "zip"

module PowerTomDev
  module Anatomy
    NS = {
      "p" => "http://schemas.openxmlformats.org/presentationml/2006/main",
      "a" => "http://schemas.openxmlformats.org/drawingml/2006/main",
      "r" => "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
      "ct" => "http://schemas.openxmlformats.org/package/2006/content-types"
    }.freeze

    RELS_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
    NOTES_REL_SUFFIX = "/notesSlide"
    LAYOUT_REL_SUFFIX = "/slideLayout"

    module_function

    # 读取 pptx,返回结构事实 Hash(全 String key)。
    def analyze(path)
      parts = {}
      Zip::File.open(path) do |zip|
        zip.entries.each do |entry|
          next if entry.directory?
          # 二进制部分(媒体/字体)对文本结构无意义,跳过读取
          next unless entry.name.end_with?(".xml", ".rels")

          parts[entry.name] = zip.get_input_stream(entry.name, &:read)
        end
      end
      analyze_parts(parts)
    end

    # 供剥离自检与回归断言使用的最小可比子集。
    # 关键性质:只含文本结构事实,与媒体字节、嵌入字体无关。
    def text_digest(analysis)
      { "stats" => analysis["stats"], "slides" => analysis["slides"] }
    end

    # 组装 manifest(derived 字段由生成器补充)。
    def manifest(analysis, source_name:, generated_at:)
      {
        "manifest_version" => 1,
        "source" => source_name,
        "generated_at" => generated_at,
        "template" => analysis["template"],
        "stats" => analysis["stats"],
        "slides" => analysis["slides"]
      }
    end

    # ---- 内部实现 ----

    def analyze_parts(parts)
      pres = doc(parts["ppt/presentation.xml"])
      sld_sz = first_el(pres, "//p:sldSz")

      analysis = {}
      analysis["template"] = {
        "slide_count" => match_els(pres, "//p:sldIdLst/p:sldId").size,
        "slide_size_emu" => [sld_sz.attributes["cx"].to_i, sld_sz.attributes["cy"].to_i],
        "notes_slide_count" => count_parts(parts, %r{\Appt/notesSlides/notesSlide\d+\.xml\z}),
        "layout_count" => count_parts(parts, %r{\Appt/slideLayouts/slideLayout\d+\.xml\z}),
        "master_count" => count_parts(parts, %r{\Appt/slideMasters/slideMaster\d+\.xml\z}),
        "embedded_font_count" => count_parts(parts, %r{\Appt/fonts/}),
        "tag_count" => count_parts(parts, %r{\Appt/tags/tag\d+\.xml\z}),
        "layouts_referenced" => []
      }

      slides = parts.keys
                    .filter_map { |n| n.match(%r{\Appt/slides/slide(\d+)\.xml\z}) }
                    .sort_by { |m| m[1].to_i }
                    .map { |m| m[1].to_i }

      font_usage = Hash.new(0)
      slides = slides.map { |i| slide_digest(parts, i, font_usage) }

      analysis["slides"] = slides
      analysis["template"]["layouts_referenced"] = slides.filter_map { |s| s["layout"] }.uniq
      analysis["stats"] = aggregate_stats(slides, font_usage)
      analysis
    end

    def slide_digest(parts, index, font_usage)
      slide_xml = parts["ppt/slides/slide#{index}.xml"]
      rels_xml = parts["ppt/slides/_rels/slide#{index}.xml.rels"]
      rels = rels_xml ? doc(rels_xml) : nil

      digest = { "index" => index, "shape_count" => 0, "pic_count" => 0, "table_count" => 0, "paragraphs" => [] }

      if rels
        layout_rel = rels_els(rels).find do |rel|
          rel.attributes["Type"].to_s.end_with?(LAYOUT_REL_SUFFIX)
        end
        digest["layout"] = File.basename(layout_rel.attributes["Target"]) if layout_rel
      end

      if slide_xml
        d = doc(slide_xml)
        tree = first_el(d, "//p:cSld/p:spTree")
        name_seen = Hash.new(0)
        paragraphs = []
        tables = []

        if tree
          match_els(tree, ".//p:sp | .//p:pic | .//p:graphicFrame | .//p:grpSp").each do |node|
            cnv = first_el(node,
                           "p:nvSpPr/p:cNvPr | p:nvPicPr/p:cNvPr | " \
                           "p:nvGraphicFramePr/p:cNvPr | p:nvGrpSpPr/p:cNvPr")
            next unless cnv

            raw_name = cnv.attributes["name"].to_s
            name_seen[raw_name] += 1
            # 同页同名形状加序号后缀:错误定位模型要求 name + 页内序号(见设计文档 §5)
            shape_label = name_seen[raw_name] == 1 ? raw_name : "#{raw_name}##{name_seen[raw_name]}"

            case node.name
            when "sp"
              digest["shape_count"] += 1
              paragraphs.concat(sp_paragraphs(node, shape_label, font_usage))
            when "pic"
              digest["pic_count"] += 1
            when "graphicFrame"
              tbl = first_el(node, ".//a:tbl")
              tables << table_digest(tbl, shape_label) if tbl
            end
          end
        end

        digest["paragraphs"] = paragraphs
        unless tables.empty?
          digest["table_count"] = tables.size
          digest["tables"] = tables
        end
      end

      notes = notes_text(parts, rels)
      digest["notes"] = notes if notes && !notes.empty?
      digest
    end

    def sp_paragraphs(sp_node, shape_label, font_usage)
      paragraphs = []
      match_els(sp_node, "p:txBody/a:p").each do |pa|
        runs = match_els(pa, "a:r")
        next if runs.empty?

        fragments = runs.map { |rn| run_text(rn) }
        text = fragments.join
        next if text.strip.empty?

        runs.each do |rn|
          next if run_text(rn).strip.empty?

          font_usage[run_font(rn)] += 1
        end
        entry = { "shape" => shape_label, "text" => text }
        if runs.size > 1
          entry["runs"] = runs.size
          entry["fragments"] = fragments
        end
        paragraphs << entry
      end
      paragraphs
    end

    def table_digest(tbl, shape_label)
      rows = match_els(tbl, "a:tr")
      {
        "shape" => shape_label,
        "rows" => rows.size,
        "cols" => match_els(tbl, "a:tblGrid/a:gridCol").size,
        "cells" => rows.map do |tr|
          match_els(tr, "a:tc").map { |tc| match_els(tc, ".//a:t").map { |t| t.text.to_s }.join }
        end
      }
    end

    def notes_text(parts, rels)
      return nil unless rels

      notes_rel = rels_els(rels).find do |rel|
        rel.attributes["Type"].to_s.end_with?(NOTES_REL_SUFFIX)
      end
      return nil unless notes_rel

      name = "ppt/notesSlides/#{File.basename(notes_rel.attributes['Target'])}"
      return nil unless parts[name]

      # a:t 是 a:p 的孙子节点(a:p > a:r > a:t),必须用后代轴 .//a:t
      match_els(doc(parts[name]), "//a:p")
        .map { |pa| match_els(pa, ".//a:t").map { |t| t.text.to_s }.join }
        .reject { |line| line.strip.empty? }
        .join("\n")
    end

    def aggregate_stats(slides, font_usage)
      paragraphs = slides.flat_map { |s| s["paragraphs"] }
      split = paragraphs.select { |p| p["runs"] && p["runs"] > 1 }
      # 段落统计口径:仅形状文本(p:sp 的 txBody);表格段落另行随 fixture 演进补充
      {
        "paragraphs" => paragraphs.size,
        "split_paragraphs" => split.size,
        "split_ratio" => paragraphs.empty? ? 0.0 : (split.size.to_f / paragraphs.size).round(3),
        "run_font_usage" => font_usage
      }
    end

    # ---- REXML 小工具(规避嵌套路径与安全导航下标的坑) ----

    def doc(xml)
      REXML::Document.new(xml)
    end

    def first_el(node, xpath)
      REXML::XPath.first(node, xpath, NS)
    end

    def match_els(node, xpath)
      REXML::XPath.match(node, xpath, NS)
    end

    # rels 文档用默认 xmlns(无前缀),不能带 NS 匹配:
    # 传入命名空间哈希后 REXML 对未加前缀的名字做严格匹配,反而 0 命中
    def rels_els(rels_doc)
      REXML::XPath.match(rels_doc, "//Relationship")
    end

    def first_t(run_node)
      t = run_node.elements["a:t"]
      t&.text.to_s
    end

    def run_text(run_node)
      first_t(run_node)
    end

    # run 显式字体;未指定时归入"(继承主题)"桶
    def run_font(run_node)
      rpr = run_node.elements["a:rPr"]
      return "(继承主题)" unless rpr

      latin = rpr.elements["a:latin"]
      latin ? latin.attributes["typeface"].to_s : "(继承主题)"
    end

    def count_parts(parts, pattern)
      parts.keys.count { |n| n.match?(pattern) }
    end
  end
end
