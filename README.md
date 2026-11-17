# PowerTom — PowerPoint template engine for Ruby

[![Gem Version](https://img.shields.io/gem/v/powertom)](https://rubygems.org/gems/powertom)

> Designers keep the template in PowerPoint. Engineers pass a Ruby Hash (or a TOML file) and get a finished deck.
> Layout, fonts, colours, masters and theme stay under the designer's control; the code only scans tags, binds data and clones slides.

```ruby
require "powertom"

data = { title: "Final exams", classes: [{ name: "Grade 8 (3)", avg: 82.4 }] }
PowerTom.render("template.pptx", data: data).save("report.pptx")
```

<sub>Not affiliated with Microsoft or TomTom.</sub>

---

## In 30 seconds

```text
Designer                                   Engineer
┌──────────────────────────┐              ┌──────────────────────────┐
│ A plain pptx in          │              │ report.toml              │
│ PowerPoint:              │              │   title = "Final exams"   │
│   body: {{title}}         │  ─────────▶  │   [[classes]]            │
│   notes: {{#each classes}}│              │   name = "Grade 8 (3)"    │
│   picture named           │              │   avg  = 82.4             │
│   powertom:image:cover    │              │                          │
└──────────────────────────┘              └──────────────────────────┘
                    │                                  │
                    └──────────────┬───────────────────┘
                                   ▼
                    PowerTom.render("template.pptx", data: "report.toml")
                                   ▼
                    Finished deck: tags bound, pages cloned/removed,
                    pictures replaced — opens in PowerPoint without repair.
```

## Why another one

Ruby has two ways to produce PPTX today, and neither fits "reuse the design asset":

| Approach | Examples | Problem |
| --- | --- | --- |
| Code-driven generation | `powerpoint`, `ruby_slides` | Layout is hard-coded; changing one font size needs a developer |
| Low-level OOXML library | `ruby_pptx`, `rbpptx` | XML building blocks, no template layer; designers cannot use it directly |

PowerTom fills the middle layer: a **template engine on top of [`ruby_pptx`](https://rubygems.org/gems/ruby_pptx)**, without parsing OOXML itself. Think Carbone / Docxtemplater for Ruby — no Node dependency, no external service, one line in your Gemfile.

## Installation

```ruby
# Gemfile
gem "powertom"
```

Requires Ruby >= 3.3; depends on `ruby_pptx ~> 0.2.0` (read/write) and `tomlrb ~> 3.0` (data files).

## Quick start

**1. The designer builds a template** — just a normal pptx, tags in the body, page directives in the notes:

```text
Body:   Welcome to {{product_name}}
        Adoption rate {{kpis[0].value}}
Notes:  {{#each scenarios}}
```

**2. The engineer prepares the data** — TOML is the default data format:

```toml
# TOML — default data format
product_name = "Student workspace"
show_compare = true

[[kpis]]
name = "Adoption rate"
value = "29.7%"

[[scenarios]]
headline = "Morning reading pack"
detail = "Ready automatically every Sunday"
```

**3. Render:**

```ruby
require "powertom"

# Read the template, bind tags, clone/remove pages, replace images
result = PowerTom.render("templates/report.pptx", data: "data/report.toml")
result.save("out/report.pptx")
result.warnings.each { |w| warn w }   # unused fields, fallback values…
```

Or pass a Hash directly when the data comes from a database or an API:

```ruby
# Same call with in-memory data
result = PowerTom.render("templates/report.pptx", data: {
  product_name: "Student workspace",
  kpis: [{ name: "Adoption rate", value: "29.7%" }],
  scenarios: [{ headline: "Morning reading pack", detail: "Ready every Sunday" }]
})
```

## Template syntax

> Full tag reference: [docs/usage.md](https://github.com/ixepet/powertom/blob/main/docs/usage.md) — data shape, every tag form, table blocks, formatters, images and errors.

| Syntax | Where | Meaning |
| --- | --- | --- |
| `{{title}}` | body | Bind a field |
| `{{kpis[0].value}}` | body | Dot path + array index |
| `{{classes[].name}}` | table cell | Table row loop: clones the row per array item |
| `{{#rows groups}}` | table row | Nested loop marker: declares the parent array (marker row itself is not printed) |
| `{{#rows groups[].items}}` | table row | Nested loop marker: declares the child array |
| `{{#grid rows: .. cols: ..}}` | table header | Dynamic columns: clones the template column per `cols` item |
| `{{#rows groups}} ... {{/rows}}` | table rows | Paired row block: clones all rows between the markers per item (up to 3 levels) |
| `{{#cols subjects}} ... {{/cols}}` | table row | Column band: one or more template columns; may be declared in the header or inside a row block |
| `{{#if groups[].flag}} ... {{/if}}` | table rows | Conditional row block inside a `#rows` block |
| `{{#if subjects[].show}} ... {{/if}}` | table header | Conditional columns inside a `#cols` band |
| `{{price:currency}}` | body | Formatter: ¥1,234.56 |
| `{{ratio:percent.1}}` | body | Formatter: 29.7% |
| `{{day:date.year_month}}` | body | Formatter: 2026年11月 |
| `{{#each scenarios}}` | notes | Clone the page per array item (empty array removes the group) |
| `{{#if show_compare}}` | notes | Remove the page when falsy |

- **Split runs are handled**: if PowerPoint stores `{{title}}` as several runs, the engine merges the paragraph and replaces correctly; the result inherits the first run's style.
- **Nested table rows**: `{{#rows groups}}` occupies a whole row (first cell only), and the next row is the parent content row; `{{#rows groups[].items}}` followed by its own content row adds one nesting level. Two levels maximum; parent and child tags use full paths (`{{groups[].name}}`, `{{groups[].items[].name}}`).
- **Dynamic columns**: put `{{#grid rows: distribution cols: bands value: counts}}` in the header row's first cell. The header row's second cell is the column template (`{{col.label}}`), and the next row is the row template (`{{row.name}}` in the first cell, `{{cell}}` in the data columns). Exactly two columns; `value:` is optional (defaults to `row[col.key]`).
- **Row blocks (v0.2.x)**: `{{#rows groups}} ... {{/rows}}` each occupy a whole row; everything between them is one record template and is cloned per item. Up to 3 nested levels; `{{row.name}}` refers to the current record. A `{{#cols ...}}` band may be declared in the header or directly inside a row block, and may span several template columns; `value: scores,rates` maps one field to each template column (a single field is shared by all). A `{{#if ...}} ... {{/if}}` block inside a row block removes its rows when the condition is falsy; inside a `#cols` band it removes the wrapped columns per column item.
- **Pictures**: name the shape or its alt text `powertom:image:cover` and pass a file path in the data. Replacement always fills the shape and crops from the centre.
- **Charts**: name the chart shape or its alt text `powertom:chart:sales` and pass `{ categories, series, number_format }` in the data; the whole data set is replaced and series formatting is inherited from the template. Bar/column/line/area/pie/doughnut are supported.
- One directive per notes page, maximum.
- TOML dates are written unquoted (`report_date = 2026-01-20`), normalised to Ruby `Date`, and can be formatted with `{{report_date:date.cn}}`.
- Full guide for designers: [docs/template-guide.md](https://github.com/ixepet/powertom/blob/main/docs/template-guide.md).
- Full usage reference: [docs/usage.md](https://github.com/ixepet/powertom/blob/main/docs/usage.md).

Built-in formatters: `currency`, `percent`, `number`, `date` (with `.year_month` / `.cn` / `.short`).
Register your own:

```ruby
# Custom formatter — receives (value, arg) and returns the text to write
PowerTom.register_formatter("rmb") { |value, _arg| "#{value} RMB" }
# Use in a template: {{amount:rmb}}
```

## Template checker

Most tools treat validation as a side effect of logging. PowerTom makes it a first-class step: bad templates fail in CI before anything is rendered.

```bash
bundle exec rake powertom:check TEMPLATE=templates/report.pptx DATA=data/sample.toml
```

Example report:

```text
PowerTom template check — report.pptx
[warning] slide 9 shape '(notes)' {{scenarios}} array 'scenarios' is empty (0 items): the whole page group will be removed at render time
[error  ] slide 2 shape 'Rounded Rectangle 4' {{workload}} data has no field 'workload'
[error  ] slide 5 shape 'powertom:image:banner' {{banner}} picture file does not exist: /tmp/a.png
[warning] data field 'unused_field' is not used by the template
------------------------------------------------
2 error(s), 2 warning(s) (errors block rendering; fix them before calling PowerTom.render)
```

Programmatic API:

```ruby
# Validate without rendering; errors are reported, not raised
result = PowerTom.check("templates/report.pptx", data: "data/sample.toml")
result.ok?          # => false
result.errors       # each entry carries slide_no / shape / label / message
result.report       # the human-readable report shown above
result.exit_code    # 0 or 1 — usable in CI
```

Checks: missing fields (including each item of an `#each` array), unregistered formatters, directive syntax, more than one directive per page, picture fields and missing files, chart data shape, placeholder overflow warnings, unused data fields, leftover tags in notes.

## Error model

| Situation | Behaviour |
| --- | --- |
| Missing field | `PowerTom::MissingDataError` by default, with slide number, shape name and tag; with `strict: false`, fills in blank and records a warning |
| Invalid tag syntax | `PowerTom::TemplateSyntaxError` before rendering |
| Not a valid pptx | `PowerTom::InvalidTemplateError` |
| Missing `#each` path | Always raises — pages are never silently dropped |

Output is **all or nothing**: every check runs before anything is written to disk.

## Limitations

| Limitation | Notes |
| --- | --- |
| Tables support row loops, paired row blocks, nesting and dynamic columns | `{{classes[].name}}` clones one row; `{{#rows ...}} ... {{/rows}}` clones multi-row records (3 levels); `{{#grid ...}}` / `{{#cols ...}}` clone columns; merged cells inside loops are rejected |
| Charts: bar/column/line/area/pie/doughnut, radar, combo and scatter/bubble are data-bound | Name the chart shape `powertom:chart:<field>`; combo/scatter/bubble bind in document order and require exactly the template's series count (scatter/bubble carry `points: [{x, y(, size)}]` per series instead of shared categories); text tags inside charts are left as-is and reported as warnings |
| Notes are not rendered | Notes are only read for page directives; ordinary tags in notes produce a warning |
| Tags on masters/layouts are ignored | Only shapes on slides are processed |
| No PPT → PDF | Use LibreOffice headless |
| `.pptx` only | No legacy 97-2003 binary format |
| TOML or Hash only | No YAML / JSON loader |
| Fixed picture cropping | Always fill the shape and crop from the centre; a warning is emitted when the image aspect differs by more than 20% |

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md) — please do not open public issues for security problems.

- Template tags are pure data binding: the scanner matches `{{...}}` with regex and resolves paths against your data. No code from the template or the data is ever evaluated.
- Picture fields are read as file paths from the server running the render. If your data comes from untrusted input, validate paths on your side (restrict to a controlled directory and an extension allowlist) before passing them to `render` — see [dogfooding plan §7](https://github.com/ixepet/powertom/blob/main/docs/dogfooding-plan.md) for the reference `AssetResolver` design.
- Dependency advisories are checked in CI with `bundler-audit` (`bundle exec bundler-audit check --update` locally).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide; in short:

```bash
bundle install
bundle exec rspec          # full suite (private-fixture examples skip if absent)
bundle exec rubocop       # style
bundle exec yard doc --no-output   # API docs check
bundle exec bundler-audit check --update   # dependency advisories
```

Two fixture tiers cover the end-to-end paths:

- **Committed mini golden sample** (`spec/fixtures/mini/template.pptx`): split-run
  merging, multi-tag paragraphs, page cloning/removal, picture replacement,
  chart data binding and LibreOffice fidelity run in every CI build
  (`spec/powertom/mini_golden_spec.rb`). Regenerate it with
  `bundle exec ruby tools/build_mini_golden.rb` if the template needs new coverage.
- **L3 official validation** (`.github/workflows/l3.yml`): the rendered deck set
  (`tools/build_l3_decks.rb`) is checked with Microsoft's OpenXmlValidator on a
  Windows runner (`tools/openxml_validator`) — the closest machine-checkable
  approximation of PowerPoint's own tolerance. Currently in observation mode.
- **Private golden sample**: the larger real-world deck used by the HaiMate
  examples (`spec/fixtures/hai_mate/template.pptx`) is not committed, because of
  size and ownership; only its structural snapshot `spec/fixtures/hai_mate/manifest.toml` is. With the original template at hand:

```bash
bundle exec rake fixtures:generate TEMPLATE=/path/to/template.pptx OUT=spec/fixtures/hai_mate
bundle exec rake fixtures:check OUT=spec/fixtures/hai_mate
```

Without `template.pptx`, fixture-dependent examples are skipped and the unit suite still runs. The committed scaffolds (`examples/score_report/*.pptx`) and the public fidelity job cover the full render/PDF pipeline without private assets. Fidelity tests need LibreOffice (`soffice`).

## Releasing

Releases are published by pushing a version tag:

```bash
git tag -a v0.3.0 -m "v0.3.0"
git push origin v0.3.0
```

`.github/workflows/release.yml` builds the gem and exchanges the GitHub OIDC token
for RubyGems credentials (trusted publishing), so no manual `gem push` or OTP is
needed. Configure the trusted publisher on RubyGems with workflow `release.yml`
and no environment.

## License

MIT.

## Why PowerTom

The Tom in PowerTom is a dedication — left unexplained, on purpose.
