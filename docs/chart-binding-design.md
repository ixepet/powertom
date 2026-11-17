# Chart data binding design (§5.4 pre-research)

> Status: **spike verified, not yet implemented** · 2026-11-17
> Spike: `tools/chart_binding_spike.rb` · Supersedes the assumptions in
> project design document §5.4.

---

## 1. Finding: the hard part already exists upstream

Project design document §5.4 deferred chart binding "because series add/remove
and `c:idx` / `c:order` maintenance are hard, and it may fit a separate gem
(powertom-charts) or an upstream PR". **ruby_pptx 0.2.0 already implements all
of it:**

| Upstream API | What it does |
| --- | --- |
| `Pptx::ChartData` | `categories = [...]` (flat, grouped or date axes) + `add_series(name, values, number_format:)`; generates the embedded xlsx blob |
| `GraphicFrame#chart` → `Chart#replace_data(chart_data)` | Rewrites every `c:ser`: rebinds names/categories/values, clones the last series' formatting for extra series, removes surplus series, renumbers `c:idx` / `c:order`, and **regenerates the embedded workbook** so PowerPoint's "Edit Data" stays consistent |
| `Shapes#add_chart(chart_type, chart_data)` | Creates a chart from scratch |
| `shape.chart?` / `shape.chart` | Shape → chart access (PowerTom's `chart_tags` already relies on it) |

Conclusion: chart binding does **not** need a separate gem and does **not**
need an upstream PR. It is a thin layer over `replace_data`: locate charts by
naming convention, map data to `ChartData`, call `replace_data`, validate.

## 2. Spike evidence

`tools/chart_binding_spike.rb` builds a column chart (2 series × 4 categories)
named `powertom:chart:sales`, then rebinds and re-reads the chart XML:

| Scenario | Result |
| --- | --- |
| Create + read back | `plot_type: :BAR`, categories/series round-trip |
| Rebind, categories 4→3, series renamed/re-valued | caches correct |
| Rebind with **more** series (2→3) | 3rd series cloned, inherits formatting |
| Rebind with **fewer** series (2→1) | surplus removed, plot kept |
| Rebind with **zero** series | plot removed → binding layer must treat "no series" as an error |
| LibreOffice PDF conversion of all three outputs | succeeds |

## 3. Key constraint: cloned slides share the chart part

`PageSurgery.execute` on a chart slide (clone 1 page → 2) yields
`slide1 → chart1.xml`, `slide2 → chart1.xml` — **the chart part is shared**.

Consequence: on `#each`-cloned pages, one `replace_data` call would overwrite
every clone. The binding phase must therefore **deep-copy the chart part per
output page** before binding:

1. Copy `ppt/charts/chartN.xml` to a fresh partname and add it to
   `[Content_Types].xml` (already declared by extension).
2. Copy the slide's chart relationship into the cloned slide's rels, pointing
   at the new part.
3. Do **not** copy the old `ppt/embeddings/*.xlsx` link; `replace_data` calls
   `ChartWorkbook#replace_with`, which creates a fresh embedded workbook and
   `c:externalData` link per part — each clone gets its own editable workbook.

This mirrors picture replacement, which already writes one media part per
output page. Implementation detail lives in the adapter; `PageSurgery` itself
stays untouched (binding knows the output-page ↔ data-item mapping).

## 4. Proposed template syntax

Naming convention, consistent with `powertom:image:<field>`:

```text
shape name or alt text = powertom:chart:field_name
```

Data shape (TOML and Hash are mirror images, as everywhere else):

```toml
[sales]
categories = ["Q1", "Q2", "Q3", "Q4"]
number_format = "0.0"        # optional, default "General"

[[sales.series]]
name = "2026"
values = [14.5, 24.0, 18.5]

[[sales.series]]
name = "2027"
values = [16.0, 21.0, 20.0]
```

Authoring flow for designers: draw a real chart in PowerPoint with placeholder
series, name the shape `powertom:chart:sales`, done. The renderer replaces the
whole data set; series formatting comes from the template (first series' style
for rewrites, last series cloned for extras).

## 5. Error model and check

- Missing `sales` / not a Hash → `MissingDataError` / `PowerTom::Error` with
  slide number, shape name and field (same shape as picture errors)
- `categories` not an array of strings, `series` missing or empty → error
  (zero-series binding is rejected; the spike showed it deletes the plot)
- Every `values` entry must be Numeric and `values.size == categories.size`
- `check` reconciles the same shape per `#each` item, mirroring picture
  reconciliation
- The existing "chart contains `{{tags}}`" warning stays: text tags inside
  charts remain unsupported

## 6. Scope

**First pass**: bar / column / line / area / pie / doughnut — all use the
`c:ser` + `c:cat` + `c:val` model that `replace_data` handles.

**Deferred**: scatter / bubble (`XyChartData` has a different shape), combo
charts (multi-plot, needs `ComboChartWriter`), pivot-source charts, text tags
inside charts, creating charts into empty placeholders.

**Explicitly not done**: switching chart type from data; per-point formatting
from data.

## 7. Risks

- LibreOffice is more lenient than PowerPoint: every new chart template still
  needs one manual PowerPoint pass (§5.5 checklist)
- When series/category counts change, per-point formatting (data labels,
  point colours) follows the upstream clone strategy — visual QA required
- One embedded xlsx per output page; negligible size, but a template with
  many cloned chart pages multiplies parts

## 8. Rollout

| Phase | Content |
| --- | --- |
| v0.4.0 | Naming-convention locator + per-clone chart part deep copy + `replace_data` binding + `check` reconciliation + mini-golden regression |
| v0.4.x | Scatter / bubble, combo charts |

> The spike removes the two assumptions that postponed §5.4: no XML surgery is
> needed (upstream `SeriesRewriter`) and no separate gem is warranted (the
> PowerTom layer is naming convention + data mapping + validation).
