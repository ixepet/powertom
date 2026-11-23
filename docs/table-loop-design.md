# Table loop syntax design (nested rows / dynamic columns)

> Status: **L0 / L1 / L2 / v0.2.4 block syntax are all implemented** · Updated 2026-11-17
> Implemented: L0 simple row loops (`{{array[].field}}`), L1 two-level nesting (`{{#rows path}}`),
> L2 dynamic columns (`{{#grid rows: .. cols: ..}}`), v0.2.0 paired row blocks,
> v0.2.1 multi-column template bands, v0.2.2 row-level `#if`, v0.2.4 column-level `#if`.
> This document also states explicitly what is **not** being done for now.

---

## 1. Current state: what simple row loops can do

```text
| Class               | Average           |
| {{classes[].name}}  | {{classes[].avg}} |
| Grade total         | {{total_avg}}     |
```

- One marker row → cloned per array item; header/total rows are kept; an empty array removes the row
- One loop row per table; cannot be combined with a page-level `#each`
- Limitations:
  1. **No nesting** — a two-level structure such as "class → student" cannot be expressed
  2. **Columns are static** — score bands and metric columns cannot adapt to each exam configuration

## 2. Goals and principles

| Goal | Description |
| --- | --- |
| Backwards compatible | The existing `[]` syntax stays valid; new syntax is a superset |
| Explicit scope | When parent and child fields appear in one cell, write the full path instead of guessing |
| Single responsibility | Row loops handle rows, column loops handle columns; they can combine but stay semantically separate |
| Fail loudly | Misplaced markers, exceeding the level limit, merged-cell conflicts — always an error, never a silent fallback |
| Not a general reporting engine | No grouping aggregation, sorting or formulas; those belong to the data side |

## 3. Option comparison

| Option | Approach | Pros | Cons |
| --- | --- | --- | --- |
| A. Extend `[]` depth | `{{groups[].items[].name}}` expresses nesting through the path itself | No new syntax | Row boundaries cannot be inferred from a path; what distinguishes "parent row" from "child row" is unclear |
| B. Block directives (recommended) | Declare levels with dedicated marker rows `{{#rows ...}}` | Clear row boundaries, best readability | One more kind of "marker row" for designers to learn |
| C. Grid directive | A corner cell `{{#grid rows: .. cols: ..}}` declares two dimensions at once | Most natural for dynamic columns | Heaviest syntax; verbose for simple cases |

**Conclusion**: keep `[]` for simple cases (sugar over option A); use B / C for nesting and dynamic columns, and only implement them when a real need appears.

## 4. Recommended syntax

### 4.1 L0: `[]` simple row loops (implemented, unchanged)

```text
| {{classes[].name}} | {{classes[].avg}} |
```

### 4.2 L1: `#rows` two-level nested rows (implemented)

> Implementation: `lib/powertom/table_loop.rb` (planning and structural validation),
> `adapter/ruby_pptx_adapter.rb#expand_table_rows_nested` (row cloning),
> `binder.rb` (`row_scopes` scopes), `validator.rb` (level-by-level reconciliation).
> Regression: `spec/powertom/table_row_loop_nested_spec.rb` (20 examples).

**Data**

```toml
[[groups]]
name = "Grade 8 (1)"
avg = "81.5"

[[groups.items]]
name = "Student A"
total = 398

[[groups.items]]
name = "Student B"
total = 405
```

**Template**

```text
| {{#rows groups}}          |                  |   ← parent row marker (marker alone in the cell)
| {{groups[].name}}         | {{groups[].avg}} |   ← parent row content
| {{#rows groups[].items}}  |                  |   ← child row marker
| {{groups[].items[].name}} | {{groups[].items[].total}} |   ← child row content
```

**Semantics**

1. `{{#rows path}}` must **occupy a whole row**, in the first column; the row itself is not printed.
2. The row immediately after it is its content row; tags in the content row use **full paths** (`groups[].name`), with no implicit `..` parent reference.
3. A child marker `{{#rows groups[].items}}` may only appear after the parent content row; render order:
   ```
   for group in groups:
     render parent content row(group)
     for item in group.items:
       render child content row(group, item)
   ```
4. **Two levels** only; a third-level marker raises `stacking depth exceeds 2 levels`.
5. Empty arrays: an empty parent removes both parent and child rows; an empty child keeps only the parent content row.
6. Still cannot be combined with a page-level `#each`.

### 4.3 L2: `#grid` dynamic columns (implemented)

> Implementation: `table_loop.rb` (argument parsing and scope validation),
> `adapter/ruby_pptx_adapter.rb#expand_grid_columns` (gridCol + per-row cell cloning),
> `grid_value.rb` (column keys / intersection values, shared by render and check), `binder.rb` (row/col/cell scopes).
> Regression: `spec/powertom/table_grid_spec.rb` (26 examples).

**Data**

```toml
[[distribution]]
name = "Grade 8 (1)"
[distribution.counts]
excellent = 17
good = 25
pass = 15
fail = 4

[[distribution]]
name = "Grade 8 (2)"
[distribution.counts]
excellent = 15
good = 25
pass = 14
fail = 7

[[bands]]
key = "excellent"
label = "≥629 excellent"

[[bands]]
key = "good"
label = "555–628"
```

**Template**

```text
| {{#grid rows: distribution cols: bands value: counts}} | {{col.label}} | {{col.label}} | … |
| {{row.name}}                                          | {{cell}}      | {{cell}}      | … |
```

**Semantics**

1. `{{#grid ...}}` goes in the **first cell of the header row**; it declares:
   - `rows`: the row array (required)
   - `cols`: the column array (required)
   - `value`: the field to read from each row (optional; defaults to `row[col.key]`)
2. Header cells other than the first are the **column template**: columns are cloned per `cols` item, and each cell may use:
   - `{{col.label}}` / `{{col.key}}` / `{{col}}` (when column items are scalars)
3. The content row is the **row template**: rows are cloned per `rows` item, and cells may use:
   - `{{row.field}}` row data
   - `{{cell}}` the current row/column intersection value; with `value:` it equals `row[value][col.key]`, otherwise `row[col.key]`
4. Column cloning covers the header cell + the corresponding cell in every row + the `a:gridCol` width. Columns inherit the template column width.
5. Empty `cols`: keep the first column (row titles) and drop the duplicate columns; empty `rows`: drop the content row and keep the header.
6. **Merged cells are not supported** (`gridSpan` / `vMerge`): detection raises an error asking the designer to split the table first.

### 4.4 Combination

Combining `#grid` with `#rows` is a two-dimensional Cartesian product with complex semantics and few real needs: **not supported in v1**; both markers in one table raise an error.

## 5. Scope and path rules

| Location | Available variables | Resolution rule |
| --- | --- | --- |
| `[]` simple row | Row item fields + page data | Paths with `[]` are relative to the row item; without `[]` they read page data |
| `#rows` parent row | `groups[].field` | The first segment must be a declared array |
| `#rows` child row | `groups[].items[].field` | The prefix must match the parent/child markers; no skipping levels |
| `#grid` header | `col.*` | Column item scope |
| `#grid` content row | `row.*` / `cell` | Row item scope + intersection value |
| `#grid` static row (totals etc., outside header/content) | page fields only | `row.*` / `col.*` / `cell` are rejected at plan time with a located error, so `check` and render fail identically |

Error examples:

- `{{#rows groups}}` not in the first cell / sharing a cell with text → `row marker must occupy the first cell alone`
- `{{name}}` in a content row (missing the `groups[]` prefix) → `table row tag does not match the loop array`
- Third-level marker → `stacking depth exceeds 2 levels`
- Merged cells participating in a loop → `loop area contains merged cells; split them first`

## 6. Implementation sketch (for scheduling reference)

| Step | Change |
| --- | --- |
| 1 | Upgrade `TableLoop` to a parser: recognise marker rows, build the level tree; `[]` uses the same tree (degraded to a single level) |
| 2 | Row expansion: reuse the existing `Element#import` cloning; add two-phase "parent row + child row" expansion |
| 3 | Column expansion: clone `a:gridCol` + per-row `a:tc`; detect and reject `gridSpan`/`vMerge` |
| 4 | Binding: extend Binder scopes to the `row/col/cell` slots, with a fixed path-resolution priority |
| 5 | Validation: `check` reconciles two-level arrays item by item; dynamic columns verify that `cols` and `row[value]` keys match |
| 6 | Compatibility: `[]` stays as-is; `#rows/#grid` are new syntax with zero changes to old templates |

Risk: column cloning changes the cell count of every row, so `a:tblGrid` must stay in sync with each `a:tr`'s `h` and the `graphicFrame`'s `ext`; this needs a set of freeze-point tests (see the existing `table_row_loop_spec`).

## 7. Explicitly not done

- Three or more levels of nesting
- Merged cells inside loop areas
- Group aggregation (per-class subtotals, cross-row sums) — compute them on the data side
- Column sorting/filtering/conditional formatting
- Partial card loops inside a page (another gap unrelated to tables)

## 8. Suggested rollout pace

| Phase | Trigger | Deliverable |
| --- | --- | --- |
| v2.1 nested rows ✅ 2026-11-17 | Two-level "class → student" structure | `#rows` two levels + structural validation + 20 regression examples |
| v2.2 dynamic columns ✅ 2026-11-17 | "Score bands / metric columns change per exam" | `#grid` + column cloning + 26 regression examples |
| Deferred | Three-level nesting / merged cells / aggregation | Stay out of scope to avoid over-engineering |

> L0/L1/L2 are all available. Dynamic columns support **two-column templates** only (row titles in the first column + a data template in the second);
> column widths inherit the template column; for more complex headers, split into several tables.
> Three-level nesting, merged cells in loop areas and row/column aggregation remain out of scope.

---

# 9. Next generation: a general table block DSL (v0.2 design draft)

> Goal: converge the three specialised L0/L1/L2 syntaxes into one **composable block syntax**
> covering arbitrary levels, multi-row records, two-dimensional row/column matrices, conditional rows and multi-column templates, while keeping L0/L1/L2 compatible.
>
> **v0.2.0 / v0.2.1 / v0.2.2 / v0.2.4 are implemented**: paired `#rows` blocks (multi-row records, 3 levels) + multi-column template `#cols` bands
> (may be written inside blocks) + row-level `#if` + column-level `#if`. Regression: `spec/powertom/table_blocks_spec.rb` (59 examples).

## 9.1 Four hard limits of the current syntax

| Limit | Current state | Real-world need |
| --- | --- | --- |
| At most two levels of row nesting | `#rows` is fixed at parent/child | Grade → class → student; subject → topic → question |
| A record can only occupy one row | The row after a marker is the only content row | A class row + a note row, two rows as one record |
| Dynamic columns have only one template column | `#grid` is fixed to "first column + second column" | Each subject needs "average + score rate", two columns |
| Row and column loops are mutually exclusive | `#grid` cannot combine with `#rows` | A two-dimensional class × subject score matrix |

Two more implicit limits: row-level conditions (hiding one record) and static merged cells (title rows) cannot be expressed in a loop table.

## 9.2 Goals and non-goals

| Goal | Description |
| --- | --- |
| Orthogonal | Row loops handle "vertical repetition", column loops "horizontal repetition"; usable independently or together |
| Block-oriented | `{{#rows}} ... {{/rows}}` wraps "all rows of one record" instead of relying on a "next row" convention |
| Bounded | Default nesting cap 3; exceeding it is an error; no unbounded recursion |
| Explicit scope | Keep full paths (`groups[].items[].name`); no implicit `..` or relative paths |
| Fail loudly | Pairing, levels, band extents and merged-cell conflicts always raise |
| Backwards compatible | L0/L1/L2 templates change not at all; the new syntax is a superset |
| Not a general reporting engine | Group subtotals, sorting, aggregation and formulas stay on the data side |

**Explicitly out of scope**: pivot-style dynamic row/column intersections, generating `colspan/rowspan` from data, merged cells inside loop areas,
combining page-level `#each` with table loops, unlimited nesting.

## 9.3 Option comparison

| Option | Approach | Pros | Cons |
| --- | --- | --- | --- |
| A. Keep adding parameters | Add `span: 2` to `#rows`, `cols: 2` to `#grid` | Small change | Combinatorial explosion; `#grid + #rows` still unsolved |
| B. Single-cell JSON spec | Write `{{#table {...}}}` in the first cell | Most expressive | Unreadable for designers; hard to locate errors |
| C. Declare table structure in notes | Put the table structure in the notes | Clean body | Structure separated from layout; hard to review |
| D. Block DSL (recommended) | `#rows/#if` own whole rows, `#cols` owns a column band | Visible structure, composable, incremental | Needs new pairing and scope rules |

Choose D: the designer can see "this block repeats" directly on the layout, matching the mental model of the existing L1.

## 9.4 Recommended syntax

### 9.4.1 The three blocks

**Row block** (replaces L1's "next row" convention, supports multi-row records):

```text
| {{#rows grades}}                    |                    |
| {{grades[].name}}                   |                    |
| {{#rows grades[].classes}}          |                    |
| {{grades[].classes[].name}}         | {{...avg}}         |   ← class record row 1
| {{grades[].classes[].note}}         |                    |   ← class record row 2
| {{/rows}}                           |                    |
| {{/rows}}                           |                    |
```

- `{{#rows path}}` / `{{/rows}}` must **occupy a whole row** (marker in the first cell, other cells empty) and are not printed.
- **All rows between the two markers** form the row template of one record, cloned as a whole per array item.
- Nesting is allowed: `{{#rows grades[].classes}}` inside the parent block, up to 3 levels.
- Empty array: the whole block is removed (as today).

**Conditional block** (row-level show/hide):

```text
| {{#rows classes}}            |                |
| {{#if classes[].has_data}}   |                |
| {{classes[].name}}           | {{...avg}}     |
| {{/if}}                      |                |
| {{/rows}}                    |                |
```

- `{{#if path}} ... {{/if}}` also occupies whole rows; when falsy, all rows in the block are removed.
- A conditional block may **only be written inside a row block**, cannot nest, and cannot contain loop or column-band markers (for "loop inside a record", put the condition in the outer block).
- A path with `[]` is resolved in the current loop scope; without `[]` it checks the current row item first, then page data (handy for page-level switches such as `#if show_note`).
- A missing condition field is an error (never silently false).

**Column band** (multi-column dynamic templates):

```text
| Class | {{#cols subjects value: scores}}{{col.label}}{{/cols}} |
```

- `{{#cols path [value: field1,field2]}}` / `{{/cols}}` must be written in the first and last data columns of the same row; the columns between the markers are the column template (possibly several), cloned as a whole per column item.
- **A column band may be written in any row**: the header row, or any content row inside a row block.
  - Written inside a row block, the declaration row is cloned with the block, which suits "each group carries its own header";
  - A band describes the table's **columns** and applies to the whole table, not just the block it lives in.
- The first column outside the markers is a fixed column; `#cols` requires at least one fixed column (otherwise the table is all dynamic columns and cannot keep its structure when the array is empty).
- Header cells keep using `{{col.label}}` / `{{col.field}}`; intersection values use `{{cell}}`.
- `value:` accepts a comma-separated field list aligned with the template columns (for example `value: scores,rates`); a single field is shared by all template columns; the count must be 1 or equal to the band width.
- Empty `cols`: only fixed columns remain.
- Column-level conditions (v0.2.4): in a column band's header cell, wrap template columns with `{{#if path}} ... {{/if}}`; the condition is evaluated per column item and, when falsy, removes that item's template columns across the whole table.
  - The path may be a column-item field (`show`), a full path (`subjects[].show`) or a page-level field; column items are checked first, then page data.
  - The condition range cannot exceed the band or nest; multiple ranges may sit side by side but not overlap.
  - Column conditions are row-independent: they cannot reference row fields, and the result is the same for all rows.

Multi-column template example (two columns per subject: "average + score rate"):

```text
| Class | {{#cols subjects value: scores,rates}}{{col.label}} | {{col.rate_label}}{{/cols}} |
| {{#rows classes}}            |          |          |
| {{classes[].name}}           | {{cell}} | {{cell}} |
| {{/rows}}                    |          |          |
```


Example of a column band written inside a row block (each class carries its own subject header row):

```text
| {{#rows classes}}            |                |
| {{classes[].name}}           | {{#cols subjects value: scores}}{{col.label}}{{/cols}} |
| {{classes[].name}}           | {{cell}}       |
| {{/rows}}                    |                |
```

### 9.4.2 Combinations: arbitrary levels + two-dimensional matrices

```text
| Class | {{#cols subjects value: scores}}{{col.label}}{{/cols}} | Total |
| {{#rows classes}}            |          |          |
| {{classes[].name}}           | {{cell}} | {{classes[].total}} |
| {{/rows}}                    |          |          |
```

> Multi-column templates are implemented: `{{#cols subjects value: scores,rates}}{{col.label}} | {{col.rate_label}}{{/cols}}`
> clones both columns as one unit per column item, and `{{cell}}` takes `scores` / `rates` in template-column order.

Expansion order (fixed, and written into the implementation and error messages):

```text
1. Column bands: clone horizontally across all rows first (columns first, so every row keeps the same cell count)
2. Row blocks: clone vertically from outer to inner (each clone is a "multi-row record")
3. Conditional blocks: evaluate per row item, removing falsy blocks
4. Binding: every cell now has a definite row / col / cell scope
```

Why columns before rows: column cloning changes each row's `a:tc` count and the `a:tblGrid` column count, so it must finish first;
row cloning can then copy "already aligned whole rows" as a unit.

### 9.4.3 Scope and paths

| Location | Available variables | Resolution rule |
| --- | --- | --- |
| Row block content | `{{parent[].child[].field}}` full paths | The prefix must match a declared row block |
| Column band header | `{{col.field}}` / `{{col}}` | Column items only |
| Row/column intersection cell | `{{row.field}}` / `{{col.field}}` / `{{cell}}` | row is the current record; cell is the intersection value |
| Static rows/columns | Page data | As today |
| `#if` conditions | With `[]` → loop scope; otherwise current row item → page data | Evaluated per item |

**Keep using full paths only**, with no relative paths:

- Relative paths would implicitly shadow same-named page fields, making check and render easy to diverge;
- Full paths reconcile directly against data, and errors can say "expected `groups[0].items[1].name`";
- The level cap of 3 bounds path length, which real templates tolerate.

### 9.4.4 Static content and merged cells

- Rows outside a row block = static rows (headers, totals, notes), kept as-is and allowed to contain page-level tags.
- Columns outside a column band = fixed columns, not cloned, kept across all rows.
- Merged cells **are allowed** on static rows/fixed columns, but a merged cell **must not intersect** a column band or row block.
  Note: a title row spanning the whole table (including dynamic columns) intersects the band, so it cannot be merged in dynamic-column scenarios; put the title outside the table.
- Cell widths inside a band copy their own template column; row heights copy the template row.

### 9.4.5 Error messages (new ones)

| Situation | Message |
| --- | --- |
| Unclosed block | `row N: {{#rows X}} is missing {{/rows}}` |
| Stray closing marker | `row N: {{/rows}} has no matching {{#rows}}` |
| Nesting exceeded | `row block nesting exceeds 3 levels (row N)` |
| Marker does not own the row | `block markers must occupy the whole row; leave the other cells empty` |
| Band out of bounds | `{{#cols}} and {{/cols}} must be in the same header row, in the correct order` |
| No fixed column | `a column band must keep at least one fixed column (the first column)` |
| Loop inside a conditional block | `conditional blocks cannot contain loop markers; reorder the nesting` |
| Merged-cell conflict | `merged cells cannot intersect a column band or row block; split them first` |
| Mixed syntax | `a table cannot mix L0/L1/L2 with block syntax` |

## 9.5 Compatibility and migration

| Old form | New form | Strategy |
| --- | --- | --- |
| `{{classes[].name}}` (L0) | Kept | Single-level, single template row scenarios keep using L0; no forced migration |
| `{{#rows groups}}` + next row (L1) | `{{#rows groups}} ... {{/rows}}` | A `{{/rows}}` in the table switches to block mode; without a pair it is interpreted as L1 (kept for one release, marked legacy in docs) |
| `{{#grid rows: .. cols: ..}}` (L2) | `{{#cols ..}}` + `#rows` blocks | L2 is kept as sugar for "two-column templates" and maps internally to a column band + single-row block |
| L1 + column bands, previously incompatible | Allowed in block mode | New syntax only |

**Mixing rules**: when a table contains more than one of `[]`, `#rows`, `#grid`, `#cols`,
only block mode allows `#rows + #cols`; every other combination raises with a recommended form.

## 9.6 Implementation sketch

| Step | Change |
| --- | --- |
| 1 | Upgrade `TableLoop` to tree parsing: row block stack, conditional blocks, column band extents; emit `{kind: :blocks, ...}` |
| 2 | Add `expand_table_row_range(table, frame, start, finish, count)`: clone a multi-row record as a whole |
| 3 | Generalise `expand_grid_columns` into `expand_column_band(table, frame, first_col, last_col, count)` |
| 4 | Column expansion does not change row indices but changes each row's cell count; row blocks keep the original indices and re-locate markers before expansion |
| 5 | Extend Binder into a "scope stack": row levels + col + cell; full-path prefix matching reuses the current implementation |
| 6 | Evaluate conditional blocks after row expansion, item by item, deleting row ranges |
| 7 | Recursive validator reconciliation: row blocks item by item, bands column by column, intersections cell by cell; errors carry row/column coordinates |
| 8 | Invariant: after expansion, each row's `tc` count == `tblGrid` column count; `graphicFrame/@cy` stays in sync |

**Risks**

- Getting the order of multi-row cloning and column band cloning wrong makes `tc` counts diverge from column counts, and PowerPoint asks to repair.
  A set of "structural invariant" tests is needed (see `table_row_loop_spec` / `table_grid_spec`).
- Marker rows inside a row block are cloned by column expansion too; strip markers first, then delete them as a whole, avoiding empty rows.
- Deleting rows in conditional blocks shifts all row indices; binding scopes must follow the "post-expansion row plan" and stop using the original table indices.

## 9.7 Open questions

1. Is the nesting cap fixed at 3 or configurable? (Recommendation: fixed at 3 to reduce misuse)
2. Should `#if` support conditional text inside a cell? (Not this release; row level first)
3. Should bands allow "a fixed column every N columns"? (No; split the table instead)
4. When is the unpaired L1 form removed? (Recommendation: warn from v0.3, remove in v0.4)
5. Can multi-row records merge across rows? (Static rows only; forbidden inside blocks)

## 9.8 Phased plan

| Phase | Content | Acceptance |
| --- | --- | --- |
| v0.2.0 ✅ 2026-11-17 | Paired `#rows` blocks (multi-row records, up to 3 levels) + single-column `#cols` bands (may live inside blocks) | Class → student + class × subject examples + 28 regression examples |
| v0.2.1 ✅ 2026-11-17 | Multi-column template bands (template columns cloned as a unit per column item, `value:` aligned per template column) | Subject "average + score rate" example + 33 regression examples |
| v0.2.2 ✅ 2026-11-17 | Row-level `#if` conditions + static merged cells allowed | Conditional row example + 50 regression examples |
| v0.2.4 ✅ 2026-11-17 | Column-level `#if` (removes whole columns per column item) | Conditional column example + 59 regression examples |
| v0.3 | Contract lint supports block declarations; warn on unpaired L1 forms | Guide updated; zero changes to old templates |

> Conclusion: the current L0/L1/L2 cover a 9-page score analysis deck; **the block DSL is the superset prepared for "arbitrary levels + multi-row records + two-dimensional matrices"**.
> Deliver it in three steps per §9.8, each independently shippable and reversible.
