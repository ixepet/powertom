# frozen_string_literal: true

require "date"

# M4:Formatter(§3.4)。{{path:name}} / {{path:name.arg}},内置四族 + 自定义注册。
RSpec.describe PowerTom::Formatter do
  describe "内置四族" do
    it "currency:千分位 + ¥,默认 2 位小数" do
      aggregate_failures do
        expect(described_class.apply(1_234_567.891, "currency")).to eq("¥1,234,567.89")
        expect(described_class.apply(42, "currency")).to eq("¥42.00")
        expect(described_class.apply(-1200.5, "currency")).to eq("¥-1,200.50")
        expect(described_class.apply(1234.6, "currency.0")).to eq("¥1,235")
      end
    end

    it "percent:比例 ×100,参数控制小数位" do
      aggregate_failures do
        expect(described_class.apply(0.297, "percent.1")).to eq("29.7%")
        expect(described_class.apply(0.297, "percent")).to eq("30%")
        expect(described_class.apply(0.5, "percent")).to eq("50%")
      end
    end

    it "number:千分位,参数控制小数位" do
      aggregate_failures do
        expect(described_class.apply(12_345, "number")).to eq("12,345")
        expect(described_class.apply(12_345.678, "number.2")).to eq("12,345.68")
      end
    end

    it "date:默认 ISO,支持 year_month / cn / short" do
      d = Date.new(2026, 11, 16)
      aggregate_failures do
        expect(described_class.apply(d, "date")).to eq("2026-11-16")
        expect(described_class.apply(d, "date.year_month")).to eq("2026年11月")
        expect(described_class.apply(d, "date.cn")).to eq("2026年11月16日")
        expect(described_class.apply(Time.new(2026, 11, 16, 9, 30), "date.short")).to eq("11/16")
      end
    end
  end

  describe "边界行为" do
    it "spec 为 nil 时不格式化(返回 nil,由 Binder 走默认 to_s)" do
      expect(described_class.apply(29.7, nil)).to be_nil
    end

    it "类型不符抛 PowerTom::Error" do
      expect { described_class.apply("abc", "currency") }
        .to raise_error(PowerTom::Error, /currency.*String/)
      expect { described_class.apply("2026-11-16", "date") }
        .to raise_error(PowerTom::Error, /date.*String/)
    end

    it "date 未知参数报错并列出可用值" do
      expect { described_class.apply(Date.today, "date.nothing") }
        .to raise_error(PowerTom::Error, /date.*不支持/)
    end

    it "未注册的 formatter 报错并列出可用名" do
      expect { described_class.apply(1, "nope") }
        .to raise_error(PowerTom::Error, /未注册的 formatter 'nope'/)
    end
  end

  describe "自定义注册" do
    after do
      # 清理测试注册,避免污染其他用例
      PowerTom::Formatter.registered_names
                         .select { |n| n.start_with?("spec_") }
                         .each { |n| PowerTom.unregister_formatter(n) }
    end

    it "PowerTom.register_formatter 注册自定义 formatter" do
      PowerTom.register_formatter("spec_shout") { |value, _arg| "#{value}!!" }
      expect(PowerTom::Formatter.apply("加油", "spec_shout")).to eq("加油!!")
      expect(PowerTom::Formatter.registered?("spec_shout")).to be(true)
      expect(PowerTom::Formatter.registered_names).to include("spec_shout")
    end

    it "自定义 formatter 也能带 .参数" do
      PowerTom.register_formatter("spec_pad") { |value, arg| value.to_s.rjust(arg.to_i, "0") }
      expect(PowerTom::Formatter.apply(42, "spec_pad.5")).to eq("00042")
    end
  end
end

# Binder 层:formatter 与缺失字段/nil 语义的组合
RSpec.describe PowerTom::Binder do
  ctx = { slide_no: 2, shape: "文本框 5" }

  it "spec 生效:标签继承所在 run 样式,文本由 formatter 产出" do
    binder = described_class.new({ price: 99.5, ratio: 0.123 }, strict: true, warnings: [])
    aggregate_failures do
      expect(binder.render_label("price", ctx, spec: "currency")).to eq("¥99.50")
      expect(binder.render_label("ratio", ctx, spec: "percent.1")).to eq("12.3%")
    end
  end

  it "nil 值:formatter 不参与,直接空字符串,不报错" do
    warnings = []
    binder = described_class.new({ price: nil }, strict: true, warnings: warnings)
    expect(binder.render_label("price", ctx, spec: "currency")).to eq("")
    expect(warnings).to be_empty
  end

  it "缺失字段:strict 报错;non-strict 先填空,formatter 不参与" do
    strict = described_class.new({}, strict: true, warnings: [])
    expect { strict.render_label("price", ctx, spec: "currency") }
      .to raise_error(PowerTom::MissingDataError)

    warnings = []
    loose = described_class.new({}, strict: false, warnings: warnings)
    expect(loose.render_label("price", ctx, spec: "currency")).to eq("")
    expect(warnings.join).to include("已填空字符串")
  end
end
