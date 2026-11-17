# frozen_string_literal: true

# Binder 纯单元测试:路径取值与标签渲染(§2.2 / §2.3)。不依赖文件 I/O。
RSpec.describe PowerTom::Binder do
  def binder_for(data, strict: true)
    warnings = []
    binder = described_class.new(data, strict: strict, warnings: warnings)
    [binder, warnings]
  end

  ctx = { slide_no: 2, shape: "文本框 5" }

  describe "路径取值" do
    it "支持点路径与数组下标" do
      binder, = binder_for({ kpis: [{ name: "领养率" }] })
      expect(binder.render_label("kpis[0].name", ctx)).to eq("领养率")
    end

    it "Hash 的字符串键与符号键都能取到" do
      binder, = binder_for({ title: "T" })
      expect(binder.render_label("title", ctx)).to eq("T")
      binder2, = binder_for({ "title" => "T2" })
      expect(binder2.render_label("title", ctx)).to eq("T2")
    end
  end

  describe "标量渲染(§2.2)" do
    it "nil 渲染为空字符串" do
      binder, = binder_for({ title: nil })
      expect(binder.render_label("title", ctx)).to eq("")
    end

    it "数字、Symbol、日期时间用 to_s" do
      binder, = binder_for({ count: 86, ratio: 29.7, kind: :vip, day: Date.new(2026, 11, 16) })
      aggregate_failures do
        expect(binder.render_label("count", ctx)).to eq("86")
        expect(binder.render_label("ratio", ctx)).to eq("29.7")
        expect(binder.render_label("kind", ctx)).to eq("vip")
        expect(binder.render_label("day", ctx)).to eq("2026-11-16")
      end
    end

    it "Hash/Array 取到后渲染为文本是错误" do
      binder, = binder_for({ kpis: [{ name: "x" }] })
      expect { binder.render_label("kpis", ctx) }
        .to raise_error(PowerTom::Error, /only renders scalars as text/)
    end
  end

  describe "错误模型(§2.3)" do
    it "strict 下缺失字段抛 MissingDataError,信息含页码、形状、标签" do
      binder, = binder_for({})
      expect { binder.render_label("workload", ctx) }
        .to raise_error(PowerTom::MissingDataError, /slide 2 shape '文本框 5'.*workload/)
    end

    it "strict 下数组下标越界报错" do
      binder, = binder_for({ kpis: [] })
      expect { binder.render_label("kpis[0].name", ctx) }
        .to raise_error(PowerTom::MissingDataError, /index \[0\] is out of bounds/)
    end

    it "strict 下在数组上取字段报错" do
      binder, = binder_for({ items: %w[a b] })
      expect { binder.render_label("items.name", ctx) }
        .to raise_error(PowerTom::MissingDataError, /arrays only support \[index\]/)
    end

    it "strict: false 降级为空字符串并记 warning" do
      binder, warnings = binder_for({}, strict: false)
      expect(binder.render_label("workload", ctx)).to eq("")
      expect(warnings.join).to include("slide 2", "filled with an empty string")
    end

    it "nil 值不是缺失:不报错也不记 warning" do
      binder, warnings = binder_for({ title: nil })
      expect(binder.render_label("title", ctx)).to eq("")
      expect(warnings).to be_empty
    end
  end

  describe "used_root_keys" do
    it "记录引用过的顶层字段" do
      binder, = binder_for({ a: { x: 1 }, b: [2] })
      binder.render_label("a.x", ctx)
      binder.render_label("b[0]", ctx)
      expect(binder.used_root_keys.to_a).to contain_exactly("a", "b")
    end
  end
end
