# PowerTom usage reference

> Companion to the README: the data shape, every tag form, and the rules the engine enforces.
> Designer-facing guide: [template-guide.md](template-guide.md).

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
- Labels on an `#each` page resolve against the current item first.
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

## 5. Images

- Name a picture shape (or its alt text) `powertom:image:cover`.
- Put the image file path in the data under the matching field.
- Replacement always fills the shape and crops from the centre; use a placeholder with the target aspect ratio.
- A missing field keeps the placeholder (`strict: false`); a path that does not exist is an error.

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
- `categories` and every series' `values` must have the same length; `values`
  must be numbers; zero-series data is rejected.
- Supported chart types: bar / column / line / area / pie / doughnut.
  Scatter, bubble and combo charts are not bound yet; text tags inside charts
  are left as-is and reported as warnings.
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
| Charts: bar/column/line/area/pie/doughnut only | Charts named `powertom:chart:<field>` are data-bound; scatter / bubble / combo charts and text tags inside charts are left untouched (text tags are reported as warnings). |
| Notes are not rendered | Notes are only read for page directives; ordinary tags in notes produce a warning. |
| Image replacement always fills and centre-crops | When the image aspect differs from the placeholder by more than 20%, a render warning explains that the image will be cropped. Use a placeholder with the target aspect ratio. |
| Tags on masters/layouts are ignored | Only shapes on slides are processed. |

Missing fields are errors in strict mode. Known limitations above degrade with a warning
instead of silently doing nothing.
