# Score report · template production spec (v1)

> This is the **construction drawing** handed to the designer; use it together with the Template Guide.
> Goal: a 7-page reporting deck whose tags map one-to-one to the sample data in [examples/score_report/sample.toml](../examples/score_report/sample.toml).
> Acceptance: `powertom:check` reports 0 errors, and a render with the sample data opens in PowerPoint without a "repair" prompt.

---

## 1. Global conventions

| Item | Convention |
| --- | --- |
| Canvas | 16:9 (13.33 × 7.5 in) |
| Fonts | Source Han Sans CN; body ≥ 14 pt, metric values ≥ 32 pt |
| Shape naming | Name tagged text boxes as in this spec (for example `cover-title`); name pictures `powertom:image:<field>` |
| Notes | **Only P4 and P7 carry directives**; leave the notes of other pages empty, with no `{{...}}` at all |
| Styling | A paragraph containing a tag uses one size/colour only; no mixing (otherwise the first run wins after replacement) |
| Tables | No tables in this version; use metric cards / bullet text / chart images |
| Layouts | Cover / content / loop page / closing are enough; do not create new layouts |

### 1.1 What engineering already provides

`examples/score_report/template_scaffold.pptx` is the **7-page structural scaffold** generated from this spec:

- Shape names, tags, notes directives and picture placeholders are all in place; `powertom:lint` currently reports 0 errors;
- Fonts use `PingFang SC` as a stand-in and pictures are grey placeholders, **with no visual design at all**;
- Designers can build visuals on top of it: change colours, fonts, sizes, positions and backgrounds, but do not change shape names or tags;
- Changing them is still safe: `powertom:lint` reports "missing shape / missing tag / tag outside the contract".

Regenerate the scaffold (save the designer version first, it will be overwritten):

```bash
ruby tools/build_score_report_template.rb
```

## 2. Page-by-page specification

> Copy the "placeholder text" straight into the text box; rename shapes in PowerPoint's Selection Pane.
> Suggested lengths follow the overflow warning line (bound value ≥ 20 characters and ≥ 2× the tag length triggers a warning); staying within them avoids false alarms.

### P1 · Cover

| Shape name | Type | Placeholder text | Size | Suggested length |
| --- | --- | --- | --- | --- |
| cover-title | Text box | `{{report_title}}` | 40 bold | ≤ 28 characters, at most 2 lines |
| cover-subtitle | Text box | `{{school_name}} · {{exam_name}}` | 22 | ≤ 12 characters each |
| cover-date | Text box | `{{report_date:date.cn}}` | 16 | Always prints "2026年01月20日" |

- No picture placeholder on the cover; decorative shapes are fine and need no names.
- Leave the notes empty.

### P2 · Overview

The title is the fixed text "Overall performance" with no tag.

The four metric cards share one structure; copy it four times and change only the index:

| Shape name | Type | Placeholder text | Size |
| --- | --- | --- | --- |
| card1-label | Text box | `{{kpis[0].label}}` | 14 |
| card1-value | Text box | `{{kpis[0].value}}` | 40 bold |
| card1-delta | Text box | `{{kpis[0].delta}}` | 16 |
| card2-label … card4-delta | Same as above | `kpis[1]` … `kpis[3]` | Same as above |

| Shape name | Type | Notes |
| --- | --- | --- |
| `powertom:image:overview_chart` | Picture | 16:9 layout recommended; the placeholder should also be 16:9 |

- `delta` may be an empty string (the fourth card is empty); leave one line of height in the text box.
- Leave the notes empty.

### P3 · Class comparison

| Shape name | Type | Placeholder text / name | Notes |
| --- | --- | --- | --- |
| `powertom:image:class_rank_chart` | Picture | — | 16:9; class ranking chart |
| comparison-note | Text box | `{{class_comparison_note}}` | 16 pt, 1–2 lines, ≤ 25 characters |

- Leave the notes empty.

### P4 · Class detail (loop page)

**Notes:**

```text
{{#each classes}}
```

| Shape name | Type | Placeholder text | Size |
| --- | --- | --- | --- |
| class-title | Text box | `{{name}}` | 32 bold |
| class-average | Text box | `{{avg_score}}` | 48 bold |
| class-rank | Text box | `{{rank}}` | 20 |
| class-weak-subject | Text box | Weak subject: `{{weak_subject}}` | 18 |
| class-focus-students | Text box | Focus: `{{focus_students}}` | 18 |
| `powertom:image:chart` | Picture | — | 4:3 recommended |

- This page is the **template page**: with 4 classes in the data it is cloned into 4 pages, each bound to its own values.
- Fixed text (such as "Weak subject:") goes before the tag and survives replacement.
- Write exactly one directive in the notes, with no other tags.

### P5 · Subject analysis

| Shape name | Type | Placeholder text / name | Notes |
| --- | --- | --- | --- |
| `powertom:image:subject_chart` | Picture | — | 16:9; subject double-pass-rate / score-band chart |
| subject-note | Text box | `{{subject_note}}` | 16 pt, ≤ 25 characters |

- Leave the notes empty.

### P6 · Recommendations

Five recommendations in a fixed layout; do not use a table:

| Shape name | Placeholder text | Size |
| --- | --- | --- |
| tip1 | `{{tips[0].text}}` | 18 |
| tip2 | `{{tips[1].text}}` | 18 |
| tip3 | `{{tips[2].text}}` | 18 |
| tip4 | `{{tips[3].text}}` | 18 |
| tip5 | `{{tips[4].text}}` | 18 |

- Each recommendation is ≤ 30 characters; if one line does not fit, allow two and reserve two lines of height.
- The server guarantees exactly 5 items and pads short lists; **do not build the template with 4 or 6 slots**.
- Leave the notes empty.

### P7 · Appendix (conditional page)

**Notes:**

```text
{{#if show_appendix}}
```

| Shape name | Type | Placeholder text / content | Notes |
| --- | --- | --- | --- |
| appendix-data-source | Text box | `{{data_source}}` | 16 pt, ≤ 30 characters |
| appendix-definition | Text box | Fixed text, no tags | Pass line, statistics definitions, etc. |

- When `show_appendix = false` the whole page is removed; the appendix design must stand on its own (it cannot rely on earlier pages).
- Write exactly one directive in the notes.

## 3. Tag ↔ data field summary

| Page | Tag | Data field | Type | Required |
| --- | --- | --- | --- | --- |
| P1 | `{{report_title}}` | report_title | Text | Yes |
| P1 | `{{school_name}}` | school_name | Text | Yes |
| P1 | `{{exam_name}}` | exam_name | Text | Yes |
| P1 | `{{report_date:date.cn}}` | report_date | Date (unquoted in TOML) | Yes |
| P2 | `{{kpis[0..3].label}}` | kpis[].label | Text | Yes (4 items) |
| P2 | `{{kpis[0..3].value}}` | kpis[].value | Text | Yes (4 items) |
| P2 | `{{kpis[0..3].delta}}` | kpis[].delta | Text, may be empty | Yes (4 items) |
| P2 | `powertom:image:overview_chart` | overview_chart | Picture path | Yes |
| P3 | `powertom:image:class_rank_chart` | class_rank_chart | Picture path | Yes |
| P3 | `{{class_comparison_note}}` | class_comparison_note | Text | Yes |
| P4 | `{{#each classes}}` (notes) | classes | Array | Yes (≥1 item) |
| P4 | `{{name}}` | classes[].name | Text | Yes |
| P4 | `{{avg_score}}` | classes[].avg_score | Text | Yes |
| P4 | `{{rank}}` | classes[].rank | Text | Yes |
| P4 | `{{weak_subject}}` | classes[].weak_subject | Text | Yes |
| P4 | `{{focus_students}}` | classes[].focus_students | Text | Yes |
| P4 | `powertom:image:chart` | classes[].chart | Picture path | Yes |
| P5 | `powertom:image:subject_chart` | subject_chart | Picture path | Yes |
| P5 | `{{subject_note}}` | subject_note | Text | Yes |
| P6 | `{{tips[0..4].text}}` | tips[].text | Text | Yes (5 items) |
| P7 | `{{#if show_appendix}}` (notes) | show_appendix | Boolean | Yes |
| P7 | `{{data_source}}` | data_source | Text | Yes |

## 4. Picture placeholders at a glance

| Shape name | Page | Recommended ratio | Placeholder requirement |
| --- | --- | --- | --- |
| `powertom:image:overview_chart` | P2 | 16:9 | Put a 16:9 placeholder directly |
| `powertom:image:class_rank_chart` | P3 | 16:9 | Same as above |
| `powertom:image:chart` | P4 | 4:3 | Put a 4:3 placeholder |
| `powertom:image:subject_chart` | P5 | 16:9 | Same as above |

The replacement rule is fixed: **fill the shape and crop from the centre**. The output inherits the placeholder's ratio, so the placeholder ratio must match the target ratio.

## 5. Prohibitions

| Prohibited | Reason |
| --- | --- |
| Tags on masters / layouts | The engine only processes slide shapes; tags on masters appear as-is on every page |
| Two directives in one page's notes | Validation reports an error immediately |
| Tags inside tables / charts | Not bound in v0.1; tags stay as-is |
| Mixing sizes/colours in a paragraph with a tag | After replacement, everything takes the first run's style |
| Writing `{{tips[3].text}}` with only 4 items | Indices must match the data count; a missing item is an error |
| A misspelled picture placeholder name | It does not error, but it also does not replace (silent failure); double-check after naming |
| Saving with WPS and leaving old notes behind | Old text in notes is kept as design commentary; clear the notes before writing directives |

## 6. Delivery and acceptance

**Deliverables**

1. `template.pptx` (7 pages, named and placeholdered as in this spec; you may save a copy of `template_scaffold.pptx` and restyle it)
2. If fields changed, update `examples/score_report/sample.toml` in sync and notify engineering
3. Put the template version in the file name or the handover note: v1

**Acceptance steps (designer self-check, engineering review)**

```bash
# Step 1: structural self-check — verify shape names / tags / notes directives / picture placeholders page by page
bundle exec rake powertom:lint \
  TEMPLATE=examples/score_report/template.pptx \
  CONTRACT=examples/score_report/template_contract.toml \
  DATA=examples/score_report/sample.toml

# Step 2: data reconciliation (run after the structure passes; passing DATA to lint already runs it)
bundle exec rake powertom:check \
  TEMPLATE=examples/score_report/template.pptx \
  DATA=examples/score_report/sample.toml
```

```ruby
# Render once with the sample data and open it in PowerPoint
ruby -rpowertom -e '
  PowerTom.render("examples/score_report/template.pptx",
                  data: "examples/score_report/sample.toml")
          .save("/tmp/score_report.pptx")
'
```

- [ ] `powertom:lint` structural check reports 0 errors (missing pages / shapes / misspelled tags / directive mismatches / picture placeholders are all reported)
- [ ] `powertom:check` reports 0 errors; confirm every warning one by one (especially overflow warnings)
- [ ] Rendered page count = 1 + 1 + 1 + number of classes + 1 + 1 + 1 (4 classes in the sample data → 10 pages)
- [ ] Opens in real PowerPoint without a "repair" prompt, fonts render correctly
- [ ] Change one piece of copy → re-run lint + check → passes (validates the change workflow)
