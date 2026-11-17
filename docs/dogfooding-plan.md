# Dogfooding plan

> Corresponds to design document milestone M4: **ship one real export scenario in a company product, where changing the template needs no developer involvement.**
> Version: v0.1 draft · 2026-11-17 · Status: scenario selection pending confirmation

---

## 1. Acceptance definition (measurable)

Dogfooding is not "a demo that runs once" but "real business keeps using it". All of the following must hold:

| Dimension | Target |
| --- | --- |
| Shipped scenarios | ≥ 1 real business export entry point (with real users) |
| Template change loop | Designer edits template → runs check → publishes a version, **zero code changes, zero releases** |
| Render success rate | ≥ 99.5% (every failure attributable: missing data / template error / environment issue) |
| Latency | Decks up to 20 pages, P95 ≤ 3 s (excluding file upload/download) |
| Error location | 100% of errors carry slide number + shape name + tag, so users/designers can self-diagnose |
| Human effort | Manual page-assembly time for this scenario drops by ≥ 50%, or it moves from "impossible" to "possible" |

## 2. Candidate scenarios

| Scenario | Data availability | Template complexity | Reuse frequency | Main risk | Verdict |
| --- | --- | --- | --- | --- | --- |
| **A. Score analysis report deck** | High: scores, classes and metrics are all structured; the analysis service already produces them | Medium: a reporting deck, structurally identical to the golden sample | High: every exam × every grade | Table/chart binding was not supported; work around it with images | **Recommended for phase 1** |
| B. Classroom analysis review deck | Medium: results exist, but the structure is still evolving | Medium-high: includes video stills and a timeline | Medium: every lesson | Unstable data structure means frequent template changes | Phase 2 |
| C. School monthly work report | Low: mostly unstructured text | Low | Low | Data entered by hand; the engine only helps with layout | Not recommended |

Why A: it satisfies all four criteria at once — naturally structured data, a standard reporting deck template, high output frequency, and a clear pain point in manual page assembly — and the HaiMate product story already includes this scenario (scenario 4: exam score analysis). Dogfooding and the product story align without inventing a need.

### Explicitly out of scope (phase 1)

- Table row-level loops (design document §11 open question #2) — this scenario avoids them with "metric cards + text bullets + chart images"
- Chart data binding (`c:ser` series values) — charts are exported as PNGs by the analysis service; PowerTom only places images
- In-page partial loops (for example, a row of cards generated from an array) — not supported; **repeated elements inside a page can only be addressed by fixed indices**, and looping requires cloning the whole page (see §3.4)

## 3. Recommended scenario: score analysis report export

### 3.1 User journey

```text
Teacher starts "Score analysis" in HaiMate
  → selects exam, classes and analysis dimensions
  → the analysis result is generated (existing capability)
  → clicks "Export report deck"
      → async job: assemble data → PowerTom.render → store in object storage
      → a downloadable / previewable pptx appears in the workspace
  → the teacher presents it directly, or asks the designer to change the template and export again
```

### 3.2 Template page list

> **Calibrated against the real deck on 2026-11-17**: after obtaining the actual "Score Analysis Report (Grade 8 · Final Exam)" deck in use, the page list was revised to 9 pages following the real structure.
> The real deck lives in `spec/fixtures/score_report/` (anonymised: school and student names replaced with placeholders).

| Page | Content | Form | Engine capability |
| --- | --- | --- | --- |
| 1 Cover | Title, subtitle, school, presenter and date | Text | Text tags + `date` |
| 2 Overall performance | 4 metric blocks + summary | Text | Fixed indices `kpis[0..3]` |
| 3 Class average comparison | Scores and names of 8 classes + conclusion | Text layout / chart image | Text tags or `powertom:image:*` |
| 4 Class score detail | Header + 8 classes + total | **Table 10×7** | **Table row loop** `{{classes[].*}}` |
| 5 Subject analysis | 8 subjects + total | **Table 10×6** | **Table row loop** `{{subjects[].*}}` |
| 6 Total-score band distribution | 8 classes × 4 bands | **Table 10×6** | **Table row loop** `{{distribution[].*}}` |
| 7 Students needing attention | 10 students | **Table 11×5** | **Table row loop** `{{students[].*}}` |
| 8 Improvement measures | 3 measures (with owner and timing) | Text | `tips[0..2]` |
| 9 Appendix | Statistical definitions | Text | `{{#if show_appendix}}` |

The early v1 contract avoided table capabilities and designed a 7-page version with "one page per class + chart PNGs" (`template_contract.toml` / `template_scaffold.pptx`).
v2 now follows the real 9-page structure and coexists with v1:

- Contract: `examples/score_report/template_contract_v2.toml`
- Sample data: `examples/score_report/sample_v2.toml`
- Structural scaffold: `examples/score_report/template_scaffold_v2.pptx` (rebuild with `tools/build_score_report_template_v2.rb`)
- Regression: `spec/powertom/score_report_v2_spec.rb` (lint 0/0, 9 pages, row counts of the four tables, appendix toggle)

v1 is kept as the minimal loop and legacy regression; new scenarios use v2.

### 3.3 Data contract (TOML)

The template tags **mirror** the file below one-to-one, and `rake powertom:check` reconciles against it.
See the full v2 sample at [examples/score_report/sample_v2.toml](../examples/score_report/sample_v2.toml) (9 pages / 4 tables); the v1 contract is kept below as the minimal loop example, with fields and page specs in the [template production spec](score-report-template-spec.md).

```toml
# Top-level scalars must come before all [[array tables]] (TOML syntax rule)
report_title = "2026-2027 Grade 8 Final Exam Score Analysis"
school_name = "Haisigu Experimental School"
exam_name = "Final unified exam"
report_date = 2026-01-20          # No quotes; the engine normalises it to a Ruby Date

overview_chart = "/srv/powertom/assets/2026-final/overview.png"
class_rank_chart = "/srv/powertom/assets/2026-final/class-rank.png"
subject_chart = "/srv/powertom/assets/2026-final/subject.png"

class_comparison_note = "The gap between classes 3 and 7 has narrowed to 1.2 points"
subject_note = "Physics experiment questions scored only 61%, the clearest weakness this time"

show_appendix = true
data_source = "Academic affairs system final exam scores (exported 2026-01-15)"

# Overview metric cards (fixed 4)
[[kpis]]
label = "Average score"
value = "82.4"
delta = "+1.8"

[[kpis]]
label = "Distinction rate"
value = "31.2%"
delta = "+2.4pt"

# Class detail: one page per item
[[classes]]
name = "Grade 8 (3)"
avg_score = "85.1"
rank = "2/12"
weak_subject = "Physics"
focus_students = "Li Ming, Wang Xiaoyu"
chart = "/srv/powertom/assets/2026-final/class-3.png"

# Improvement recommendations (fixed 5; the server pads short lists)
[[tips]]
text = "Physics experiment questions concentrate the losses; add two focused training sessions"
```

Conventions:

- **Fields are assembled by the server**, never passing user input straight through; picture paths must stay inside a controlled directory (see §7 Security).
- Fixed-count areas (KPI cards, recommendations) use fixed indices so reviewers can reconcile them by eye; variable-count areas (class pages) use `#each`.
- Date fields pass a `Date`; use `{{report_date:date.cn}}` in the template to control presentation.
- **TOML order**: all top-level scalars go before the first `[[table]]`; keys written after an array table belong to the last array item. The sample data already follows this rule.

### 3.4 Engine capability comparison

| Need | Status | Handling |
| --- | --- | --- |
| Text / number / date formatting | ✅ | Four formatter families |
| One page per class | ✅ | `#each classes` |
| Charts | ⚠️ No data binding | The analysis service produces PNGs; the template places them with `powertom:image:` placeholders |
| Tables | ✅ Rows/columns/blocks/conditions | Single-level `[]`, two-level `#rows`, dynamic columns `#grid`/`#cols`; multi-row records and three-level structures use paired blocks; conditional rows use `{{#if}}...{{/if}}` |
| 5 recommendations in a fixed layout | ✅ | `tips[0..4]` |
| Appendix page shown by a toggle | ✅ | `#if show_appendix` |
| A row of cards generated from an array | ❌ | Not supported; keep the card count fixed and use indices |
| Server fonts | ⚠️ | Install Source Han Sans in the image; otherwise PDF previews and PPT fonts diverge |

Conclusion: the four tables the real deck needs are covered by **table row loops** (see `spec/powertom/table_row_loop_spec.rb` and the real-table regressions). The remaining gaps are "in-page cards generated from an array" and "chart data binding"; both can be worked around in phase 1 with fixed indices / picture placeholders.

### 3.5 System structure

```text
┌────────────────────────────────────────────────────────────┐
│ HaiMate service (Rails)                                    │
│                                                            │
│  ReportDeckJob (async)                                     │
│    ├─ 1. ReportDataBuilder   structured data → Hash         │
│    ├─ 2. AssetResolver       write chart PNGs to the        │
│    │                         controlled directory           │
│    ├─ 3. PowerTom.check      pre-render gate (block/warn)   │
│    ├─ 4. PowerTom.render     template + data → RenderResult │
│    ├─ 5. Upload to storage   return a download URL          │
│    └─ 6. Telemetry          latency/pages/warnings/errors   │
│                                                            │
│  Template registry report_templates: type / version / file  │
│  / status                                                   │
└────────────────────────────────────────────────────────────┘
```

### 3.6 Template governance

- Version template files together with sample data: `templates/score_report/v3/template.pptx` + `sample.toml`.
- **Publish gate**: uploading a new template automatically runs `powertom:check` (see §6) → errors block publishing, warnings inform the designer.
- Production jobs **pin the template version**, so a new release does not affect running exports; failures can roll back to the previous version.
- Whenever the gem or ruby_pptx is upgraded, run the full regression over all published templates + sample data (`check` + render + page-count assertions).

## 4. Phased rollout

| Phase | Content | Output | Done when |
| --- | --- | --- | --- |
| 0 · Template rework | Designer builds the 7-page template per the guide; engineering prepares `sample.toml` | Template v1 + sample data | `powertom:check` reports 0 errors |
| 1 · Local run | Add the gem to Rails, write `ReportDataBuilder` and a script, render locally | One command produces a deck | PowerPoint opens without a repair prompt; content matches the data |
| 2 · Service | Async job, object storage, download entry point, telemetry | Users can click export | Roll out to 1 grade; success rate ≥ 99% |
| 3 · Self-service loop | Template upload page + check gate + version switching | Designers publish themselves | One real template change end-to-end with zero developer involvement |

Each phase is independently acceptable; no need to do it all at once.

## 5. Engineering change list

| Location | Change |
| --- | --- |
| `Gemfile` | `gem "powertom"` (use a local `path:` or a private source first) |
| `app/services/reports/report_data_builder.rb` | Analysis result → v2 contract Hash; fixed counts (4 KPIs / 3 measures / 10 students) and numeric copy are finalised in the builder; dates remain `Date` for the `date` formatter |
| `app/services/reports/deck_exporter.rb` | Wrap `PowerTom.check` + `render` + upload; centralise error mapping |
| `app/jobs/report_deck_job.rb` | Async execution, retry policy, failure notifications |
| `config/powertom/templates.yml` | Report type → template path/version/enabled |
| `app/views/...` | "Export report deck" entry point + download list |
| `spec/services/reports/deck_exporter_spec.rb` | Assert page count, key text and expanded table rows using sample data |
| Operations | Install Source Han Sans in the image; manage and clean `/srv/powertom/assets` |

**Reference implementations are ready**: [examples/score_report/report_data_builder.rb](../examples/score_report/report_data_builder.rb) (`ScoreReport::DataBuilder`) can be copied directly to `app/services/reports/report_data_builder.rb`. It already covers:

- Fixed counts: exactly 4 KPIs; fewer than 3 measures are padded with "None yet", more than 3 **raise an error instead of being silently dropped**; students are capped at 10 with "N in total" noted in the conclusion; empty classes/subjects/distribution refuse to render
- Copy conventions: averages with 1 decimal, ratios as `percent.1`, comparisons as `+1.8 points` / `+2.3pt` / `+6 students`
- Data consistency: the four bands of a class must sum to that class's student count, and the distribution total must equal the sum of class counts; otherwise rendering is refused
- Readable errors: `ScoreReport::DataBuilder::Error` messages are ready for teachers (for example "This analysis is missing class score data")
- End-to-end regression: `spec/powertom/score_report_data_builder_spec.rb` renders the v2 scaffold straight from an analysis result and asserts 9 pages plus the expanded row counts of the four tables

**Export orchestration reference implementation**: [examples/score_report/deck_exporter.rb](../examples/score_report/deck_exporter.rb) (`ScoreReport::DeckExporter`)

```ruby
result = ScoreReport::DeckExporter.new(
  template_path: "templates/score_report/v1/template.pptx",
  uploader: ->(path, key) { oss_client.upload(path, key) },
  template_version: "v1"
).call(data: builder.build)

result.url            # download URL
result.slide_count    # telemetry: output page count
result.duration_ms    # telemetry: latency
result.warnings       # telemetry: template quality trend
```

- Precheck: run `PowerTom.check` with data first; on failure, run check again without data to distinguish template problems from data problems (**never guess the category from error text**)
- Error mapping: `DataError` (teacher-readable, retry after supplying data) / `TemplateError` (contact the designer/ops) / `UploadError` (retryable), all carrying `user_message`, with raw details kept in `message` for logs
- Lifecycle: temporary files cleaned up in `ensure`; the uploader is injected, not tied to a specific object store
- Regression: `spec/powertom/score_report_deck_exporter_spec.rb`, 6 examples (normal export / warnings surfaced / data error / template error / upload failure / precheck disabled)

**Async job reference implementation**: [examples/score_report/report_deck_job.rb](../examples/score_report/report_deck_job.rb) (`ScoreReport::ReportDeckJob`)

```ruby
outcome = job.perform(analysis: payload, attempt: 1)
outcome.succeeded?        # => success; result carries url / slide_count / warnings
outcome.retry_scheduled?  # => re-enqueue after outcome.retry_in seconds, attempt + 1
outcome.failed?           # => terminal; already notified, no more retries
```

- Retry policy: **only upload failures and fallback render failures are retried**, backing off 10 s / 20 s / 40 s (capped at 300 s);
  incomplete data, template exceptions and data-assembly failures produce the same result no matter how often they run, so they terminate immediately to avoid delaying feedback to the teacher
- Notifications: an injected `notifier` receives `:succeeded` / `:retrying` / `:failed`, with `user_message` in the payload, ready for in-app messages or Lark
- Queue-agnostic: `perform` returns a protocol-level Outcome; ActiveJob / Sidekiq adapters just re-enqueue on `retry_scheduled?` + `retry_in`
- Regression: `spec/powertom/score_report_report_deck_job_spec.rb`, 7 examples (success / succeeds after one retry / backoff to the cap / data error / template error / assembly exception / real end-to-end)

## 6. Gates and observability

**Publish gate (template side)**

```bash
# Structural self-check: verify page count / shape names / tags / notes directives / picture placeholders against the contract (switching scenarios only changes the contract)
rake powertom:lint TEMPLATE=templates/score_report/v3/template.pptx \
                   CONTRACT=templates/score_report/v3/template_contract.toml \
                   DATA=templates/score_report/v3/sample.toml

# Data reconciliation: template tags vs sample data
rake powertom:check TEMPLATE=templates/score_report/v3/template.pptx \
                    DATA=templates/score_report/v3/sample.toml
```

- error → blocks publishing; warning → recorded in the template review log (every overflow warning must be confirmed by a human once).
- The template contract is versioned next to the template and sample data (`template_contract.toml`); changing page specs requires changing the contract too, otherwise lint reports "tag outside the contract / missing shape".

**Runtime observability**

| Metric | Purpose |
| --- | --- |
| `render_duration_ms`, `slide_count` | Performance regression and capacity |
| `render_warnings_count` | Template quality trend (persistently high means the template needs work) |
| `render_error{class}` | Separate data / template / environment problems |
| Template version + gem version | Pinpoint "which template + which engine" when something breaks |

## 7. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| **Forged picture paths reading arbitrary server files** | Data is assembled only by the server; `AssetResolver` validates that paths stay inside the controlled directory and uses an extension allowlist (png/jpg); never accept paths from the front end |
| Missing data fields fail the export | Precheck with `PowerTom.check` before rendering; on failure show the teacher a readable message ("This analysis is missing XX data"); never swallow exceptions |
| The designer breaks the template | Check gate + version pinning + one-click rollback; before every release, render with sample data and review it in PowerPoint manually |
| Missing fonts break the layout | Install Source Han Sans in the image; ship a font list with the template; PDF previews depend on the same fonts |
| Long text spills off the slide | Overflow warnings + the designer guide (§3) reserving 2× space; run real data once for manual acceptance |
| LibreOffice is more lenient than PowerPoint | Open every template version once in real PowerPoint (manual checklist in design document §5.5) |
| A ruby_pptx 0.x upgrade breaks compatibility | Pin versions in the Gemfile; run the full published-template regression before upgrading |
| Export latency exceeds the target | Measure a baseline first; warm templates / rate-limit concurrency if needed; optimise only after exceeding the P95 target |

## 8. Acceptance checklist

- [ ] Template v1 passes `powertom:check` (0 errors)
- [ ] Rendering one real term of data produces matching page counts, copy and pictures
- [ ] The output opens in real PowerPoint without a "repair" prompt, with correct fonts
- [ ] The export entry point is rolled out to 1 grade with a success rate ≥ 99.5%
- [ ] A designer completes one template change independently (edit copy + swap picture + adjust layout) → publish → live, with no developer involvement
- [ ] Telemetry can answer: latency distribution, warning trend, error attribution
- [ ] Write a dogfooding retrospective: what the engine lacks, what the template guide must add, whether table row loops are worth building

---

**Pending decision**: should A (score analysis report) be the phase-1 scenario? If the business side has a more urgent export need, re-rank using the four dimensions in §2; the plan structure does not change.
