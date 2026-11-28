<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.png">
    <img src="docs/assets/logo-light.png" alt="PowerTom — Ruby PowerPoint template engine" width="360">
  </picture>
</p>

# PowerTom — PowerPoint template engine for Ruby

[![Gem Version](https://img.shields.io/gem/v/powertom)](https://rubygems.org/gems/powertom)
[![Docs](https://img.shields.io/badge/docs-ixepet.github.io%2Fpowertom-blue)](https://ixepet.github.io/powertom/) · documentation site (usage reference, designer guide, API docs)

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
                    pictures and charts bound — opens in PowerPoint
                    without repair.
```

## Why another one

Ruby has two ways to produce PPTX today, and neither fits "reuse the design asset":

| Approach | Examples | Problem |
| --- | --- | --- |
| Code-driven generation | `powerpoint`, `ruby_slides` | Layout is hard-coded; changing one font size needs a developer |
| Low-level OOXML library | `ruby_pptx`, `rbpptx` | XML building blocks, no template layer; designers cannot use it directly |

PowerTom fills the middle layer: a **template engine on top of [`ruby_pptx`](https://rubygems.org/gems/ruby_pptx)**, without parsing OOXML itself. Think Carbone / Docxtemplater for Ruby — no Node dependency, no external service, one line in your Gemfile.

## Built for enterprise delivery

Most "generate a deck" tooling is a library. PowerTom is built for the case
where the deck is a **deliverable that has to survive contact with an
organisation**: a template library with named owners, data that arrives from
several upstream systems, and a CI pipeline that has to say *no* before a
broken template reaches a customer.

**The template is a governed asset, not a file in a repo.** Designers work in
PowerPoint; nobody has to open XML or write code to change a layout. What the
template *is* — a set of pages, masters and placeholders — stays under the
design team's control, while the data layer stays under engineering's. When
the two disagree, `check` reports the difference instead of silently
producing a deck with blank cells.

**A broken template fails in CI, not in front of a stakeholder.** `check` is a
first-class gate, not a debugging aid:

```bash
bundle exec rake powertom:check TEMPLATE=templates/report.pptx DATA=samples/q4.toml
# exit 0  ok
# exit 1  the template would fail to render — errors are reported, not raised
# exit 2  usage error, unreadable template or data
```

Every error carries the slide number, the shape name and the original tag, so
the person who can fix it is the person who owns the template. `check` never
raises on a malformed template — it returns a report, because a CI gate that
crashes tells you far less than one that lists eleven problems.

**Data contracts are enforced where the data enters the system.** Fields the
template does not use are reported; fields the template needs but the data
lacks are errors; a formatter given a string where it needs a number is an
error. Because `check` applies the *same* rules the renderer does, a template
that passes the gate renders — the two cannot drift apart.

**Assets stay behind your own boundary.** A picture field is a *reference*.
With an asset resolver, your application decides what a reference means —
object storage, a controlled directory, a permissioned endpoint — and
PowerTom performs no network I/O of its own. See
[Asset resolution](#template-syntax) below.

**Output is all or nothing.** Every check runs before anything is written to
disk. A render either produces the whole deck or leaves no file behind, so a
failed job cannot leave a half-written report on a shared drive.

**Nothing from the template or the data is ever executed.** Tags are matched
with a regex and resolved against your data; there is no `eval`, no template
expression language, and no code path where a document can run code.
Dependencies are audited in CI with `bundler-audit`, and the gem is published
with Sigstore provenance showing which commit and workflow built it.

**It fits the way Ruby teams already ship.** One gem, no Node runtime, no
service to operate, no template format to learn — the `.pptx` stays a
`.pptx`, editable by the people who own the design.

## Installation

```ruby
# Gemfile
gem "powertom"
```

Requires Ruby >= 3.3; depends on `ruby_pptx >= 0.3.0, < 1.0` (read/write) and `tomlrb ~> 3.0` (data files).

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

# Read the template, bind tags, clone/remove pages, replace images and charts
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
| `{{@index}}` / `{{@index1}}` | loop | 0-based / 1-based index of the current item |
| `{{@first}}` / `{{@last}}` | loop | `true` on the first / last item |
| `{{classes[].avg:sum}}` | body / total row | Aggregate: `sum`, `avg`, `min`, `max`; `{{classes[]:count}}` counts items |

> [!WARNING]
> **Scope inside `{{#each}}`.** An `{{#each scenarios}}` page renders once per
> item, and every tag on that page resolves against the **item** — there is no
> fallback to the root data. Write `{{headline}}`, not `{{scenario.headline}}`:
> a prefix that does not exist on the item raises `MissingDataError`. A value
> that lives only at the top level is not visible on that page; put it on a
> separate page or include it in each item. Loop variables (`{{@index}}`,
> `{{@index1}}`, `{{@first}}`, `{{@last}}`) are the way to number items.

- **Split runs are handled**: if PowerPoint stores `{{title}}` as several runs, the engine merges the paragraph and replaces correctly; the result inherits the first run's style.
- **Nested table rows**: `{{#rows groups}}` occupies a whole row (first cell only), and the next row is the parent content row; `{{#rows groups[].items}}` followed by its own content row adds one nesting level. Two levels maximum; parent and child tags use full paths (`{{groups[].name}}`, `{{groups[].items[].name}}`).
- **Dynamic columns**: put `{{#grid rows: distribution cols: bands value: counts}}` in the header row's first cell. The header row's second cell is the column template (`{{col.label}}`), and the next row is the row template (`{{row.name}}` in the first cell, `{{cell}}` in the data columns). Exactly two columns; `value:` is optional (defaults to `row[col.key]`).
- **Row blocks (v0.2.x)**: `{{#rows groups}} ... {{/rows}}` each occupy a whole row; everything between them is one record template and is cloned per item. Up to 3 nested levels; `{{row.name}}` refers to the current record. A `{{#cols ...}}` band may be declared in the header or directly inside a row block, and may span several template columns; `value: scores,rates` maps one field to each template column (a single field is shared by all). A `{{#if ...}} ... {{/if}}` block inside a row block removes its rows when the condition is falsy; inside a `#cols` band it removes the wrapped columns per column item.
- **Pictures**: name the shape or its alt text `powertom:image:cover` and pass a file path in the data. Replacement fills the shape and crops from the centre by default; append `; mode=contain` (`powertom:image:logo; mode=contain`) to fit the whole image inside the frame instead.
- **Conditional shapes**: name the shape or its alt text `powertom:if:<field>`. When the value is falsy the shape is removed at render time; `PowerTom.check` verifies the field exists. On an `{{#each}}` page the field comes from the current item.
- **Loop variables**: `{{@index}}` (0-based), `{{@index1}}` (1-based), `{{@first}}` and `{{@last}}` are available in `#each` pages, `{{array[].field}}` rows, `#rows` blocks and `#grid` data rows. They refer to the innermost loop; using them on a header/total row or outside a loop is a located error in `check` and at render time.
- **Aggregates**: `{{classes[].avg:sum}}` (also `avg`, `min`, `max`) and `{{classes[]:count}}` work in body text, table total rows and `#each` items. Single-level arrays with numeric fields only; nil values are skipped; no expressions, sorting or filtering.
- **Asset resolution**: picture fields are references. By default they are local paths; `PowerTom.configure { |c| c.asset_resolver = ... }` (or `render(..., asset_resolver:)`) lets an application return a path or `{data:, extension:}` from object storage. PowerTom never fetches URLs itself, so the resolver stays the security boundary.
- **Charts**: name the chart shape or its alt text `powertom:chart:sales` and pass `{ categories, series, number_format }` in the data; the whole data set is replaced and series formatting is inherited from the template. On standard charts (bar/column, line, area, doughnut, radar) a series count that differs from the template renders fine but emits a warning — added series inherit the last template series' formatting, removed series lose theirs. Supported: bar/column, line, area, pie (exactly one series), doughnut and **radar** (including the filled variant — `radarStyle` and radial-axis scaling such as a fixed maximum are preserved). Combo charts and scatter/bubble charts use a different contract — see Limitations.
- One directive per notes page, maximum.
- TOML dates are written unquoted (`report_date = 2026-01-20`), normalised to Ruby `Date`, and can be formatted with `{{report_date:date.cn}}`.
- Full guide for designers: [docs/template-guide.md](https://github.com/ixepet/powertom/blob/main/docs/template-guide.md).
- Full usage reference: [docs/usage.md](https://github.com/ixepet/powertom/blob/main/docs/usage.md).
- Windows behaviour and verification: [docs/windows-support.md](https://github.com/ixepet/powertom/blob/main/docs/windows-support.md).

Built-in formatters: `currency`, `percent`, `number`, `date` (with `.year_month` / `.cn` / `.short`).
Register your own:

```ruby
# Custom formatter — receives (value, arg) and returns the text to write
PowerTom.register_formatter("rmb") { |value, _arg| "#{value} RMB" }
# Use in a template: {{amount:rmb}}
```

A formatter can declare which arguments it accepts, so `check` can reject a
wrong argument before the render:

```ruby
PowerTom.register_formatter("rmb", args: ["upper", "lower"]) { |value, arg| ... }
# {{amount:rmb.upper}} passes; {{amount:rmb.bogus}} is reported by check
```

## Template checker

Most tools treat validation as a side effect of logging. PowerTom makes it a first-class step: bad templates fail in CI before anything is rendered.

Add the task to your project's Rakefile once (the gem ships it):

```ruby
require "powertom/tasks"
```

Then run:

```bash
bundle exec rake powertom:check TEMPLATE=templates/report.pptx DATA=data/sample.toml
```

The Rake task reads TOML (pass a parsed Hash from Ruby for other formats); the
CLI below also accepts JSON.

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

Checks: missing fields (including each item of an `#each` array), unregistered formatters, invalid formatter arguments and value types (e.g. `{{d:date.bogus}}`, or `{{amt:currency}}` bound to a string), directive syntax, more than one directive per page, picture fields and placeholder options, asset resolver results, chart kind and data shape, conditional fields, loop-variable scope, aggregate arrays and numeric fields, tags on masters/layouts (they never take effect), placeholder overflow warnings, unused data fields, leftover tags in notes.

`check` **never raises on a malformed template** — it returns a report. A CI
gate that crashes tells you far less than one that lists eleven problems, so
empty tags, placeholders with a missing field name, sample data that is not a
Hash and `{{#each}}` directives pointing at a missing or non-array value are
all reported as errors with their location.

`check` and the renderer apply the *same* rules, so a template that passes the
gate renders. Scatter and bubble charts on a `{{#each}}` page, for example, are
validated against their own `points` shape rather than the ordinary
`categories` shape.

## CLI

The gem ships a `powertom` executable for pipelines that do not use Rake:

```bash
powertom check templates/report.pptx --data data/sample.toml
powertom render templates/report.pptx --data data/values.json --out out/report.pptx
powertom version
```

`check` prints the same human-readable report as the Rake task; both `check`
and `render` accept `.toml` or `.json` sample data. `render` writes the deck to
`--out`; `--no-strict` fills missing fields with blanks and warns. Exit codes
are the stable contract:

| Code | Meaning |
| --- | --- |
| 0 | success (warnings allowed) |
| 1 | template/data errors that block rendering |
| 2 | usage error, unreadable template, data or asset |

## Error model

| Situation | Behaviour |
| --- | --- |
| Missing field | `PowerTom::MissingDataError` by default, with slide number, shape name and tag; with `strict: false`, fills in blank and records a warning |
| Invalid tag syntax | `PowerTom::TemplateSyntaxError` before rendering |
| Loop variable outside a loop | `PowerTom::TemplateSyntaxError` — `@index` on a header row or a page without a loop is a template bug, not missing data |
| Aggregate misuse | `PowerTom::MissingDataError` when the array is missing or an item's field is not numeric |
| Not a valid pptx | `PowerTom::InvalidTemplateError` |
| Asset resolver failure | `PowerTom::Error` when the resolver returns `nil` or an unsupported value |
| Missing `#each` path | Always raises — pages are never silently dropped |
| Placeholder without a field name | `PowerTom::Error` — `powertom:chart:` with nothing after the colon is a template bug |
| Page `#each` combined with a table row loop | `PowerTom::Error` — only one loop level is supported |

Output is **all or nothing**: every check runs before anything is written to disk.

`PowerTom.check` is the exception to the "raises" rule: it never raises on a
malformed template, it reports. A CI gate that crashes tells you far less than
one that lists eleven problems.

## Limitations

| Limitation | Notes |
| --- | --- |
| Tables support row loops, paired row blocks, nesting and dynamic columns | `{{classes[].name}}` clones one row; `{{#rows ...}} ... {{/rows}}` clones multi-row records (3 levels); `{{#grid ...}}` / `{{#cols ...}}` clone columns; merged cells inside loops are rejected |
| Charts: bar/column/line/area/pie/doughnut, radar, combo and scatter/bubble are data-bound | Name the chart shape `powertom:chart:<field>`; pie charts accept exactly one series (use doughnut for multiple rings); standard charts allow add/remove series but warn when the count differs from the template (added series inherit the last series' formatting); combo/scatter/bubble bind in document order and require exactly the template's series count (scatter/bubble carry `points: [{x, y(, size)}]` per series instead of shared categories); text tags inside charts are left as-is and reported as warnings |
| Notes are not rendered | Notes are only read for page directives; ordinary tags in notes produce a warning |
| Tags on masters/layouts are rejected | Only shapes on slides are processed; `PowerTom.check` reports these tags as errors because they never take effect |
| No PPT → PDF | Use LibreOffice headless |
| `.pptx` only | No legacy 97-2003 binary format |
| TOML or Hash only | The library takes a Hash or a `.toml` path; the CLI also accepts `.json`. No YAML loader (see the FAQ below) |
| Pictures default to fill + centre-crop | Append `; mode=contain` to `powertom:image:<field>` to fit the image inside the frame without cropping; the aspect-ratio warning only applies to fill mode |
| Loop variables refer to the innermost loop | In nested `#rows` blocks there is no syntax for the parent index; compute it in the data if needed |
| Aggregates are deliberately narrow | One array level, one numeric field, no expressions, sorting or rounding; complex math belongs in Ruby |
| Shape conditions use page scope | Evaluated per page / `#each` item before binding; they cannot reference table-row fields, and deleting a group removes its children |

## FAQ

**Why does `{{scenario.headline}}` fail inside `{{#each scenarios}}`?**

The page context becomes the current item, as in Handlebars or Liquid. Every
tag on that page resolves against the item, with no fallback to the root
document. Write `{{headline}}`; a prefix that does not exist on the item raises
`MissingDataError`. Values that exist only at the top level need their own page
or must be repeated in each item.

**`rake powertom:check` says "Don't know how to build task".**

The task has to be loaded by your project. Add this once to the Rakefile of the
app that uses the gem (0.4.2+):

```ruby
require "powertom/tasks"
```

Then `bundle exec rake powertom:check TEMPLATE=... DATA=...` works. The
repository-only `powertom:lint` and `fixtures:*` tasks are not part of the gem.
If the project does not use Rake at all, run `powertom check TEMPLATE
--data DATA` instead (0.8.0+).

**Can I pass JSON or YAML instead of TOML?**

The built-in loader accepts a `Hash` or a `.toml` path. Parse other formats
yourself and pass the resulting Hash — string and symbol keys both work:

```ruby
require "json"
PowerTom.render("template.pptx", data: JSON.parse(File.read("data.json")))

require "yaml"
PowerTom.render("template.pptx",
                data: YAML.safe_load_file("data.yaml",
                                          permitted_classes: [Date, Time],
                                          aliases: true))
```

JSON/YAML have no native date type: convert date-like strings to `Date` or
`Time` yourself if a `date` formatter is used.

**How do I put a total under a table?**

Use an aggregate in the static total row: `{{classes[].avg:sum}}` (also `avg`,
`min`, `max`) or `{{classes[]:count}}`. The loop row keeps using
`{{classes[].name}}`; `check` verifies the array exists and the field is
numeric. Aggregates also work in body text and on `#each` items.

**Can pictures come from S3 or HTTP?**

Yes, through an asset resolver — PowerTom does not make network calls itself:

```ruby
PowerTom.configure do |config|
  config.asset_resolver = lambda do |ref, context|
    # ref is the data value; return a path or raw bytes
    { data: MyStore.fetch(ref), extension: "png" }
  end
end
```

A resolver receives `(ref, {slide_no:, shape:, field:})` and returns a file path
or `{data: <binary String>, extension: "<ext>"}`. `PowerTom.check` validates the
resolver result with the same rules; returning `nil` is an error. Per-render
override: `PowerTom.render(..., asset_resolver: ->(ref, ctx) { ... })`.

## Windows and file locking

PowerTom renders on Windows without leaving files open. This is not a
freebie — the underlying zip library leaks handles by default, and on Windows
an open handle means the file cannot be deleted, renamed or overwritten.

**What the problem looked like.** `rubyzip` 3.x keeps no handle in `Zip::File`
itself, but every `Zip::InputStream` it hands out opens an independent file
handle through `::File.open`. `get_input_stream` without a block returns that
stream and never closes it, so the handle survives until the GC finalizer
runs. The result: after a render, the template and the output deck stayed
locked, and the test suite reported it as 19–36 randomly distributed
`Errno::EACCES` failures that moved with the random seed.

**What PowerTom does about it.**

- Every read passes a block, so the stream closes as soon as it is consumed.
- `PageSurgery` reads the template through `Zip::File.open_buffer` over a
  `StringIO`. The template handle exists only while the template is read, so a
  rendered template can be deleted or renamed right after a render.
- The intermediate workbook rewrite runs entirely in memory and returns bytes.
  `Tempfile`'s finalizer race on Ruby 4.0 (`Tempfile.new` defers `File.unlink`
  to GC) cannot happen.
- Intermediate surgery and image files use `Tempfile.create` (a plain `File`
  without a finalizer) and are closed and unlinked explicitly.

```ruby
result = PowerTom.render("template.pptx", data: data)
result.save("out.pptx")
result.close          # releases the intermediate surgery file

File.delete("template.pptx")   # works on Windows
File.delete("out.pptx")        # works on Windows
```

**How it is verified.** The suite runs clean on Ruby 4.0.9 across four random
seeds. Beyond the unit tests, the rendered decks are opened with **Microsoft
PowerPoint 16** through COM automation and checked on two signals: no repair
dialogue, and `Presentation.Saved == -1` (PowerPoint did not modify the file,
which means it considers the structure valid). The exported slides are then
inspected visually — chart series, axis values and CJK text rendering included.
The L3 job (`.github/workflows/l3.yml`) additionally runs Microsoft's
OpenXmlValidator on a Windows runner as a hard gate, so schema-level
violations fail the build rather than reaching a user's PowerPoint.

## Security

To report a vulnerability, see [SECURITY.md](https://github.com/ixepet/powertom/blob/main/SECURITY.md) — please do not open public issues for security problems.

- Template tags are pure data binding: the scanner matches `{{...}}` with regex and resolves paths against your data. No code from the template or the data is ever evaluated.
- Picture fields are references. Without an `asset_resolver`, they are read as local paths from the server running the render — validate untrusted input on your side (a controlled directory and an extension allowlist) before passing it to `render`. With an `asset_resolver`, the application's resolver is the trust boundary and PowerTom performs no network I/O itself; see the FAQ above.
- Dependency advisories are checked in CI with `bundler-audit` (`bundle exec bundler-audit check --update` locally).

## Development

See [CONTRIBUTING.md](https://github.com/ixepet/powertom/blob/main/CONTRIBUTING.md) for the full guide; in short:

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
  approximation of PowerPoint's own tolerance. A **hard gate**: any
  schema-level finding fails the build. Also runs on a daily schedule to catch
  upstream drift.
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

`.github/workflows/release.yml` runs `rubygems/release-gem` (trusted publishing
over the GitHub OIDC token), so no manual `gem push` or OTP is needed. The
action also signs the gem with Sigstore, so each RubyGems version shows
"Provenance: Built and signed on GitHub Actions" with the commit and workflow
that built it. Configure the trusted publisher on RubyGems with workflow
`release.yml` and no environment.

## License

MIT.

## Why PowerTom

The Tom in PowerTom is a dedication — left unexplained, on purpose.
