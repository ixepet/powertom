---
layout: page
title: Usage reference
---

# PowerTom usage reference

> Companion to the README: the data shape, every tag form, and the rules the engine enforces.
> Designer-facing guide: [template-guide.html](template-guide.html).

## 1. Minimal render

```ruby
require "powertom"

data = {
  title: "Final exams",
  classes: [{ name: "Grade 8 (3)", avg: 82.4 }]
}
result = PowerTom.render("template.pptx", data: data)
result.save("report.pptx")
result.warnings.each { |w| warn w }
```

- `template.pptx` is a normal PowerPoint file: tags in the body, page directives in the notes.
- `data` is a Ruby Hash or a path to a `.toml` file.
- `strict: true` (default) raises `PowerTom::MissingDataError` for a missing field.
  `strict: false` renders an empty string and records a warning instead.
- Rendering is all-or-nothing: every check runs before anything is written to disk.
- `PowerTom.render(...)` returns a `RenderResult` (`save`, `warnings`, `slide_count`).

## 2. Text tags

| Tag | Data | Result |
| --- | --- | --- |
| `{{title}}` | `title: "Final exams"` | Final exams |
| `{{school.name}}` | nested Hash | dot path |
| `{{kpis[0].value}}` | array + index | first KPI value |
| `{{price:currency}}` | `1234.5` | ¥1,234.50 |
| `{{ratio:percent.1}}` | `0.297` | 29.7% |
| `{{count:number}}` | `12345` | 12,345 |
| `{{day:date.cn}}` | `Date.new(2026, 1, 20)` | 2026年1月20日 |

Rules:

- Paths are dot paths plus numeric indexes. No expressions, operators or method calls.
- `{{ name }}` and `{{name}}` are equivalent; several tags may share a paragraph.
- If PowerPoint splits a tag across runs, the engine merges the paragraph. The result
  inherits the style of the **first run** in that paragraph.
- `currency`, `percent`, `number` and `date` are built in. A custom formatter is registered with:

  ```ruby
  PowerTom.register_formatter("rmb") { |value, _arg| "CNY#{value}" }
  ```

- Tags on masters and layouts are ignored. Put tags on slide shapes.

## 3. Page directives (notes)

| Directive | Effect |
| --- | --- |
| `{{#each classes}}` | Clone this page once per array item. An empty array removes the whole group. |
| `{{#if show_appendix}}` | Remove this page when the value is `false` or `nil`. |

- Directives live in the **slide notes**, one per page.
- Labels on an `#each` page resolve against the current item only — there is no
  fallback to the root data. Use `{{headline}}`, not `{{scenario.headline}}`.
- `{{@index}}`, `{{@index1}}`, `{{@first}}` and `{{@last}}` are available on
  `#each` pages (see §4.7).
- A missing `#each` path is an error; pages are never dropped silently.
- A page cannot combine a page directive with a table block/loop.

## 4. Table loops

Table loops are opt-in per table; header and total rows stay static.

### 4.1 Single-level row loop: `{{array[].field}}`

```text
| Class                 | Average               |
| {{classes[].name}}    | {{classes[].avg}}     |
| Total                 | {{total}}             |
```

- The row containing `[]` is the template; it is cloned once per array item.
- One loop row per table. `[]` is only valid inside table cells.
- An empty array removes the template row; headers and totals remain.
- Labels without `[]` in the same row still come from the page data.
- `{{@index}}` / `{{@index1}}` / `{{@first}}` / `{{@last}}` work on the text of the loop row (see §4.7).

### 4.2 Two-level legacy form: `{{#rows parent}}` + next row

```text
| {{#rows groups}}              |                  |
| {{groups[].name}}             |                  |
| {{#rows groups[].items}}      |                  |
| {{groups[].items[].name}}     | {{...score}}     |
```

- The marker row itself is not printed; the **next row** is the content row.
- Maximum two levels (parent → child).
- Kept for templates created before v0.2. New templates should use paired blocks.

### 4.3 Paired row blocks: `{{#rows path}} ... {{/rows}}`

```text
| {{#rows grades}}                    |                    |
| {{grades[].name}}                   |                    |
| {{#rows grades[].classes}}          |                    |
| {{grades[].classes[].name}}         | {{...avg}}         |
| {{grades[].classes[].note}}         |                    |
| {{/rows}}                           |                    |
| {{/rows}}                           |                    |
```

- Each marker occupies a whole row (first cell only); marker rows are not printed.
- Everything between the markers is **one record** and is cloned per item.
- Up to **3 levels**; a child path must start with the parent path plus `[]`.
- `{{row.field}}` refers to the current record's field.
- An empty array removes the whole block, including child blocks.
- Full paths (`grades[].classes[].name`) stay valid in every level.

### 4.4 Column bands: `{{#cols path}} ... {{/cols}}`

```text
| Class | {{#cols subjects value: scores}}{{col.label}}{{/cols}} |
| {{#rows classes}}            |          |
| {{classes[].name}}           | {{cell}} |
| {{/rows}}                    |          |
```

- The band spans the columns between the two markers and is cloned per `cols` item.
- A band may be declared in the header row or **inside a row block** (its declaration row is cloned with the block).
- `{{col.label}}` / `{{col.field}}` read the column item; `{{cell}}` is the row × column value.
- `value:` names the row field that holds the per-column values:
  - one field → shared by every template column;
  - `value: scores,rates` → one field per template column, count must be 1 or the band width.
- Without `value:`, `{{cell}}` reads `row[col.key]`.
- Column items must be Hashes with a `key`, or plain scalars used as the key.
- An empty `cols` array keeps only the fixed columns.
- A band at least needs one fixed column to the left.

#### Column conditions

`{{#if ...}} ... {{/if}}` inside a band header cell hides the wrapped template columns for
column items where the condition is falsy:

```text
| Class | {{#cols subjects value: scores}}{{#if subjects[].show}}{{col.label}}{{/if}}{{/cols}} |
| {{#rows classes}} | |
| {{classes[].name}} | {{cell}} |
| {{/rows}} | |
```

- The condition is evaluated **per column item**, and the whole wrapped template column is removed
  from every row (and from `a:gridCol`) when it is false.
- Paths may address the column item (`show`), the full column path (`subjects[].show`), or page data.
  The column item is tried first, then the page data.
- A column condition cannot reference row fields: the result must be uniform across all rows.
- Conditions cannot nest, must stay inside the band, and their column ranges must not overlap.

### 4.5 Row conditions: `{{#if path}} ... {{/if}}`

```text
| {{#rows classes}}            |                |
| {{#if classes[].has_data}}   |                |
| {{classes[].name}}           | {{...avg}}     |
| {{/if}}                      |                |
| {{/rows}}                    |                |
```

- Conditional blocks live **inside a row block**, cannot nest, and cannot contain loops or column bands.
- A falsy value removes every row in the block; marker rows are not printed.
- A path containing `[]` resolves against the row scope. Otherwise it is looked up on the current
  record first, then on the page data (so `{{#if show_note}}` works as a page-wide switch).
- A missing condition field is an error, not an implicit `false`.

### 4.6 Dynamic columns: `{{#grid ...}}`

```text
| {{#grid rows: distribution cols: bands value: counts}} | {{col.label}} |
| {{row.name}}                                           | {{cell}}      |
```

- The marker sits in the first cell of the header row; the next row is the row template.
- The table must have exactly **two columns** (row title + column template).
- `rows:` is the row array, `cols:` the column array, `value:` an optional row field.
- An empty `cols` keeps the first column; an empty `rows` keeps the header.
- A table can use only one of `#grid`, `#rows` or `[]`.

### 4.7 Loop variables: `@index`, `@index1`, `@first`, `@last`

| Tag | Value |
| --- | --- |
| `{{@index}}` | 0-based index of the current item |
| `{{@index1}}` | 1-based index |
| `{{@first}}` | `true` on the first item |
| `{{@last}}` | `true` on the last item |

- Available in `[]` row loops, `#rows` blocks, `#grid` data rows and `#each` pages.
- They refer to the innermost loop (in parent/child blocks, the child index).
- Header/total rows and non-loop pages are errors in `check` and at render time.
- Formatters apply: `{{@index1:number}}`.

### 4.8 Aggregates: `{{array[].field:sum}}`

| Tag | Result |
| --- | --- |
| `{{classes[].avg:sum}}` | sum |
| `{{classes[].avg:avg}}` | mean |
| `{{classes[].avg:min}}` / `:max` | smallest / largest |
| `{{classes[]:count}}` | item count |

- Single-level array with a numeric field; nil values are skipped, empty `sum`
  is `0`, empty `avg/min/max` render blank.
- Works in body text, table total rows and `#each` pages (array from the item).
- No expressions, sorting or filtering; `check` rejects non-numeric fields.

## 5. Images

- Name a picture shape (or its alt text) `powertom:image:cover`.
- Put the image file path in the data under the matching field.
- Default `fill` mode fills the shape and crops from the centre; use a
  placeholder with the target aspect ratio. Append `; mode=contain` to fit the
  whole image inside the frame and centre it without cropping:
  `powertom:image:cover; mode=contain`. The margins show whatever is behind
  the picture (slide background or another shape); no background fill is
  synthesised.
- A missing field keeps the placeholder (`strict: false`); a path that does not exist is an error.
- Picture fields are references. Configure `PowerTom.configure { |c| c.asset_resolver = ... }`
  (or pass `asset_resolver:` to `render`/`check`) to resolve them from object
  storage: the resolver returns a path or `{data: <binary>, extension: "png"}`.
  PowerTom never performs network calls itself.

### 5.1 Conditional shapes: `powertom:if:<field>`

- Name a shape (or its alt text) `powertom:if:show_logo`.
- When the value is falsy (`false` / `nil`), the shape is removed at render
  time; truthy keeps it untouched. Groups are supported — the whole group goes.
- On an `#each` page the field is read from the current item.
- `PowerTom.check` validates the field (and every `#each` item); a missing field
  is an error. Conditions are evaluated before binding, so hidden shapes do not
  raise for their own tags.

## 6. Charts

- Name a chart shape (or its alt text) `powertom:chart:sales`.
- Put the whole data set in the data under the matching field:

```toml
[sales]
categories = ["Q1", "Q2", "Q3", "Q4"]
number_format = "0.0"        # optional, default "General"

[[sales.series]]
name = "2026"
values = [14.5, 24.0, 18.5, 22.0]

[[sales.series]]
name = "2027"
values = [16.0, 21.0, 20.0, 25.5]
```

- The whole data set is replaced: categories and series are rewritten, extra
  series inherit the last template series' formatting, surplus series are
  removed. Chart type, layout and series formatting come from the template.
- When the data's series count differs from the template's on a standard chart
  (bar/column, line, area, doughnut, radar), rendering still succeeds but emits
  a warning: added series inherit the last template series' formatting, and
  removed series take their formatting with them. `PowerTom.check` reports the
  same mismatch as a warning. Combo, scatter and bubble charts still require
  exactly the template's series count (error otherwise).
- `categories` and every series' `values` must have the same length; `values`
  must be numbers; zero-series data is rejected.
- Pie charts plot exactly one series; data with more than one series is
  rejected. Doughnut charts accept multiple series as concentric rings.
- Supported chart types: bar / column / line / area / pie / doughnut / radar,
  and combo charts (e.g. column + line with a secondary axis): a combo binds
  its series in document order and the data must provide exactly the
  template's total series count, otherwise the combo structure would change.
- Radar charts (including the filled variant) bind like line charts: the
  template's `radarStyle` and radial-axis settings — such as a fixed maximum
  of 100 — survive the rebind untouched.
- Scatter and bubble charts bind per-series `points` instead of shared
  categories:

```toml
[scatter]
[[scatter.series]]
name = "Group A"
[[scatter.series.points]]
x = 1.0
y = 10.0
[[scatter.series.points]]
x = 2.0
y = 20.0
```

  Bubble points additionally carry `size`. The series count must equal the
  template's series count.
- `#each` cloned pages are supported: each clone binds its own item's data in
  its own chart part.
- A missing field keeps the placeholder chart (`strict: false`); a wrong data
  shape is an error located at slide / shape / field.

## 7. Data files (TOML)

```toml
report_title = "2026 final exams"   # top-level scalars before any [[array]]
report_date = 2026-01-20            # unquoted → Ruby Date

[[classes]]
name = "Grade 8 (3)"
avg = 82.4
```

- TOML is the default data format; a Ruby Hash works too.
- Write top-level scalars **before** the first `[[array]]`; otherwise TOML attaches them to the last array item.
- Dates are normalised to Ruby `Date` / `Time` and can use the `date` formatter.
- Keys may be Strings or Symbols in a Hash; TOML keys arrive as Strings.
- JSON and YAML are not built-in. Load them outside PowerTom and pass a Hash:

```ruby
require "json"

data = JSON.load_file("data.json")
PowerTom.render("template.pptx", data: data)
```

```ruby
require "date"
require "yaml"

data = YAML.safe_load_file("data.yaml", permitted_classes: [Date, Time], aliases: true)
PowerTom.render("template.pptx", data: data)
```

  Use `YAML.safe_load_file`, not `YAML.load_file`. JSON/YAML have no native
  date type, so convert date-like strings to `Date` / `Time` before using the
  `date` formatter.

## 8. Validation

```ruby
result = PowerTom.check("template.pptx", data: data)
result.ok?        # no errors
result.errors     # missing fields, syntax errors, useless image paths…
result.warnings   # unused data keys, empty loops, likely text overflow…
result.exit_code  # 0 / 1, for CI
puts result.report
```

`PowerTom.check` reports instead of raising, so it can gate template publication. A missing `DATA`
argument still performs syntax and structure checks, but skips field reconciliation.

## 9. Errors

| Class | When |
| --- | --- |
| `PowerTom::MissingDataError` | A tag or directive points at a field that does not exist (strict mode). |
| `PowerTom::TemplateSyntaxError` | Invalid tag, misplaced directive, broken table block. |
| `PowerTom::InvalidTemplateError` | The file is not a readable `.pptx`. |

Messages include the slide number, shape name (or table cell) and tag, so both engineers and
designers can locate the problem without reading the code.

## 10. Limitations and warnings

| Limitation | Behaviour |
| --- | --- |
| Pie charts are single-series | Binding rejects more than one series because PowerPoint would silently drop the extras; use a doughnut chart for multiple rings. |
| Text tags inside charts are not rendered | Tags inside chart data are left as-is and reported as warnings. |
| Notes are not rendered | Notes are only read for page directives; ordinary tags in notes produce a warning. |
| Pictures default to fill + centre-crop | Append `; mode=contain` to fit the image inside the frame without cropping. In fill mode, an aspect difference above 20% produces a render warning. |
| Tags on masters/layouts never take effect | Only shapes on slides are processed; `PowerTom.check` reports such tags as errors. |

Missing fields are errors in strict mode. Known limitations above degrade with a warning
instead of silently doing nothing.

## 11. Rails integration in 10 minutes

PowerTom needs **no railtie or generator** — the whole Rails-specific surface is one Gemfile
line, one Rakefile line, and three reference files you copy and adapt. (Evaluated and
rejected as a generator in `docs/evaluation-after-1.0.md`: the reference files must be
edited per business anyway, so a generator would only save one copy-paste.)

```ruby
# Gemfile
gem "powertom"
```

```ruby
# Rakefile — CI gate for template publication
require "powertom/tasks"
# bundle exec rake powertom:check TEMPLATE=templates/score_report/v1/template.pptx \
#                          DATA=templates/score_report/v1/sample.toml
```

Checklist:

1. **Store templates** under e.g. `templates/score_report/<version>/template.pptx` with a
   `sample.toml` next to each, and map report type → template path/version/enabled in
   `config/powertom/templates.yml`.
2. **Copy the three reference implementations** from `examples/score_report/` and adapt:
   - `report_data_builder.rb` → `app/services/reports/report_data_builder.rb`
     (analysis result → contract Hash, with readable `DataBuilder::Error` messages);
   - `deck_exporter.rb` → `app/services/reports/deck_exporter.rb`
     (precheck `PowerTom.check` → render → upload, mapping failures to
     `DataError` / `TemplateError` / `UploadError`, each carrying `user_message` for the
     UI and raw `message` for logs);
   - `report_deck_job.rb` → wrap in ActiveJob; `perform` returns an `Outcome`
     (`:succeeded` / `:retry_scheduled` with `retry_in` / `:failed`), so the queue adapter
     just re-enqueues on `retry_scheduled?`. Only upload/render-fallback failures retry
     (backoff 10 s → 300 s cap); data and template errors are terminal.
3. **Configure the asset resolver** in `config/initializers/powertom.rb` — picture fields
   are references, and PowerTom never fetches URLs itself:

   ```ruby
   PowerTom.configure do |config|
     config.asset_resolver = lambda do |ref, _ctx|
       # Security boundary: validate the reference stays inside the controlled
       # directory and the extension is allowlisted — never accept paths from
       # the front end (see docs/dogfooding-plan.md §7).
       path = File.expand_path(ref, Rails.root.join("srv/powertom/assets"))
       unless path.start_with?(Rails.root.join("srv/powertom/assets").to_s) &&
              %w[png jpg jpeg].include?(File.extname(path).delete_prefix(".").downcase)
         raise PowerTom::Error, "picture reference rejected: #{ref.inspect}"
       end
       path
     end
   end
   ```

4. **Entry point + spec**: a controller action that builds the analysis →
   `ReportDeckJob.perform_later(analysis:)`, and a service spec that renders
   `examples/score_report/sample_v2.toml` against the scaffold and asserts page count and
   expanded table rows.

That is the entire integration; everything else is plain Ruby covered by §1–§10 above.
