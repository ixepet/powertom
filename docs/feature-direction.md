# Feature direction and design notes

> Status: reviewed · 2026-11-17
> Scope: current limitations, decisions and candidate directions. This is not a
> fixed roadmap; items may be deferred or rejected based on complexity,
> fidelity and maintenance burden.

## Design principle

PowerTom's default path prioritises **designer control, predictable
PowerPoint-native fidelity, and early validation**. A new feature is preferred
only when it can be:

1. opt-in,
2. clearly bounded,
3. validated before any OOXML is written,
4. introduced without silently breaking existing templates.

Two consequences worth stating explicitly:

- A feature that changes every slide must be opt-in **at the tag level**, not
  only by the accident of being placed on a master or layout.
- Every fidelity caveat needs either a warning in `check`/render or a regression
  test; "it usually looks fine" is not an acceptance criterion.

## Decision summary

| Area | Decision | Main reason |
| --- | --- | --- |
| Chart series add/remove | Keep for standard charts, reject for pie, keep strict for combo / scatter / bubble | Upstream already handles standard charts; pie silently drops extra series; combo and XY need structural guards |
| Picture contain mode | Implemented as opt-in `mode=contain`; `fill` remains the default | Geometry is bounded; margins show what is behind the picture |
| JSON / YAML input | No built-in loaders; document adapter snippets | Small dependency surface; `Hash` is the stable API |
| Master / layout tags | Runtime still ignores them; `PowerTom.check` now reports them as errors | Shared parts and placeholder inheritance rule out binding; the public check closes the validation gap |
| General principle | Accepted as written | Matches the existing check-first, all-or-nothing design |

---

## 1. Chart: dynamic add/remove series

### Verified current behaviour

The earlier draft said every chart requires exactly the template's series
count. **That is not what the code does.** The strict rule applies only to
combo, scatter (XY) and bubble charts.

| Chart kind | Series count behaviour | Guard |
| --- | --- | --- |
| Bar / column, line, area, radar | Add/remove allowed. Additional series are cloned from the last series and inherit its formatting; surplus series are removed and emptied plots deleted. | None |
| Doughnut | Same as above; additional series become concentric rings. | None |
| Pie | Only the first series is drawn; extra series are silently ignored. | **Implemented**: hard error in both `check` and render when more than one series is supplied |
| Combo | Series are flattened across plots; adding/removing can silently reassign plot structure. | Hard error in both `check` and render |
| Scatter / bubble | Adapter rewrites `xVal` / `yVal` / `bubbleSize` in place and zips by index. | Hard error in both `check` and render |

Additional verified details:

- Zero series is rejected before anything is written (`series` must be a
  non-empty array). This is intentional: upstream removes the emptied plot
  when the series count reaches zero.
- Series count changes on standard charts are **not** reported by `check`, so a
  designer gets no warning that extra series inherit the last series' style.
- Pie silently ignoring extra series was confirmed by rendering a one-series
  pie rebound to two series: the output still showed one pie. Doughnut with two
  series rendered two rings. A hard guard now rejects more than one pie series
  before any OOXML is written.
- `number_format` is written only into each series' cached value block
  (`c:val/c:numRef/c:numCache/c:formatCode`). It does not touch `c:numFmt` on
  axes or data labels, and it does not format the embedded workbook's value
  cells. A template's explicit `c:numFmt` (`sourceLinked="0"`) therefore wins
  over the data's `number_format`; when labels/axes are source-linked, the
  cached format code is used. Percent formats expect fractional data
  (`0.145`, not `14.5`).

### Rationale for the remaining strict cases

- **Combo**: one chart part contains several plots. A flat series list cannot
  express which incoming series belongs to which plot, so the only safe
  contract is "same total count, same document order".
- **Scatter / bubble**: these series carry their own `xVal` / `yVal`
  (`bubbleSize`) instead of a shared category cache. The adapter rewrites the
  existing `c:ser` elements positionally; a count mismatch would leave stale or
  missing series.
- **Pie**: PowerPoint's pie model is effectively single-series. Accepting more
  series produces output that looks successful but loses data.

### Decision

1. Keep dynamic add/remove for bar/column, line, area, radar and doughnut; it
   is already delivered, not a future feature.
2. **Pie guard delivered**: exactly one series in both `check` and render,
   reported as a located error. This is a correctness fix, not a feature flag.
3. Optionally add a **warning** when a standard chart's series count differs
   from the template: state that added series inherit the last series'
   formatting and that removed series' formatting disappears.
4. Keep the strict rule for combo, scatter and bubble.
5. Do **not** add an `allow_series_add_remove` flag for standard charts; it
   would only re-expose existing behaviour. If a flag is ever needed, scope it
   to pie/doughnut, default to strict, and document the visual consequences.

### Open questions

- Which use case dominates: time-series charts whose line count varies per
  report, category-driven charts whose series grow unpredictably, or ad-hoc
  dashboards?
- For doughnut charts, is a changing ring count acceptable, or should the
  series count also be fixed?

---

## 2. Picture binding: contain / letterbox mode

### Verified current behaviour

`powertom:image:key` always fills the target shape and centre-crops. When the
image aspect ratio differs from the placeholder by more than 20%, render emits
a warning that the image will be centre-cropped. Vector images are not cropped.

### Feasibility notes

Contain mode is technically straightforward:

1. `scale = min(placeholder_width / image_width, placeholder_height / image_height)`;
2. fitted size = native size × scale;
3. centre the fitted rectangle inside the placeholder;
4. write the resulting offset and extent onto the picture shape and clear any
   `srcRect` crop.

Two corrections to the original proposal:

- The margins show **whatever is behind the picture** (slide background or a
  separate shape). A `p:pic` has no background fill of its own; contain mode
  must not promise to restore "the placeholder's fill" unless the template
  provides a background shape.
- Picture effects and rotation move/scale with the picture. A rotated
  placeholder needs extra care; the first pass should either reject it or treat
  contain as fitting the unrotated bounds.

Syntax would be a suffix on the existing placeholder, for example
`powertom:image:key; mode=contain`. This requires parsing the existing field
name rather than `delete_prefix`, plus corresponding `check`/lint support. The
aspect-ratio warning only applies to `fill`.

### Decision

- **Implemented** as an opt-in suffix: `powertom:image:<field>; mode=contain`.
  `fill` remains the default, so existing templates are unchanged.
- Margins show whatever is behind the picture; no background fill is
  synthesised.
- Regression tests cover geometry, explicit `mode=fill`, alt-text syntax,
  invalid modes and warning suppression in contain mode.
- Rotated placeholders remain a caveat: contain fits the unrotated bounds.

---

## 3. Data input: JSON / YAML support

### Verified current behaviour

The built-in loader accepts:

- a Ruby `Hash` (programmatic API),
- a path ending in `.toml` (converted to `Hash` with date normalisation).

There is no built-in JSON or YAML loader. `PathResolver` accepts both string
and symbol keys, so a `Hash` produced by any parser works without conversion.

### Decision

Do not add built-in loaders. Keep `Hash` as the stable input contract. The
adapter pattern is documented in `docs/usage.md` §7:

```ruby
require "json"

data = JSON.load_file("data.json")
PowerTom.render("template.pptx", data: data)
```

For YAML, use the safe loader; never `YAML.load_file` on untrusted input:

```ruby
require "yaml"

data = YAML.safe_load_file("data.yaml", permitted_classes: [Date, Time], aliases: true)
PowerTom.render("template.pptx", data: data)
```

Document two caveats:

- JSON/YAML have no native date type. Date-like strings stay strings, so a
  `date` formatter needs them converted to `Date` / `Time` first.
- The TOML loader's error message was reworded to "the built-in loader only
  supports .toml" so it no longer says "v0".

Adding optional auto-detection later is acceptable only as a separate opt-in
path; it should not change the meaning of the `data:` argument for existing
callers.

---

## 4. Master / layout tags

### Verified current behaviour

- Runtime binding scans normal slides only. Tags on masters and layouts are
  never rendered.
- `template_lint` and `PowerTom.check` both report tags on masters/layouts as
  **errors**: "tags on masters/layouts never take effect". The public API no
  longer relies on the project-only tool.

### Feasibility notes

A narrow "global master variable" layer is technically possible:

- only simple scalar interpolation, evaluated against root data;
- no `#each`, `#if`, image/chart/table markers or page directives;
- a distinct namespace (for example `{{global:field}}`) so opting in is
  explicit per tag;
- `check` rejects every non-scalar construct on masters/layouts;
- render applies these tags before slide-level binding.

The risks are not primarily technical:

- master/layout parts are shared by many slides;
- a slide can override a placeholder, so a "global" value may not appear
  wherever the designer expects;
- changing a master affects slides that contain no PowerTom tags at all.

### Decision

- Defer master/layout **binding**. Runtime continues to ignore tags there.
- **Implemented**: `PowerTom.check` reports master/layout tags as **errors**,
  matching `template_lint`; no project tool is required.
- Do not support loops, conditionals, images, charts or tables on masters or
  layouts, now or later.
- If a concrete repeated need appears, implement only the scalar `global`
  namespace, opt-in per tag, with an explicit warning that all slides using the
  layout may change.

---

## Verification notes

- Chart series behaviour was verified against `ruby_pptx` 0.2.0
  (`Chart#replace_data`, `SeriesRewriter#adjust_series_count`,
  `#clone_series`, `#trim_series`) and against rendered output:
  bar charts accept add/remove; pie ignores extra series; doughnut renders
  extra series as rings.
- Chart data shape, zero-series rejection and the combo/XY/bubble count guards
  live in `PowerTom::Render#validate_chart_data!`,
  `#validate_chart_series_count!` and `PowerTom::Validator`.
- Picture fill/crop, contain geometry and the 20% warning live in
  `RubyPptxAdapter#replace_image` / `#fit_image_inside` /
  `#image_aspect_mismatch` and `PowerTom::Render#warn_image_aspect`.
  Contain is covered by `spec/powertom/image_contain_spec.rb`.
- Master/layout detection lives in `RubyPptxAdapter#container_texts` and is
  consumed by both `tools/template_lint.rb` and `PowerTom.check`
  (`spec/powertom/check_container_spec.rb`).
- JSON/YAML adapter snippets are documented in `docs/usage.md` §7; there is no
  built-in loader by design.
- LibreOffice was used for visual probes. PowerPoint-specific checks are still
  required for new chart/picture templates, as with every visual feature.
