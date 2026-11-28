# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `check` no longer lets templates through that fail at render time
  (design §7.2 "check says OK ⇒ render succeeds"):
  - A `#grid` table's static rows (e.g. a totals row outside the header and
    content rows) may no longer use `{{row.*}}` / `{{col.*}}` / `{{cell}}` —
    `TableLoop.plan` rejects them with a located error, so `check` and render
    fail identically. Static rows take page fields only.
  - In a block table with a `{{#cols}}` band, `{{col.*}}` tags in static rows
    inside the band's column range are now reconciled per column item (they
    were silently skipped by the main reconciliation loop).
- `PageSurgery` rejects out-of-range slide numbers in the page plan
  (`source: 0`, negative or beyond the slide count) with a located error
  instead of silently cloning the wrong slide via Ruby's negative-index
  wraparound.
- `PageSurgery` validates zip entry names when writing the output package and
  rejects `../` traversal, absolute paths, drive letters and `..` segments
  (zip-slip hardening; rubyzip does not sanitize entry names itself).
- CLI `render` now catches unexpected non-`PowerTom::Error` exceptions and
  exits `1` with a one-line message instead of printing a Ruby backtrace;
  the exit-code contract (0/1/2) holds for internal failures too.
- Row block markers with an index (`{{#rows a[0]}} … {{/rows}}`) are now
  rejected with the same message as single-row markers ("row marker paths do
  not support indices"); previously block mode accepted them while the
  simple form rejected them.
- `PageSurgery` wraps missing package parts (slide/notes rels, presentation
  parts, non-standard notes targets) in a located `PowerTom::Error` instead
  of leaking a bare `KeyError`.
- Docs: `docs/usage.md` §11 documents the 10-minute Rails integration
  checklist (no generator/railtie by design); `docs/project-design.md` §11
  marks the resolved open questions.

### Added

- Standard charts (bar/column, line, area, doughnut, radar) now emit a
  **warning** in both `render` and `check` when the data's series count
  differs from the template's: added series inherit the last template
  series' formatting, and removed series take their formatting with them.
  Rendering is not blocked. Combo, scatter and bubble charts still require
  exactly the template's series count (error), and pie still rejects more
  than one series.

## [0.9.1] - 2026-11-20

### Fixed

- Table block merged-cell validation now follows the documented rule
  (design §9.4.4): a merge is allowed on a static row's fixed columns and is
  rejected only when it intersects a column band or a row block. Previously
  the presence of any column band rejected a merge on *any* row, so a valid
  template with a merged total/footer row outside the band could not pass
  `check` or render. The adapter now reports per-row merged column spans, so
  the decision is precise; callers that do not supply these spans keep the old
  conservative behavior.
- A nested `{{#rows}}` block whose relative path still contains `[]` (for
  example `{{#rows a[].b[].c}}` under `{{#rows a}}`) is now a
  `TemplateSyntaxError` pointing at the nested-block form. Such a path passed
  structure validation but always failed at render with a confusing
  "missing child array 'b[].c'" error, because `PathResolver` only supports
  `field` and `field[index]`, not `field[]`.

## [0.9.0] - 2026-11-19

### Fixed

- `check` no longer raises on malformed templates or sample data. It is a CI
  gate, so it must always return a report instead of a Ruby backtrace:
  - An empty tag (`{{}}` or `{{ }}`) is now a `TemplateSyntaxError` with a
    location instead of a `NoMethodError`. `String#split(":", 2)` returns `[]`
    for an empty string, so the path was `nil` and the first `path.split`
    blew up.
  - A picture, chart or conditional placeholder with an empty field name
    (`powertom:chart:` with nothing after the colon) is reported as an error
    instead of crashing on the empty root.
  - Sample data that is not a Hash (a JSON document with an array at the top
    level, for example) is reported as an error explaining that field
    reconciliation needs top-level fields.
  - A `{{#each}}` directive whose path resolves to `nil` or to a non-array no
    longer crashes the overflow check.
- `check` and render now agree on the chart data shape. Scatter and bubble
  charts carry their own `points` per series and have no `categories`; on a
  `{{#each}}` page `check` used to apply the ordinary chart rules and report
  a missing `categories` for valid data, so a legitimate template could never
  pass CI.
- `check` now reports formatter arguments and value types. `{{d:date.bogus}}`
  and `{{amt:currency}}` bound to a string both fail at render time; they are
  reported at check time now. The argument rules come from `Formatter` itself
  (`register` can declare the arguments it accepts), so check and render
  cannot drift apart.
- `check` reports the conflict between a page-level `{{#each}}` and a table
  row loop on the same page. Render refuses that combination, so check has to
  as well.
- The asset resolver receives the same context in `check` as in render:
  `{slide_no:, shape:, field:}`. A resolver that branches on the field name
  behaved differently between the two.
- A shape name containing an apostrophe no longer duplicates the location
  prefix in check messages.

### Added

- `PowerTom::Formatter.validate` and `PowerTom::Formatter.validate_spec`
  check a formatter specification and a bound value against the rules the
  formatter itself applies.
- `PowerTom.register_formatter` accepts the arguments a formatter supports, so
  a custom formatter can be validated at check time as well.

### Changed

- `ruby_pptx` is pinned to 0.3.1 in the lockfile. Upstream fixed the two
  chart defects PowerTom worked around (negative `c:axId`/`c:crossAx` and
  the illegal `c:smooth` in radar series, Largo/ruby_pptx#3), so the local
  chart normalisation is now gated on the ruby_pptx version and is skipped
  from 0.3.1 on. It stays active for 0.3.0, which still needs it.

### Security

- The intermediate workbook rewrite no longer writes temporary `.xlsx`
  files. It runs entirely in memory and returns bytes: `Tempfile`'s
  finalizer race on Ruby 4.0 (`Tempfile.new` defers `File.unlink` to GC)
  cannot happen any more, and the rewritten workbook is a byte string
  rather than a `StringIO`.
- Intermediate surgery and image files are created with `Tempfile.create`
  (a plain `File` without a finalizer) and are closed and unlinked
  explicitly.
- Rubyzip file handle leaks that locked rendered files on Windows.
  `Zip::Entry#get_inputstream` without a block opens an independent file
  handle that is only released by a GC finalizer, and `Zip::File` holds no
  handle itself, so the `Zip::File.open { }` block cannot close it. Every
  read in the library, the specs and the tooling now passes a block
  (`get_input_stream(&:read)`), so the stream closes as soon as it is
  consumed. `PageSurgery` additionally reads the template through
  `Zip::File.open_buffer` over a `StringIO`: the template handle exists
  only while the template is read, so a rendered template can be deleted or
  renamed right after a render on Windows.

## [0.8.0] - 2026-11-18

### Added

- Restricted aggregators: `{{array[].field:sum}}`, `:avg`, `:min`, `:max` and
  `{{array[]:count}}` over a single-level array with a numeric field. They work
  in page text, static table rows (totals) and `#each` items; nil values are
  skipped, `sum` of an empty array is `0`, and `avg/min/max` of an empty array
  render blank. `check` rejects a missing array or a non-numeric field. There
  are no expressions, sorting or filtering — prepare those in Ruby.
- `PowerTom::AssetResolver`: `PowerTom.configure { |c| c.asset_resolver = ... }`
  or `render(..., asset_resolver:)`. A picture field is a reference; the
  resolver returns a file path or `{data: <binary>, extension: "png"}`, so
  object storage and controlled directories work without PowerTom making
  network calls. `check` validates the resolver result with the same rules.
- `powertom render TEMPLATE --out PATH [--data PATH] [--no-strict]` in the CLI:
  JSON is parsed in the CLI layer, TOML goes through the library's loader.
  Render failures exit `1`; usage or unreadable input exits `2`.
- Loop variables: `{{@index}}` (0-based), `{{@index1}}` (1-based),
  `{{@first}}` and `{{@last}}`. They work in `{{array[].field}}` row loops,
  `#rows` blocks, `#grid` data rows and `{{#each}}` pages, refer to the
  innermost loop, and accept formatters. Header/total rows and pages without a
  loop are located errors in both `check` and render.
- Shape-level conditions: name a shape (or its alt text) `powertom:if:<field>`;
  falsy removes the shape (groups remove their content), truthy keeps it.
  Conditions are evaluated before binding, so hidden shapes do not raise for
  their own tags; `check` validates the field for every `#each` item.
- `powertom` executable (`exe/powertom`, installed by RubyGems) for pipelines
  that do not use Rake. `powertom check TEMPLATE [--data PATH]` prints the same
  report as `rake powertom:check`; `powertom version` and `powertom help`
  complete the surface.

## [0.4.2] - 2026-11-18

### Added

- `lib/powertom/tasks.rb`: the documented `powertom:check` Rake task now ships
  with the gem. Add `require "powertom/tasks"` to a project's Rakefile once and
  `bundle exec rake powertom:check TEMPLATE=... DATA=...` works after
  `gem install` / `bundle install`; the task's usage messages are English, like
  every other user-facing message.
- README FAQ covering the first dogfooding round: the `#each` page context is
  the current item (`{{headline}}`, not `{{scenario.headline}}` — and there is
  no root fallback), how to load the Rake task, and how to pass JSON/YAML as a
  parsed Hash. A warning box next to the syntax table makes the scope rule hard
  to miss.
- L3 official validation layer: a minimal .NET tool
  (`tools/openxml_validator`, OpenXmlValidator / DocumentFormat.OpenXml)
  plus an `L3 OpenXML validation` workflow — ubuntu renders the L3 deck set
  (`tools/build_l3_decks.rb`: every supported chart family, `#each`-cloned
  combo pages, the mini golden render), a windows-latest job runs the
  validator against the decks and the committed mini template. First run
  surfaced two upstream writer defects (negative axis ids, illegal radar
  `c:smooth` — both fixed below); the rerun validates all four decks clean.
  The workflow is a **hard gate**: any schema-level finding fails the build;
  a daily schedule guards against silent upstream drift.
- Picture placeholders support `; mode=contain`, which scales the image to fit
  inside the frame and centres it without cropping. `fill` remains the default.
  Margins show whatever is behind the picture; no background fill is added.
- `PowerTom.check` reports tags on slide masters/layouts as errors. They never
  take effect at render time, so the public validation path no longer leaves
  them silent.

### Changed

- Scatter and bubble binding now rides upstream `Chart#replace_data`:
  ruby_pptx 0.3.0 added `XyChartData` / `BubbleChartData` support (it rewrites
  each series' `c:tx`/`c:xVal`/`c:yVal`/`c:bubbleSize` in schema order and
  keeps the formatting) and raises `Pptx::Error` for a data kind the chart
  cannot hold. The adapter's own XY rewriter is gone; the regenerated workbook
  still receives the theme minor font.
- The `ruby_pptx` floor is now `>= 0.3.0` (was `0.2.0`). On 0.2.x the binding
  layer could only write category-chart data into scatter/bubble series, which
  produces a chart PowerPoint has to repair.
- Releases are published with `rubygems/release-gem` instead of the manual
  `configure-rubygems-credentials` + `gem push` pair. The action runs
  `rake release` and signs the gem with Sigstore, so RubyGems shows
  "Provenance: Built and signed on GitHub Actions" for each version, linking
  the commit and workflow that built it. The Rakefile now loads
  `bundler/gem_tasks`.
- Documented the JSON/YAML adapter pattern in `docs/usage.md`; no built-in
  loader is added. The existing `.toml`-only error no longer says "v0" and
  points to the Hash adapter.

### Fixed

- `powertom:check` existed only in the repository's `rakelib/`, which the
  gemspec never packaged, so the checker command in the README failed with
  "Don't know how to build task" for installed users. The task moved to
  `lib/powertom/tasks.rb` (shipped by `Dir["lib/**/*.rb"]`); `powertom:lint`
  and `fixtures:*` stay repository-only.
- `docs/usage.md` said `#each` labels resolve "against the current item first",
  implying a fallback to the root data. There is no fallback; the wording now
  says so.
- Pie chart binding now rejects data with more than one series. PowerPoint
  draws only the first pie series, so accepting extra series silently lost
  data; `PowerTom.check` and `render` both report a located error instead.
  Doughnut charts still accept multiple series as concentric rings.

## [0.4.1] - 2026-11-17

### Added

- Radar chart binding (§9): radar uses the same `categories`/`series` shape
  as bar/line, and spike scenarios R1–R4 verified that `replace_data`
  preserves `c:radarStyle` (filled/markers), keeps the radial value axis'
  scaling (max=100 survives rebinding data capped at 20), and treats nil
  values as standard gaps — so radar simply joins the supported kinds.
- Scatter and bubble chart binding (§9): each series carries its own
  `points` (`{x, y}` pairs; bubble adds `size`) instead of shared
  categories. Upstream `replace_data` cannot rebind XY series
  (`SeriesFragments` never emits `c:xVal`/`c:yVal`, and rebinding a scatter
  with `ChartData` produces a schema-invalid `c:ser`), so the adapter
  rewrites `c:tx/c:xVal/c:yVal/c:bubbleSize` itself through the same
  remove/insert macros upstream uses, and regenerates the embedded workbook
  via `XyChartData#xlsx_blob`. The series count must equal the template's
  series count; `categories` in scatter data is an explicit error.
- Combo chart binding (§9): a combo placeholder (e.g. column + line with a
  secondary axis) binds its series in document order through the same
  `categories`/`series` data shape as single-plot charts. The data must
  provide exactly the template's total series count — a mismatch raises a
  located error naming the template's distribution (e.g.
  `column×1 + line×1`), both in `PowerTom.render` and `PowerTom.check`.

### Fixed

- Chart schema normalization on save (L3 first-run findings): upstream chart
  writers use negative axis id constants (`VAL_AX_ID = "-2112772216"`) where
  OOXML requires unsigned ints, and `RadarChartWriter` writes a `c:smooth`
  into radar series although that element does not exist in the radar ser
  schema. LibreOffice and PowerPoint tolerate both, but `OpenXmlValidator`
  rejects them (6 findings per axis chart, 2 per radar series). Saving now
  normalizes every chart in the package: negative `c:axId`/`c:crossAx`
  values are converted to their absolute value (references stay self-consistent, and within the int32 bound) and illegal
  radar `c:smooth` nodes are removed.
- Chart binding font consistency: the regenerated embedded workbook had no
  `xl/styles.xml` (except for date categories, where the base font was
  hardcoded to Calibri), so PowerPoint's "Edit Data" fell back to the local
  Excel default font instead of the presentation's theme font. The binding
  layer now writes a minimal styles part whose base font is the theme's
  minor font — matching what PowerPoint itself produces — and patches the
  font in place when a styles part already exists. Chart text fonts were
  never affected (the chart XML's `c:txPr` nodes are untouched by binding).
- Unsupported chart kinds (scatter, bubble, radar, unknown) are rejected
  with a located error in `PowerTom.render` and reported as errors by
  `PowerTom.check` (independent of sample data), instead of silently
  binding wrong-shaped data into a non-`c:val` plot. Verified by
  `tools/chart_binding_spike2.rb`: upstream `replace_data` cannot rebind
  XY/bubble series (`SeriesFragments` never emits `c:xVal`/`c:yVal`).

## [0.4.0] - 2026-11-17

### Added

- OOXML structural lint (`tools/ooxml_lint.rb`, L1): detects dangling
  `[Content_Types].xml` overrides, dangling relationship targets, duplicate
  zip entries and broken `sldId` references — the defects PowerPoint repairs
  on open while LibreOffice silently tolerates them. CLI exits non-zero on
  findings; the mini golden, page-surgery and chart-binding specs assert
  their outputs lint clean, so the structural layer runs in CI.
- Design notes: `docs/chart-binding-design.md` and the
  `tools/chart_binding_spike.rb` feasibility spike.

### Fixed

- The mini golden fixture was silently matched by the gitignore pattern
  meant for the private golden sample (`spec/fixtures/*/template.pptx`),
  so `mini_golden_spec` skipped its whole group on CI — the public
  fidelity acceptance never actually ran outside local machines. The
  fixture is now committed (whitelisted in `.gitignore`), and the mini
  golden, page-surgery and chart-binding specs genuinely execute in CI.
- `PageSurgery` no longer declares a `notesSlide` content-type override for
  output pages whose source page has no notes. The surgery output is now a
  valid OPC package on its own (final rendered decks were already clean —
  ruby_pptx regenerates `[Content_Types].xml` on save — but the intermediate
  file used to carry dangling overrides).

### Changed

- Chart data binding (§5.4): name a chart shape or its alt text
  `powertom:chart:<field>` and pass `{ categories, series, number_format }`;
  the whole data set is replaced through ruby_pptx `Chart#replace_data`
  (series add/remove, formatting inheritance, embedded workbook
  regeneration). Supported for bar / column / line / area / pie / doughnut.
- Cloned (`#each`) chart pages each get their own chart part: parts shared
  across slides are deep-copied per bound page, so clones never overwrite
  each other's data.
- `PowerTom.check` reconciles chart fields (including per-`#each`-item
  checks) and validates the chart data shape.
- The mini golden sample now includes a chart page (categories 3→2
  reduction, two series) exercised in the public CI fidelity job.

## [0.3.2] - 2026-11-17

> Bugfix-only release cut from `release/v0.3.2`; main carries the same fixes
> inside 0.4.0.

### Added

- OOXML structural lint (`tools/ooxml_lint.rb`, L1): detects dangling
  `[Content_Types].xml` overrides, dangling relationship targets, duplicate
  zip entries and broken `sldId` references — the defects PowerPoint repairs
  on open while LibreOffice silently tolerates them. CLI exits non-zero on
  findings; the mini golden and page-surgery specs assert their outputs lint
  clean, so the structural layer runs in CI.

### Fixed

- `PageSurgery` no longer declares a `notesSlide` content-type override for
  output pages whose source page has no notes. The surgery output is now a
  valid OPC package on its own (final rendered decks were already clean —
  ruby_pptx regenerates `[Content_Types].xml` on save — but the intermediate
  file used to carry dangling overrides).

## [0.3.1] - 2026-11-17

### Added

- Committed mini golden sample (`spec/fixtures/mini/template.pptx`, generated by
  `tools/build_mini_golden.rb`): split-run merging, multi-tag paragraphs, page
  cloning/removal, picture replacement and LibreOffice fidelity now run in the
  public CI fidelity job without the private golden sample.

## [0.3.0] - 2026-11-17

### Changed

- **Breaking:** all user-facing runtime messages are now English. This covers
  `PowerTom::Error` hierarchy messages, render warnings, `PowerTom.check` reports,
  and the `powertom:lint` structure report. Code comments remain unchanged.
- The `.cn` date formatter still emits Chinese dates (`2026年11月16日`) by design.
- The `ruby_pptx` dependency constraint is relaxed from `~> 0.2.0` to
  `>= 0.2.0, < 1.0`, so applications pick up upstream 0.x fixes directly.
  Compatibility with new 0.x releases is guarded by the adapter layer and CI.

### Fixed

- `RenderResult` now owns its intermediate surgery file through a `Tempfile`, so
  abandoned results are cleaned up by the finalizer; `#close` releases it
  explicitly. Failed renders also clean up before re-raising.
- `page_scopes` now uses a default block instead of a shared Hash instance,
  preventing accidental cross-page mutation of the default scope.
- `condition_truthy?` and `column_condition_truthy?` reuse `truthy?`.

### Added

- Trusted publishing workflow (`.github/workflows/release.yml`): pushing a `v*`
  tag publishes the gem through RubyGems OIDC, without manual `gem push` or OTP.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, GitHub issue templates and a pull
  request template.
- Dependency vulnerability auditing via `bundler-audit`, run in the CI lint job
  (`bundle exec bundler-audit check --update` locally).

## [0.2.7] - 2026-11-17

### Changed

- All documentation is now English-only: the designer guide, template production spec,
  dogfooding plan, table loop design and project design document were translated from Chinese.
- Documentation files renamed to English kebab-case names:
  `docs/template-guide.md`, `docs/score-report-template-spec.md`, `docs/dogfooding-plan.md`,
  `docs/table-loop-design.md`, `docs/project-design.md`.
- `README.md` is English-only again; the French translation was removed and remaining French
  comments were translated.
- The gemspec description is English-only.
- Cross-links between the README and the guides point at the new file names.

### Note

- 0.2.6 was tagged and never published to RubyGems; 0.2.7 supersedes it.

## [0.2.6] - 2026-11-17

### Added

- RuboCop and YARD in the development toolchain, plus CI jobs for style and docs.
- A public fidelity CI job that runs the LibreOffice checks on committed scaffolds,
  so contributors can run the full pipeline without private fixtures.
- Render warnings when a chart contains template tags (charts are not data-bound).
- Render warnings when an image aspect ratio differs significantly from its placeholder
  (replacement always fills and centre-crops).

### Changed

- Added this changelog and `changelog_uri` metadata to the gemspec.
- Public API entry points now carry YARD tags.
- Documented fixture policy: private gold samples stay local; committed scaffolds are public.

## [0.2.5] - 2026-11-17

### Changed

- Gemspec metadata now explicitly includes `homepage_uri`, `source_code_uri`,
  `bug_tracker_uri` and `documentation_uri`.
- `README.md` and `LICENSE` are included in both `spec.files` and `spec.extra_rdoc_files`.
- English README comments translated from French.
- Engineering design document moved to `docs/project-design.md`.

## [0.2.4] - 2026-11-17

### Added

- Column-level `{{#if path}} ... {{/if}}` inside `#cols` bands: the wrapped template
  columns are removed per column item, across all rows.
- English, French and Chinese description on the RubyGems page.

## [0.2.3] - 2026-11-17

### Added

- `docs/usage.md`, a full tag and data reference.
- RubyGems version badge and a 5-line quick-start example in the README.

## [0.2.2] - 2026-11-17

### Added

- Paired row blocks `{{#rows path}} ... {{/rows}}` with multi-row records, up to 3 levels.
- Multi-column column bands `{{#cols path value: a,b}} ... {{/cols}}`.
- Row-level `{{#if path}} ... {{/if}}` conditional blocks.
- Backward compatible with L0/L1/L2 table loops.

## [0.1.0] - 2026-11-17

### Added

- Initial release: text tags, split-run handling, formatters, page directives,
  image placeholders, single-level table row loops, `PowerTom.check`, TOML data.
