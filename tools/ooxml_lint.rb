# frozen_string_literal: true

# L1 structural lint for rendered .pptx packages (external review 2026-11-17,
# P0-1/P2-2): catches the class of defects PowerPoint repairs on open while
# LibreOffice silently tolerates them — dangling [Content_Types].xml
# overrides, dangling relationship targets, duplicate zip entries and
# broken sldId references. Run it on every golden output before release.
#
#   ruby tools/ooxml_lint.rb out1.pptx [out2.pptx ...]
#
# Prints one line per file and exits 1 when any file has findings, so it can
# gate CI. Specs use {PowerTomDev::OoxmlLint.lint} directly (mini golden,
# page surgery, chart binding).
require "rexml/document"
require "zip"

module PowerTomDev
  # OOXML package structure checks. Pure zip/XML inspection, no PowerPoint
  # or LibreOffice involved — cheap enough for every build.
  module OoxmlLint
    module_function

    # @param path [String] a .pptx (OPC package) file.
    # @return [Array<String>] findings; empty means the structure is clean.
    def lint(path)
      errors = []
      Zip::File.open(path) do |zip|
        names = zip.entries.map(&:name).reject { |name| name.end_with?("/") }
        duplicates(names, errors)
        content_type_errors(zip, names, errors)
        relationship_errors(zip, names, errors)
        slide_id_errors(zip, names, errors)
      end
      errors
    end

    def duplicates(names, errors)
      dup = names.tally.select { |_name, count| count > 1 }.keys
      errors << "duplicate zip entries: #{dup.join(', ')}" if dup.any?
    end

    # Every part must be covered by a <Default> (by extension) or an
    # <Override>; every <Override> must point at a part that exists.
    def content_type_errors(zip, names, errors)
      document = REXML::Document.new(zip.get_input_stream("[Content_Types].xml", &:read))
      defaults = {}
      overrides = {}
      REXML::XPath.match(document, "//*[local-name()='Default']").each do |element|
        defaults[element.attributes["Extension"].to_s.downcase] = true
      end
      REXML::XPath.match(document, "//*[local-name()='Override']").each do |element|
        overrides[element.attributes["PartName"].to_s] = true
      end

      # .rels parts are dotfile-named (extname is empty) and always covered by
      # the package-wide "rels" Default; skip them here — dangling targets
      # inside them are checked by relationship_errors below.
      names.each do |name|
        next if name == "[Content_Types].xml" || name.end_with?(".rels")

        ext = File.extname(name).delete(".").downcase
        errors << "undeclared part (no Default or Override): #{name}" unless defaults[ext] || overrides["/#{name}"]
      end
      overrides.each_key do |part_name|
        errors << "Override for missing part: #{part_name}" unless names.include?(part_name.delete_prefix("/"))
      end
    end

    # Every internal relationship target must resolve to an existing part.
    def relationship_errors(zip, names, errors)
      names.grep(/\.rels\z/).each do |rels_name|
        base = rels_name.sub("_rels/", "").sub(/\.rels\z/, "")
        base_dir = File.dirname(base)
        document = REXML::Document.new(zip.get_input_stream(rels_name, &:read))
        REXML::XPath.match(document, "//*[local-name()='Relationship']").each do |rel|
          next if rel.attributes["TargetMode"] == "External"

          target = rel.attributes["Target"].to_s
          resolved = target.start_with?("/") ? target.delete_prefix("/") : resolve(base_dir, target)
          errors << "#{rels_name}: dangling target '#{target}'" unless names.include?(resolved)
        end
      end
    end

    # Package-internal relative path resolution (no filesystem access).
    def resolve(base_dir, target)
      out = []
      (base_dir.split("/") + target.split("/")).each do |segment|
        case segment
        when ".." then out.pop
        when ".", "" then next
        else out << segment
        end
      end
      out.join("/")
    end

    # Every sldId in presentation.xml must have a relationship in the
    # presentation rels.
    def slide_id_errors(zip, names, errors)
      return unless names.include?("ppt/presentation.xml") &&
                    names.include?("ppt/_rels/presentation.xml.rels")

      presentation = REXML::Document.new(zip.get_input_stream("ppt/presentation.xml", &:read))
      rels = REXML::Document.new(zip.get_input_stream("ppt/_rels/presentation.xml.rels", &:read))
      rids = REXML::XPath.match(rels, "//*[local-name()='Relationship']")
                         .filter_map { |rel| rel.attributes["Id"] }.to_set
      REXML::XPath.match(presentation, "//*[local-name()='sldId']").each do |sld_id|
        rid = sld_id.attributes.get_attribute("r:id")&.value
        errors << "sldId r:id '#{rid}' missing from presentation rels" if rid && !rids.include?(rid)
      end
    end
  end
end

if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  failed = false
  ARGV.each do |file|
    findings = PowerTomDev::OoxmlLint.lint(file)
    failed ||= !findings.empty?
    puts "#{File.basename(file)}: #{findings.empty? ? 'structure OK' : findings.join(' | ')}"
  end
  exit(failed ? 1 : 0)
end
