# frozen_string_literal: true

# TableLoop.plan 的纯逻辑契约:不构造 PPTX,直接验证合并/路径的判定口径。
# check 与 render 都经 adapter 传入 merged_spans,这里锁定 plan 自身的分支行为,
# 包括未传 merged_spans 时向后兼容的保守口径。
RSpec.describe PowerTom::TableLoop do
  def band_rows
    [
      ["固定", "列", "{{#cols subjects}}{{col.label}}{{/cols}}"],
      ["{{#rows classes}}", "", ""],
      ["{{classes[].name}}", "{{classes[].name}}", "{{cell}}"],
      ["{{/rows}}", "", ""],
      ["合计", "", ""]
    ]
  end

  describe "合并单元格与列带" do
    it "静态行在固定列合并 → 放行(合并区间与 band 不相交)" do
      merged_rows = [false, false, false, false, true]
      spans = [[], [], [], [], [[0, 1]]] # col0-1 固定列合并,band 在 col2
      plan = described_class.plan(band_rows, merged_rows: merged_rows, merged_spans: spans)
      expect(plan[:kind]).to eq(:blocks)
    end

    it "静态行合并跨越 band 列 → 拒绝" do
      merged_rows = [false, false, false, false, true]
      spans = [[], [], [], [], [[1, 2]]] # col1-2 与 band 列 col2 相交
      expect { described_class.plan(band_rows, merged_rows: merged_rows, merged_spans: spans) }
        .to raise_error(PowerTom::TemplateSyntaxError, /merged cells cannot intersect a column band/)
    end

    it "列带声明行自身合并跨 band → 拒绝" do
      merged_rows = [true, false, false, false, false]
      spans = [[[1, 2]], [], [], [], []]
      expect { described_class.plan(band_rows, merged_rows: merged_rows, merged_spans: spans) }
        .to raise_error(PowerTom::TemplateSyntaxError, /merged cells cannot intersect a column band/)
    end

    it "未传 merged_spans → 回退到保守口径(有合并即拒绝)" do
      merged_rows = [false, false, false, false, true]
      expect { described_class.plan(band_rows, merged_rows: merged_rows) }
        .to raise_error(PowerTom::TemplateSyntaxError, /column band loops do not support merged cells/)
    end

    it "行区块内合并 → 无论列位置都拒绝" do
      merged_rows = [false, false, true, false, false]
      spans = [[], [], [[0, 0]], [], []]
      expect { described_class.plan(band_rows, merged_rows: merged_rows, merged_spans: spans) }
        .to raise_error(PowerTom::TemplateSyntaxError, /row blocks do not support merged cells/)
    end
  end

  describe "子块路径" do
    it "relative 含 [] → 拒绝并指向嵌套写法" do
      rows = [
        ["{{#rows a}}", ""],
        ["{{a[].n}}", ""],
        ["{{#rows a[].b[].c}}", ""],
        ["{{a[].b[].c[].n}}", ""],
        ["{{/rows}}", ""],
        ["{{/rows}}", ""]
      ]
      expect { described_class.plan(rows) }
        .to raise_error(PowerTom::TemplateSyntaxError, /nests more than one array level/)
    end

    it "合法的多级嵌套区块 → 通过" do
      rows = [
        ["{{#rows a}}", ""],
        ["{{a[].n}}", ""],
        ["{{#rows a[].b}}", ""],
        ["{{a[].b[].n}}", ""],
        ["{{/rows}}", ""],
        ["{{/rows}}", ""]
      ]
      expect(described_class.plan(rows)[:kind]).to eq(:blocks)
    end
  end
end
