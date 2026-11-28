# Evaluation: Docxtemplater compatibility layer & standalone site/docs

> Status: evaluated 2026-11-23, against PowerTom 0.9.1 (`main` @ 9efdbc3).
> Scope: the two "After 1.0" items in [project-design.md](project-design.md) §6:
> *Docxtemplater compatibility layer (evaluation), standalone site and docs*.
> Verdict up front: **site/docs — do the minimal GitHub Pages version now;
> compatibility layer — do not build it, revisit only on real migration demand.**

## 1. Docxtemplater compatibility layer

### What "compatible" would mean

Docxtemplater (open-xml-templating, 8+ years maintained) now generates
**docx, pptx and xlsx** natively. Its template syntax is Mustache-style:

| Concept | Docxtemplater | PowerTom today | Gap |
| --- | --- | --- | --- |
| Delimiters | `{ … }` by default, configurable | `{{ … }}` hard-coded in `Scanner::TAG_RE` | small — an opt-in delimiter setting is feasible |
| Placeholder | `{name}` | `{{name}}` | same as above |
| Loop / section | `{#users} … {/users}` around **any** in-page element (paragraphs, table rows, pictures) | in-page loops only inside tables (`#rows` / `#cols` / `arr[].f`); ordinary shapes can only loop by cloning the **whole page** (`{{#each}}` in notes) | **large — a semantic gap, not syntax** |
| Condition | `{#cond} … {/cond}` boolean section, in-page | `{{#if}}` in notes removes the page; `powertom:if:` removes a shape; `#if` blocks inside table loops | medium |
| Expressions | angular parser: `{#if user.age > 18}`, filters/pipes, `$index` | deliberately no expressions — `check` must stay static; only formatters and restricted aggregates exist | **principle conflict** with the check-first design |
| Images | `{#image}` module | shape named `powertom:image:key` | small, naming convention |

### Audience reality check

- Teams that know Docxtemplater are JS teams, and Docxtemplater already speaks
  pptx — there is no reason for them to move to Ruby just for familiar syntax.
- Ruby teams have no Docxtemplater muscle memory to migrate from.
- The real migration blocker would be **semantics** (in-page section loops over
  arbitrary shapes), which is exactly the large feature this project has
  repeatedly deferred (project-design §11 Q1: nested/in-page loops, leaning no;
  feature-direction: keep the surface small). Expressions conflict with the
  static `check` guarantee.
- Single-brace `{` in slide body text also raises false-positive risk (legal /
  math text); the existing loose `TAG_RE` backstop would need delimiter-aware
  handling.

### Verdict

- **Do not build a full compatibility layer.** No evidenced demand, high cost,
  and it collides with two stated design principles (static check, small
  surface).
- If dogfooding/production feedback ever shows real migration requests, ship
  only the cheap subset: an opt-in custom delimiter (e.g. `{ … }`) in the
  scanner + validator + error messages. In-page arbitrary-shape sections and
  expression parsing stay out of scope permanently — record this in
  `feature-direction.md` when it happens.

## 2. Standalone site and docs

Current state: 11 markdown files under `docs/` (user-facing: `usage.md`,
`template-guide.md`, `windows-support.md`; internal design docs:
`project-design.md`, `feature-direction.md`, `chart-binding-design.md`,
`table-loop-design.md`, `dogfooding-plan.md`, `dogfooding-retrospective.md`,
`score-report-template-spec.md`), README on GitHub, YARD API docs built to
`doc/` but not published anywhere.

| Option | Cost | Benefit | Verdict |
| --- | --- | --- | --- |
| A. GitHub Pages + Jekyll, publishing `docs/` + YARD `doc/` | low: one `_config.yml` + one `pages` workflow; Jekyll is built into Pages, zero new dependencies for the gem | template guide reachable by designers/non-engineers without browsing a repo; API reference online; SEO | ✅ do this now, minimal version |
| B. VitePress / Docusaurus standalone site | medium: Node build chain, version maintenance, contradicts the small-dependency principle | nicer search/navigation | ⏸ only after traffic justifies it |
| C. Custom domain (e.g. powertom.dev) | low technically (Pages custom domain), plus domain purchase / regional filing | branding | ⏸ can be added later without rework |

Recommended minimal shape for option A — **implemented 2026-11-23**:

1. Site source is `docs/` with `docs/_config.yml` (theme: minima). User-facing
   pages (`usage.md`, `template-guide.md`, `windows-support.md`) carry Jekyll
   front matter; internal design docs are `exclude`d but stay in the repo.
   Home (`index.md`) and `changelog.md` are generated in CI from `README.md` /
   `CHANGELOG.md` so the repo files stay free of front matter.
2. `.github/workflows/pages.yml`: install jekyll/minima/yard standalone (the
   gem's dependency surface is unchanged), `yard doc` → `_site/api`,
   `jekyll build` from `docs/`, deploy via `actions/deploy-pages` on push to
   `main`. Pages URL: `https://ixepet.github.io/powertom/`.
3. No custom domain yet; add later via Pages settings.

Gotcha found while building: Jekyll's `exclude` entries are **prefix**
matched, so `doc` also excludes `docs/` — write `doc/` with a trailing slash.
Also, only files with YAML front matter are converted to pages; the rest are
copied as static files.

## 3. Sequencing

Both items were scheduled "after 1.0, by dogfooding feedback" — we are at 0.9.x
and the production dogfooding items (rollout, designer self-service) are still
open (see [dogfooding-retrospective.md](dogfooding-retrospective.md) §8). So:

1. Site/docs (option A) is unblocked and cheap → do it next, it also serves the
   dogfooding rollout (designers need the template guide online).
2. Compatibility layer stays **evaluated-no**; trigger to reopen = concrete
   migration requests from real users in dogfooding feedback.
