# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "zip"

# PageSurgery 直接契约:页号越界保护 + 输出 zip entry 名安全(zip-slip 防护)。
RSpec.describe PowerTom::Adapter::PageSurgery do
  around do |example|
    Dir.mktmpdir("page_surgery_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def one_page_template(text = "hello")
    prs = Pptx::Presentation.new_default
    slide = prs.slides.add(prs.slide_layouts["Blank"])
    box = slide.shapes.add_textbox(at: [Pptx.inches(0.5), Pptx.inches(0.5)],
                                   size: [Pptx.inches(4), Pptx.inches(1)])
    box.text_frame.text = text
    path = File.join(@dir, "template_#{SecureRandom.hex(4)}.pptx")
    prs.save(path)
    path
  end

  def out_path
    File.join(@dir, "out_#{SecureRandom.hex(4)}.pptx")
  end

  it "source 越界(0 / 负数 / 超过页数) → 抛带定位的 Error,而不是负下标回绕静默克隆错页" do
    template = one_page_template
    [{ source: 0, iteration: nil }, { source: -1, iteration: nil },
     { source: 2, iteration: nil }, { source: "1", iteration: nil }].each do |page|
      expect { described_class.execute(template, out_path, [page]) }
        .to raise_error(PowerTom::Error, /slide number out of range/)
    end
  end

  it "正常 plan 克隆/删除页不受影响" do
    template = one_page_template
    out = out_path
    result = described_class.execute(template, out, [
                                       { source: 1, iteration: nil },
                                       { source: 1, iteration: 0 },
                                       { source: 1, iteration: 1 }
                                     ])
    expect(result.size).to eq(3)
    prs = Pptx::Presentation.open(out)
    expect(prs.slides.size).to eq(3)
  end

  it "模板 zip 含路径穿越 entry(../) → 拒绝写入,防 zip-slip" do
    template = one_page_template
    evil = File.join(@dir, "evil.pptx")
    Zip::File.open(template) do |zin|
      Zip::OutputStream.open(evil) do |zos|
        zin.entries.each do |entry|
          zos.put_next_entry(entry.name)
          zos.write(zin.read(entry))
        end
        zos.put_next_entry("../evil.txt")
        zos.write("payload")
      end
    end

    expect { described_class.execute(evil, out_path, [{ source: 1, iteration: nil }]) }
      .to raise_error(PowerTom::Error, /unsafe zip entry name/)
  end

  it "模板 zip 含 .. 段 entry(中间穿越) → 同样拒绝" do
    template = one_page_template
    evil = File.join(@dir, "evil_mid.pptx")
    Zip::File.open(template) do |zin|
      Zip::OutputStream.open(evil) do |zos|
        zin.entries.each do |entry|
          zos.put_next_entry(entry.name)
          zos.write(zin.read(entry))
        end
        # rubyzip 自己拒绝以 / 开头的 entry 名,这里测中间 .. 段("a/../../x")
        zos.put_next_entry("ppt/../../evil.xml")
        zos.write("payload")
      end
    end

    expect { described_class.execute(evil, out_path, [{ source: 1, iteration: nil }]) }
      .to raise_error(PowerTom::Error, /unsafe zip entry name/)
  end
end
