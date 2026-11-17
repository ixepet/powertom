# Chart data binding design (§5.4 pre-research)

> Status: **implemented (v0.4.0)** · 2026-11-17
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
| Rebind with **zero** series | `plot_type: nil`, no series — upstream `SeriesRewriter#trim_series` removes the emptied plot, so the binding layer must treat "no series" as an error |
| LibreOffice PDF conversion of all four outputs | succeeds; prints `SKIP` instead of `FAILED` when `soffice` is not on `PATH` |

## 3. Key constraint: cloned slides share the chart part

`PageSurgery.execute` on a chart slide (clone 1 page → 2) yields
`slide1 → chart1.xml`, `slide2 → chart1.xml` — **the chart part is shared**.
`clone_sharing_check` asserts this and raises if a future `PageSurgery` change
starts copying parts, so this conclusion cannot rot silently.

Consequence: on `#each`-cloned pages, one `replace_data` call would overwrite
every clone. The binding phase must therefore **deep-copy the chart part per
output page** before binding. `deep_copy_clone_check` verifies the full plan:
clone → deep-copy → bind different categories/series to each page → read back
and assert both pages kept their own data, and that chart parts and embedded
workbooks are distinct.

1. Copy `ppt/charts/chartN.xml` to a fresh partname and add an `<Override>` to
   `[Content_Types].xml` — chart parts are **not** covered by the `xml`
   `<Default>`, so the override is required.
2. Rewrite the chart relationship in the bound slide's rels to point at the
   new part, then drop the stale relationship (ruby_pptx's reference-counted
   `XmlPart#drop_rel`). Implemented behaviour: the **first** bound page takes
   a fresh copy, the **last** bound page keeps the original part, and no
   slide rels keep a stale reference. Orphaned parts never reach the output —
   `save` writes only the parts reachable from the relationship graph.
3. Do **not** copy `ppt/charts/_rels/chartN.xml.rels`, and strip the
   `<c:externalData>` element from the copied chart XML. Leaving either in
   place makes `ChartWorkbook#replace_with` resolve the old shared workbook (or
   a dangling `r:id`) instead of creating a fresh one; with both removed,
   `replace_data` creates one embedded workbook and `c:externalData` link per
   output part.

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

## 9. Extension: combo / scatter / bubble (v0.4.x, spike2 verified)

`tools/chart_binding_spike2.rb` (2026-11-17) tested the three remaining chart
families. Evidence:

| Scenario | Result |
| --- | --- |
| Combo bar(1)+line(1, secondary axis), same-shape rebind | both plots rebound independently; LibreOffice conversion OK |
| Combo series 2→3 | extra series cloned from the **last series of the last plot** (the line plot) |
| Combo series 2→1 | the emptied line **plot is removed** — the chart silently degrades to a plain bar chart |
| `replace_data(XyChartData)` on a scatter | raises `NoMethodError` (`categories`) — upstream does not support it |
| `replace_data(ChartData)` on a scatter | produces a **schema-invalid** `c:ser` (a `c:val` is injected while the stale `c:xVal` remains) — unusable |

Consequences:

1. **Combo binding is feasible with the current machinery.** `SeriesRewriter`
   zips series across plots in document order and rewrites each `c:ser`'s
   `c:tx/c:cat/c:val`; bar/line/area plots all share the `cat+val` model. The
   data shape is identical to a normal chart (`categories` + `series`). One
   rule must be added: a combo placeholder requires the data's series count to
   equal the template's total series count — otherwise trim/clone silently
   adds or removes plots and destroys the designer's combo structure. The
   bind error reports the template's per-plot distribution (e.g.
   `column×1 + line×1`).
2. **Scatter/bubble cannot ride upstream `replace_data`**: `SeriesFragments`
   only emits `c:tx/c:cat/c:val` fragments and `rewrite_series` never
   removes `c:xVal/c:yVal/c:bubbleSize`. Supporting them needs either an
   adapter-level XY rewriter (build `c:xVal`/`c:yVal` num-ref fragments —
   `XyChartData#xlsx_blob` already exists) or an upstream contribution. They
   stay guarded (rejected with an error) until that work is scheduled.
