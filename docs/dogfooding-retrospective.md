# Dogfooding retrospective — score analysis report export (v2, 9-page deck)

> Date: 2026-11-23 · Gem under test: PowerTom 0.9.1 (`main` @ 0cbec34) · Scenario:
> `examples/score_report/` (template scaffold v2 + contract v2 + sample v2) · Plan:
> [dogfooding-plan.md](dogfooding-plan.md) §8 acceptance checklist.

This run covers everything that can be verified locally against the committed
scaffolds. Items that need the real product environment (rollout to one grade,
designer self-service publishing) are listed as open at the end.

## 1. Acceptance checklist status

| §8 item | Status | Evidence |
| --- | --- | --- |
| Template passes `powertom:check` (0 errors) | ✅ | v1 and v2 scaffolds: `0 error(s), 0 warning(s)`, exit 0 |
| Structure lint against the contract | ✅ | `rake powertom:lint` v2: structure 0/0, data reconciliation 0/0 |
| Rendering real-shaped data produces matching pages/rows/copy | ✅ | 12/12 assertions (below) |
| Output opens without a repair prompt | ⚠️ local proxy only | L1 OOXML lint clean; LibreOffice renders both decks to 9-page PDFs. L3 OpenXmlValidator runs in CI (Windows); **real PowerPoint open is still a manual step** |
| Export entry rolled out to 1 grade, ≥ 99.5% success | ⬜ needs production | pipeline verified locally with mocked uploader (below) |
| Designer changes template with zero developer involvement | ⬜ needs production | check/lint/CLI gates all runnable without code; not yet exercised by a non-engineer |
| Telemetry answers latency / warnings / error attribution | ✅ (schema proven) | `render_duration_ms`, `slide_count`, `warnings`, error class mapping all emitted and asserted below |
| Retrospective written | ✅ | this document |

## 2. What was run

Environment: Ruby 4.0.9 (rbenv), `bundle exec`, gem loaded from the repo.

```bash
# publish gate (template side)
bundle exec rake powertom:check TEMPLATE=examples/score_report/template_scaffold_v2.pptx \
                               DATA=examples/score_report/sample_v2.toml     # 0/0, exit 0
bundle exec rake powertom:lint  TEMPLATE=examples/score_report/template_scaffold_v2.pptx \
                                CONTRACT=examples/score_report/template_contract_v2.toml \
                                DATA=examples/score_report/sample_v2.toml      # 0/0
bundle exec exe/powertom check examples/score_report/template_scaffold_v2.pptx \
                              --data examples/score_report/sample_v2.toml     # 0/0, exit 0

# end-to-end render (analysis → DataBuilder → render)
# scenario A: PowerTomDev::ScoreReportAnalysis.full → 9 slides, tables 4/4/4/3 rows
#             (header + 2 classes + total / header + 2 students), cover date
#             "2026年01月20日", KPI card "83.4 / +1.8 分", show_appendix=false → 8 slides
# scenario B: sample_v2.toml → 9 slides, tables 10/10/10/11, total 486, last student 学生J
# both: warnings == [], render 44–57 ms (P95 target ≤ 3 s for ≤ 20 pages)

# L1 structural lint on rendered outputs
bundle exec ruby tools/ooxml_lint.rb <3 rendered decks>   # structure OK ×3

# LibreOffice render smoke test
soffice --headless --convert-to pdf <2 rendered decks>     # both → 9-page PDF
```

Full suite after the changes below: **394 examples, 0 failures**.

## 3. Pipeline (DeckExporter + ReportDeckJob) — 12/12 assertions

- Normal export: URL key `score-report/YYYYMMDD/<uuid>.pptx`, `slide_count` 9,
  `duration_ms` integer, `warnings` passed through, temp file removed after upload.
- Error mapping (all carry `user_message` for the teacher + raw detail for logs):
  - missing data field → `DataError` "本次分析数据不完整，暂时无法生成报告", uploader never called;
  - broken template → `TemplateError` "报告模板异常，请联系管理员";
  - upload failure → `UploadError` "报告已生成但保存失败，请稍后重试".
- Job retry policy: upload failure → `retry_scheduled` with `retry_in` 10 s → 20 s,
  success on attempt 3; notification sequence `[:retrying, :retrying, :succeeded]`;
  backoff capped at 300 s; data/template/assembly failures are terminal on first
  attempt with a readable `user_message`.

## 4. Finding fixed during this run

**Unreadable template file was not mapped to `TemplateError`.**
`PowerTom.check` raises `PowerTom::InvalidTemplateError` when the file is missing
or not a valid pptx (documented contract — 0.9.0's "check never crashes" fix covers
malformed *content*, not an unopenable *package*). `DeckExporter#preflight!` did
not rescue it, so a deployment mistake (wrong path, corrupted upload) surfaced as
a raw `InvalidTemplateError` instead of the teacher-facing "报告模板异常".

Fix in `examples/score_report/deck_exporter.rb`: `preflight!` now rescues
`PowerTom::InvalidTemplateError` and re-raises as `TemplateError`. Covered by a new
example in `spec/powertom/score_report_deck_exporter_spec.rb` (7 examples, 0 failures).

## 5. Engine gaps observed (candidates for the backlog)

1. **No warning when a standard chart's series count differs from the template**
   (added series silently inherit the last series' formatting) — already noted as
   optional in `docs/feature-direction.md` §1 decision 3.
2. **Doughnut ring-count variability** is accepted silently; open question in
   `feature-direction.md` §1.
3. `check` vs `render` asymmetry: an unopenable template raises from `check` but is
   reported as a located error only for content problems. Callers that want a pure
   report must rescue `InvalidTemplateError` themselves (now done in the reference
   exporter); consider documenting this in `docs/usage.md` §check.
4. i18n and CLI `--json` / `lint` remain deferred by design (feature-direction
   decision table) — no new evidence from this scenario.

## 6. Suggestions for the template guide

- Add a "publish checklist" box for designers: `rake powertom:lint` (structure +
  contract) **then** `rake powertom:check` (data reconciliation), both must be 0
  errors before publishing a template version.
- Document that page 9-style conditional appendix pages (`{{#if show_appendix}}`
  in notes) change the deck's page count — downstream consumers (previews,
  page-count assertions) must not hard-code 9.
- Remind that table row counts are data-driven: assertions on row counts belong in
  the *exporter spec with sample data*, not in the template contract.

## 7. Telemetry contract proven here

| Metric | Source | Sample value |
| --- | --- | --- |
| `render_duration_ms` | `DeckExporter::Result#duration_ms` (monotonic, includes check+render+write) | 44–70 ms |
| `slide_count` | `Result#slide_count` | 9 (8 with appendix off) |
| `render_warnings_count` | `Result#warnings` | 0 |
| `render_error{class}` | `DataError` / `TemplateError` / `UploadError` / other | all three mapped paths exercised |
| template + gem version | `Result#template_version` + `PowerTom::VERSION` | "v2" / 0.9.1 |

## 8. Open — needs the real product environment

- [ ] Roll the export entry point out to 1 grade; success rate ≥ 99.5% with every
      failure attributed (data / template / environment).
- [ ] One designer completes a template change end-to-end (edit copy + swap
      picture + adjust layout → lint/check → publish) with no developer involvement.
- [ ] Open every published template version once in real PowerPoint (no repair
      prompt, correct fonts — Source Han Sans installed in the image).
- [ ] Wire the §7 telemetry into dashboards; alert on warning trend and error classes.
- [ ] After the first real month: update this file with latency distribution,
      warning trend, and the "is it worth it" verdict (manual assembly time −50%).
