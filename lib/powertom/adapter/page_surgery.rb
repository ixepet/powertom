# frozen_string_literal: true

require "rexml/document"
require "zip"

module PowerTom
  module Adapter
    # 页面手术:按计划克隆/删除整页(§5.2)。
    #
    # ruby_pptx 0.2.0 尚无 duplicate / delete(Slides 只有 add / add_table_pages,
    # 设计文档 §5.2 已核对),本类在适配层内基于 OOXML 包结构直接完成,
    # XML 操作不外泄出适配层;待上游补齐能力后应收缩为对 ruby_pptx 的调用。
    #
    # 策略:输出页按顺序整体重新编号(slide1..slideM / notesSlide1..M),
    # 彻底规避上游 next_slide_partname 以 sldIdLst.size+1 命名的撞名问题。
    # 媒体 / 布局 / 母版 / tags 等部件被多个页面共享引用,无需复制。
    class PageSurgery
      SLIDE_CT = "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"
      NOTES_CT = "application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"

      # plan: [{source: 原页号, iteration: nil|k}] 按输出顺序(克隆页连续出现)。
      # 返回 [{source:, iteration:}](与输出页一一对应,供渲染阶段做作用域绑定)。
      def self.execute(template_path, out_path, plan)
        new(template_path, out_path, plan).run
      end

      def initialize(template_path, out_path, plan)
        @template_path = template_path
        @out_path = out_path
        @plan = plan
      end

      def run
        parts = read_parts
        order = slide_partnames_in_order(parts)

        # 输出映射:每个输出页对应哪张原始页(含其 notes 部件)
        outputs = @plan.map do |p|
          src = order[p[:source] - 1]
          raise Error, "页码越界:#{p[:source]}(共 #{order.size} 页)" unless src
          { src_slide: src, src_notes: notes_part_for(parts, p[:source]) }
        end

        rewritten = build_rewritten_parts(parts, outputs)
        write_zip(parts, rewritten)

        @plan.map { |p| { source: p[:source], iteration: p[:iteration] } }
      end

      private

      def slide_name(index) = "slide#{index + 1}.xml"

      def notes_name(index) = "notesSlide#{index + 1}.xml"

      # ---- 读取 ----

      def read_parts
        parts = {}
        Zip::File.open(@template_path) do |zip|
          zip.entries.each do |entry|
            next if entry.directory?
            parts[entry.name] = entry.get_input_stream.read
          end
        end
        parts
      end

      def slide_partnames_in_order(parts)
        pres = REXML::Document.new(parts.fetch("ppt/presentation.xml"))
        rels = REXML::Document.new(parts.fetch("ppt/_rels/presentation.xml.rels"))
        rid_target = {}
        REXML::XPath.match(rels, "//Relationship").each do |rel|
          target = rel.attributes["Target"].to_s
          rid_target[rel.attributes["Id"]] = target if target.match?(%r{\Aslides/slide\d+\.xml\z})
        end
        REXML::XPath.match(pres, "//p:sldIdLst/p:sldId").map do |sld_id|
          rid_attr = sld_id.attributes.get_attribute("r:id")
          target = rid_target[rid_attr&.value]
          raise Error, "presentation.xml 的 sldId 引用了未知关系" unless target
          "ppt/#{target}"
        end
      end

      def notes_part_for(parts, old_slide_no)
        rels_name = "ppt/slides/_rels/slide#{old_slide_no}.xml.rels"
        return nil unless parts[rels_name]
        rel = REXML::XPath.match(REXML::Document.new(parts[rels_name]), "//Relationship").find do |r|
          r.attributes["Type"].to_s.end_with?("/notesSlide")
        end
        return nil unless rel
        "ppt/notesSlides/#{File.basename(rel.attributes['Target'])}"
      end

      # ---- 重写 ----

      def build_rewritten_parts(parts, outputs)
        count = outputs.size
        new_rids = allocate_slide_rids(parts, count)

        slide_parts = outputs.each_with_index.flat_map do |out, i|
          {
            "ppt/slides/#{slide_name(i)}" => parts.fetch(out[:src_slide]),
            "ppt/slides/_rels/#{slide_name(i)}.rels" =>
              rewrite_slide_rels(parts, out[:src_slide], out[:src_notes] ? notes_name(i) : nil)
          }
        end

        notes_parts = outputs.each_with_index.filter_map do |out, i|
          next nil unless out[:src_notes]
          {
            "ppt/notesSlides/#{notes_name(i)}" => parts.fetch(out[:src_notes]),
            "ppt/notesSlides/_rels/#{notes_name(i)}.rels" =>
              rewrite_notes_rels(parts, out[:src_notes], slide_name(i))
          }
        end

        {
          "ppt/presentation.xml" => rewrite_presentation(parts, count, new_rids),
          "ppt/_rels/presentation.xml.rels" => rewrite_presentation_rels(parts, count, new_rids),
          "[Content_Types].xml" => rewrite_content_types(parts, count),
          "slide_parts" => slide_parts,
          "notes_parts" => notes_parts
        }
      end

      # presentation.xml.rels 里非 slide 关系保留原 rId,新 slide 关系从 max+1 起分配
      def allocate_slide_rids(parts, count)
        rels = REXML::Document.new(parts.fetch("ppt/_rels/presentation.xml.rels"))
        max = REXML::XPath.match(rels, "//Relationship")
              .filter_map { |r| r.attributes["Id"].to_s[/\ArId(\d+)\z/, 1] }
              .map(&:to_i).max || 0
        (1..count).map { |i| "rId#{max + i}" }
      end

      def rewrite_presentation(parts, count, new_rids)
        xml = parts.fetch("ppt/presentation.xml").dup.force_encoding(Encoding::UTF_8)
        entries = (0...count).map { |i| %(<p:sldId id="#{256 + i}" r:id="#{new_rids[i]}"/>) }.join
        unless xml.sub!(%r{<p:sldIdLst>.*?</p:sldIdLst>}m, "<p:sldIdLst>#{entries}</p:sldIdLst>")
          raise Error, "presentation.xml 中未找到 sldIdLst"
        end
        xml.force_encoding(Encoding::BINARY)
      end

      def rewrite_presentation_rels(parts, count, new_rids)
        xml = parts.fetch("ppt/_rels/presentation.xml.rels").dup.force_encoding(Encoding::UTF_8)
        xml = xml.gsub(%r{<Relationship\b[^>]*Target="slides/slide\d+\.xml"[^>]*/>}, "")
        new_rels = (0...count).map do |i|
          %(<Relationship Id="#{new_rids[i]}" ) +
            %(Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" ) +
            %(Target="slides/#{slide_name(i)}"/>)
        end
        xml.sub!(%r{</Relationships>}, "#{new_rels.join}</Relationships>")
        xml.force_encoding(Encoding::BINARY)
      end

      def rewrite_content_types(parts, count)
        xml = parts.fetch("[Content_Types].xml").dup.force_encoding(Encoding::UTF_8)
        xml = xml.gsub(%r{<Override [^>]*PartName="/ppt/slides/slide\d+\.xml"[^>]*/>}, "")
        xml = xml.gsub(%r{<Override [^>]*PartName="/ppt/notesSlides/notesSlide\d+\.xml"[^>]*/>}, "")
        overrides = (0...count).flat_map do |i|
          [%(<Override PartName="/ppt/slides/slide#{i + 1}.xml" ContentType="#{SLIDE_CT}"/>),
           %(<Override PartName="/ppt/notesSlides/notesSlide#{i + 1}.xml" ContentType="#{NOTES_CT}"/>)]
        end
        xml.sub!(%r{</Types>}, "#{overrides.join}</Types>")
        xml.force_encoding(Encoding::BINARY)
      end

      # slide rels:notesSlide 指向重编号后的新 notesSlide;其余(媒体/布局/tags)原样共享
      def rewrite_slide_rels(parts, src_slide_part, new_notes_name)
        rels_name = "ppt/slides/_rels/#{File.basename(src_slide_part)}.rels"
        xml = parts.fetch(rels_name).dup.force_encoding(Encoding::UTF_8)
        if new_notes_name
          xml = xml.gsub(%r{Target="\.\./notesSlides/notesSlide\d+\.xml"},
                         %(Target="../notesSlides/#{new_notes_name}"))
        end
        xml.force_encoding(Encoding::BINARY)
      end

      def rewrite_notes_rels(parts, src_notes_part, new_slide_name)
        rels_name = "ppt/notesSlides/_rels/#{File.basename(src_notes_part)}.rels"
        xml = parts.fetch(rels_name).dup.force_encoding(Encoding::UTF_8)
        xml = xml.gsub(%r{Target="\.\./slides/slide\d+\.xml"}, %(Target="../slides/#{new_slide_name}"))
        xml.force_encoding(Encoding::BINARY)
      end

      # ---- 写出 ----

      # 这些部件不照抄:重编号后的 slides/notesSlides、重写后的 presentation 层
      SKIP_PATTERNS = [
        %r{\Appt/slides/slide\d+\.xml\z},
        %r{\Appt/slides/_rels/slide\d+\.xml\.rels\z},
        %r{\Appt/notesSlides/notesSlide\d+\.xml\z},
        %r{\Appt/notesSlides/_rels/notesSlide\d+\.xml\.rels\z},
        %r{\Appt/presentation\.xml\z},
        %r{\Appt/_rels/presentation\.xml\.rels\z}
      ].freeze

      def write_zip(parts, rewritten)
        Zip::OutputStream.open(@out_path) do |zos|
          zos.put_next_entry("[Content_Types].xml")
          zos.write(rewritten.fetch("[Content_Types].xml"))

          parts.each do |name, data|
            next if name == "[Content_Types].xml"
            next if SKIP_PATTERNS.any? { |re| name.match?(re) }
            zos.put_next_entry(name)
            zos.write(data)
          end

          { "ppt/presentation.xml" => "ppt/presentation.xml",
            "ppt/_rels/presentation.xml.rels" => "ppt/_rels/presentation.xml.rels" }.each do |key, name|
            zos.put_next_entry(name)
            zos.write(rewritten.fetch(key))
          end

          %w[slide_parts notes_parts].each do |group|
            rewritten.fetch(group).each do |entries|
              entries.each do |name, data|
                zos.put_next_entry(name)
                zos.write(data)
              end
            end
          end
        end
      end
    end
  end
end
