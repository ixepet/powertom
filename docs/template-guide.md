# PowerTom template guide (for designers)

> Applies to powertom 0.1.x · 2026-11 · Companion tool: `rake powertom:check`
>
> In one sentence: you build a **normal pptx** in PowerPoint — `{{tags}}` in the body, page directives in the notes. Engineers hand over the data, and the engine produces the finished deck. Layout, fonts, colours and masters stay entirely in your hands; the code never touches the design.

---

## 30-second start

1. Build a normal slide and write the text that data will replace as `{{field_name}}`:

   ```text
   Welcome to {{product_name}}
   Adoption rate this quarter {{kpis[0].value}}
   ```

2. If this page should become "one page per data item", open the **notes** and write one directive:

   ```text
   {{#each scenarios}}
   ```

3. Run validation before delivery:

   ```bash
   rake powertom:check TEMPLATE=template.pptx DATA=sample_data.toml
   ```

   Every `error` must be fixed; a `warning` deserves a look. Once both are clean, the rendered deck opens normally in PowerPoint.

---

## 1. Tags: {{ }} in the body

### 1.1 Syntax

| Form | Meaning | Example data |
| --- | --- | --- |
| `{{field}}` | Top-level field | `title: "Annual summary"` → `{{title}}` |
| `{{array[index].field}}` | Field of the item at an index | `kpis[0].name` → "Adoption rate" |
| `{{a.b.c}}` | Walk down one level at a time | `school.name` |
| `{{field:formatter}}` | Number/date formatting (see 1.3) | `price:currency` → "¥1,234.56" |

- A paragraph may contain several tags: `{{first}} and {{second}} two tags` is valid.
- Spaces around a tag are allowed: `{{ title }}` is equivalent to `{{title}}`.
- Tags can live in **any text box**, including inside grouped shapes (the engine looks inside groups).

### 1.2 Where the style comes from (important)

**A tag inherits the style of the run it is written in. The finished text looks exactly like the placeholder tag.**

Two practical rules:

- Select `{{title}}` as a whole and set size/colour/bold in one go. Do not style "half the characters red and half black".
- **Do not mix styles inside a paragraph that contains a tag.** PowerPoint splits a line into several runs (IME composition, spell check and repeated editing all trigger it), and the engine merges the replaced text into the first run — that is, **for a paragraph with a tag, the finished style follows the first character of the paragraph**; styles on later runs are cleared (the placeholder is kept and the file is not broken). If one paragraph needs two differently styled parts, split it into two paragraphs and give each its own tag.

### 1.3 formatters: numbers and dates

| Tag | Data value | Result |
| --- | --- | --- |
| `{{price:currency}}` | 1234567.891 | ¥1,234,567.89 |
| `{{price:currency.0}}` | 1234.6 | ¥1,235 |
| `{{ratio:percent.1}}` | 0.297 | 29.7% |
| `{{count:number}}` | 12345 | 12,345 |
| `{{day:date}}` | 2026-11-16 | 2026-11-16 |
| `{{day:date.year_month}}` | 2026-11-16 | 2026年11月 |
| `{{day:date.cn}}` | 2026-11-16 | 2026年11月16日 |

- The word after the colon is the formatter name; `.argument` controls the number of decimals or a sub-format.
- currency / percent / number require a number; date requires a date. A wrong type raises an error at render time.
- If you need a new format, ask an engineer to register a custom formatter — the tag does not change.
- If a formatter name is misspelled, `powertom:check` reports an error and lists the available names.

### 1.4 What you can and cannot write

| Allowed | Not allowed (v0 raises an error) |
| --- | --- |
| `{{title}}`, `{{kpis[0].value}}`, `{{a.b.c}}` | Expressions, arithmetic, method calls |
| Several tags in one paragraph | `{{#each x}}` in the **body** (directives only live in notes) |
| Tags inside grouped shapes | Spaces, hyphens or non-ASCII characters in a path |
| formatters: `{{price:currency}}` | A formatter name that does not exist (check lists the available names) |

Table cells can contain tags; if a whole row should expand per array item, see §2.4 Table row loops.

Chart data **is bound** (v0.4.x and later): draw a real chart with placeholder series, and name the chart frame — or its alt text — `powertom:chart:sales`. The renderer replaces the whole data set, keeping your chart type and formatting. See §5 Chart placeholders.

### 1.5 What happens when the data has no such field

- Validation: `powertom:check` reports an error telling you "which slide, which text box, which field is missing".
- Rendering: by default (strict) it raises and stops; when an engineer passes `strict: false`, the spot is filled with blank text and a warning is logged to the terminal.
- So a misspelled field name never produces a silently blank deck — change it with confidence.

---

## 2. Page directives: written in the notes

Directives live only in the **slide notes**: invisible during a presentation, so they never pollute the artwork. **One directive per notes page** — two directives fail validation.

### 2.1 `{{#each array}}`: one template page, many data pages

Notes:

```text
{{#each scenarios}}
```

The body writes the fields of each item directly:

```text
{{headline}}
{{detail}}
```

If `scenarios` has 3 items, this page is cloned into 3 pages, each taking the values of one item; later pages shift down automatically.

- **When the array is empty (0 items), the whole group of pages is removed.** Think ahead when designing: after a group disappears, does the remaining deck still make sense (for example, do the numbers on a table-of-contents page still match)?
- If the loop path is missing from the data or is not an array, rendering raises an error — pages are never silently dropped.

### 2.2 `{{#if field}}`: remove the whole page when falsy

```text
{{#if show_compare}}
```

- `false` or empty (nil) → the page is removed; any other value → the page is kept.
- Ordinary tags on an `#if` page are bound as usual (the scope does not change).
- If the field is falsy in the sample data, check reports "this page will be removed at render time" — that is a reminder, not an error.

### 2.3 Other uses of notes

- **Ordinary text** in notes (design notes, handover comments) is fine; the engine does not render notes and leaves them untouched.
- One caution: do not write design notes in the form `{{xxx}}`, because validation warns "notes contain tags; v0 does not render notes" — that warning means you slipped.
- Colleagues using WPS: WPS leaves its own metadata in notes, and the engine ignores it automatically; still, clear the old notes before writing a `{{#each}}` directive to avoid confusion.

### 2.4 Table row loops: {{array[].field}}

As soon as a cell in a table row contains `{{array[].field}}`, that row is a **template row** and is cloned once per array item:

| Class | Average |
| --- | --- |
| `{{classes[].name}}` | `{{classes[].avg}}` |
| Grade total | `{{total_avg}}` |

- The header row and total row are kept as-is; only the row containing `[]` is replaced by several rows.
- All `[]` tags in the same row must point at the same array; a table allows one loop row.
- When the array is empty (0 items), **the whole row is removed**; header and total remain.
- Tags without `[]` in the loop row (such as the total) still read from page-level data and are not affected by the row data.
- `[]` is only allowed in **table cells**; writing it in a body text box or in notes raises an error.
- A page cannot combine a page-level `#each` with a table row loop (only one level of looping is supported).

Table cells also support formatters, for example `{{classes[].avg:number.1}}`.

> Validation: `powertom:check` reconciles every array item and tells you "which item, which expected path" when a field is missing; an empty array produces "the loop row will be removed".
>
> Two-level nesting is covered in §2.5; dynamic columns (`#grid`) are advanced syntax, designed in [table loop syntax design](table-loop-design.md).

### 2.5 Nested table rows: {{#rows path}}

For two-level structures such as "class → student", declare a **marker row + content row** pair:

| Class | Student | Total |
| --- | --- | --- |
| `{{#rows groups}}` |  |  |
| `{{groups[].name}}` | `{{groups[].avg}}` |  |
| `{{#rows groups[].items}}` |  |  |
| `{{groups[].name}}` | `{{groups[].items[].name}}` | `{{groups[].items[].total}}` |
| Grade total |  | `{{total_count}}` |

- `{{#rows parent_array}}` and `{{#rows parent_array[].child_array}}` must **occupy the first cell alone**; the remaining cells of that row stay empty; the marker row itself is not printed.
- The row **immediately after** a marker row is its content row; the order is fixed: parent marker → parent content → child marker → child content.
- Always write **full paths**: `{{groups[].field}}` in the parent row, `{{groups[].items[].field}}` in the child row; a child row may also reference parent fields.
- **Two levels** only; a third `#rows` marker raises an error. A table cannot mix this with `[]` row loops.
- Empty arrays: if the parent array is empty, parent and child rows are all removed; if one parent item's child array is empty, only that parent content row is kept.
- Merged cells are not allowed in the loop area (marker and content rows); split the table first if you need merging.

> Data shape: `groups` is an array, each item holding another `items` array. `powertom:check` reconciles level by level and reports "parent item N, child item M, expected full path".

### 2.6 Dynamic table columns: {{#grid rows: array cols: array [value: field]}}

When score bands or metric columns change with each exam configuration, use **dynamic columns**. The template fixes two columns: the first holds row titles, the second is the column template.

| Class | Score band |
| --- | --- |
| `{{#grid rows: distribution cols: bands value: counts}}` | `{{col.label}}` |
| `{{row.name}}` | `{{cell}}` |

- The marker goes in the **first cell of the header row**; that cell may keep text (for example "Class {{#grid ...}}"); the marker itself never appears in the output.
- The row immediately below is the **content row template**; the remaining table rows are treated as ordinary rows.
- The second header cell uses `{{col.label}}` (or `{{col.field}}`; use `{{col}}` when column items are scalars).
- In the content row, the first cell writes `{{row.field}}` and data columns write `{{cell}}` (the row/column intersection value).
- Data shape: `distribution` is the row array and `bands` is the column array; with `value: counts` the value is `row.counts[col.key]`, otherwise `row[col.key]`.
- When a column item is a Hash it must have a `key` field, which is the lookup key for that column.
- The table must be a **two-column** template; generated columns inherit the width of the second column.
- Empty `cols` → only the first column remains; empty `rows` → only the header remains.
- `#grid` cannot be mixed with `#rows` or `[]`, does not support merged cells, and cannot be combined with a page-level `#each`.

> `powertom:check` reconciles row by row, column by column and intersection by intersection: errors point at "array item N" or "row R × column C".

### 2.7 Table blocks: {{#rows}} ... {{/rows}} (v0.2.0)

When "one record spans several rows" or you need a three-level structure, use paired blocks:

| Grade | Class | Average |
| --- | --- | --- |
| `{{#rows grades}}` |  |  |
| `{{grades[].name}}` |  |  |
| `{{#rows grades[].classes}}` |  |  |
| `{{grades[].name}}` | `{{grades[].classes[].name}}` | `{{grades[].classes[].avg}}` |
| `{{/rows}}` |  |  |
| `{{/rows}}` |  |  |

- The opening and closing markers each occupy a **whole row** (marker in the first cell, other cells empty) and are not printed.
- **All rows between the two markers** form the row template of one record and are cloned as a whole per array item.
- Up to **3 levels**; a child block path must be written as `parent_array[].child_array`.
- Empty parent/child arrays: the corresponding block is removed entirely.
- Inside a block, `{{row.field}}` refers to the current record; `{{cell}}` / `{{col.*}}` are only used in column bands.
- A column band `{{#cols array [value: field1,field2]}} ... {{/cols}}` may be written in the header row or **directly inside a block** (the declaration row is cloned with the block); the columns between the two markers are template columns.
- Multi-column template example: `{{#cols subjects value: scores,rates}}{{col.label}} | {{col.rate_label}}{{/cols}}`; `{{cell}}` takes `scores` / `rates` in template-column order. With a single field in `value:` all template columns share it; with several, the count must equal the number of template columns.
- Conditional rows (v0.2.2):

  | `{{#rows classes}}` |  |
  | --- | --- |
  | `{{#if classes[].has_data}}` |  |
  | `{{classes[].name}}` | `{{classes[].avg}}` |
  | `{{/if}}` |  |
  | `{{/rows}}` |  |

  - A conditional block may only be written inside a row block, cannot be nested, and cannot contain `#rows` / `#cols` inside.
  - When the condition is falsy, all rows in the block are removed together; the marker rows themselves are not printed.
  - A condition path containing `[]` is resolved in the loop scope; without `[]` it checks the current record first, then page-level data.
  - A missing condition field raises an error and is never silently treated as false.
- Column conditions (v0.2.4):

  | Class | `{{#cols subjects value: scores}}{{#if subjects[].show}}{{col.label}}{{/if}}{{/cols}}` |
  | --- | --- |
  | `{{#rows classes}}` |  |
  | `{{classes[].name}}` | `{{cell}}` |

  - The condition goes in the column band's header cell and wraps the template columns to control; when falsy, the template columns for that column item are removed across the whole table.
  - Conditions are evaluated per column item and may use a column-item field (`show`), a full path (`subjects[].show`) or a page-level field; they cannot reference row fields.
  - No nesting; the condition range must stay inside the column band.
- Merged cells are not supported inside blocks/column bands; cannot be mixed with `#grid` / `[]`.

> Old templates are unaffected: the L1 form "`{{#rows}}` + next row" still works; block mode starts only when `{{/rows}}` or `{{#cols}}` appears.

---

## 3. Placeholder text and text overflow

**With autofit off, overflowing text is not clipped — it spills off the slide.** A tag is only a few characters, while real data is often dozens; this is the most common template failure.

Rules and advice:

- The engine's warning line: **after binding, ≥20 characters and more than 2× the tag length** → `powertom:check` emits a warning.
- Reserve **at least twice the tag length** of space in the text box, or:
  - turn on "shrink text on overflow" (autofit shrink);
  - or ask for shorter field values (agree on data length with the engineer).
- Multi-line copy works the same way: if `{{intro}}` does not fit on one line, give the text box room for several lines.

---

## 4. Picture placeholders

Picture replacement is located by shape name or alt text, with this convention:

```text
shape name = powertom:image:field_name
```

For example, name the cover key visual `powertom:image:cover` and a team page `powertom:image:team_photo`. The value of the matching data field is an **image file path** (absolute paths recommended); PNG and JPEG both work.

- The default replacement strategy is **fill**: fill the shape and crop from the centre. The output is cropped to the proportion of the placeholder image, so **use the target aspect ratio for the placeholder** (put a 16:9 placeholder on a 16:9 layout).
- For images that must not be cropped (logos, diagrams), append `; mode=contain` to the placeholder name: `powertom:image:logo; mode=contain`. The whole image is scaled to fit inside the frame and centred; the margins show whatever is behind the picture (slide background or another shape) — no background fill is synthesised. The aspect-ratio warning applies to `fill` only.
- `#each` cloned pages are supported too: put a placeholder on the loop page and give each data item its own path; every cloned page receives its own picture.
- When a picture field is missing (non-strict mode), the placeholder is kept and a warning is recorded; if the field is present but the **file does not exist**, rendering raises an error.
- `powertom:check` checks picture fields: missing fields, wrong types, missing files and invalid placeholder options (`mode=` other than `fill`/`contain`) all report errors — running it before delivery is the safest bet.

---

## 5. Chart placeholders

Charts are data-bound like pictures, with the same naming convention:

```text
shape name = powertom:chart:field_name
```

Draw a **real chart** in PowerPoint (column, bar, line, area, pie, doughnut, radar, a combo such as column + line, or a scatter / bubble chart) with placeholder series, and name the chart frame `powertom:chart:sales` — or set that text as its alt text. The value of the matching data field is the whole data set:

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

- The renderer replaces the **whole data set**: categories and series are rewritten, while your chart type, layout and series formatting stay. Extra series inherit the last template series' formatting; surplus template series are removed.
- `categories` and every series' `values` must have the same length, and `values` must be numbers. Zero-series data is rejected (it would delete the plot).
- Pie charts plot exactly one series; more than one is rejected (use a doughnut for multiple rings). Doughnut charts accept multiple series as concentric rings.
- `#each` cloned pages are supported: every cloned page binds its own item's data, and each gets an independent chart part.
- Combo charts (a column chart with a line over it is the classic case) are bound too: the data provides **exactly the template's total series count**, in document order — the first series fills the first plot, and so on. A count mismatch is an error that names the template's distribution (e.g. `column×1 + line×1`).
- Scatter and bubble charts take per-series `points` — `{x, y}` pairs (bubble adds `size`) — instead of shared categories. A series-count mismatch is an error.
- Radar charts bind like line charts (same `categories`/`series` shape); your `radarStyle` (filled/markers) and radial-axis scaling are preserved untouched.
- Text tags like `{{x}}` inside a chart are left as-is and reported as warnings.
- When a chart field is missing (non-strict mode), the placeholder chart is kept unchanged and a warning is recorded.
- `powertom:check` reconciles chart fields per page and per `#each` item, and validates the data shape — run it before delivery.

---

## 6. Masters, layouts and covers

- **Do not put tags on masters or layouts.** The engine only processes shapes on slides; `{{x}}` on a master is not replaced and does not raise at render time — it simply appears on every page as-is. `powertom:check` now reports such tags as **errors**, so the problem surfaces before delivery instead of only in the project lint tool.
- Keep the number of layouts small: 3–5 layouts per template is plenty (the HaiMate template had 62 layouts and used only 4). Fewer layouts make cloned pages more predictable.
- **Covers:** if the cover title is baked into a full-bleed background image (text drawn inside the picture), the engine cannot bind it. For a replaceable cover title, place a real text box with `{{cover_title}}`.
- Shapes with the same name on one slide (two "TextBox 8") are allowed, and error messages distinguish them as "TextBox 8#2"; still, give key text boxes meaningful names (such as "pain-point-title") so errors are easy to locate.

---

## 7. Pre-delivery self-check

```bash
# With sample data: field reconciliation + overflow warnings + syntax and structure checks
rake powertom:check TEMPLATE=template.pptx DATA=sample_data.toml

# Without sample data: syntax and structure only
rake powertom:check TEMPLATE=template.pptx
```

- `error`: rendering is impossible until it is fixed (missing fields, directive syntax errors).
- `warning`: does not block, but every one deserves a look — they are almost always signs of an ugly finished deck.
- Errors on the engineer side look like this: `slide 2 shape 'Rounded Rectangle 4': {{workload}} data has no field 'workload'` — use this format to find the spot in the template yourself.

The data file format is TOML (maintained by engineers); style reference:

```toml
title = "2026 annual summary"
show_outlook = true

[[scenarios]]
headline = "Morning reading pack generated automatically"
detail = "Every Sunday at 8 pm"
```

---

## 8. Common pitfalls

| Symptom | Cause | Fix |
| --- | --- | --- |
| A paragraph's style changed in the output | Mixed styles in a paragraph with a tag; text merged into the first run | Do not mix styles in a paragraph containing a tag |
| Text spills off the slide | Data longer than the tag, autofit off | See §3: reserve 2× the space or enable shrink |
| A tag appears as-is in the output | Tag written on a master/layout, or inside a chart | Move it to a slide text box; tags inside charts are reported as warnings |
| `powertom:check` says "only one directive allowed" | Two `{{#...}}` directives in the notes | One per page; put the other on another page |
| Loop page render error "cannot determine the loop count" | The array named by `#each` is missing from the data | Agree on the field name with the engineer |
| A shape name in an error ends with `#2` | Duplicate shape names on the page | Rename them to make errors easy to locate |
| A tag split into pieces is still replaced | The engine merges at paragraph level; nothing to do | Keep typing tags in one go |

---

*This guide evolves together with `powertom:check`: whenever the engine gains a check, the guide is updated. For the engineering design document, see [project-design](project-design.md).*
