# PowerTom: Ruby PPTX template engine · project design document

> Name PowerTom, module `PowerTom`, gem name `powertom`. Version v0.1 draft, 2026-11-16.

## 1. Project positioning

### 1.1 One-sentence positioning

Designers maintain the template in PowerPoint; engineers pass a Ruby Hash and get a finished deck. Layout, fonts, masters and theme stay entirely under the design tool's control; the code only "scans tags, binds data and clones pages".

### 1.2 Problems to solve

Ruby's ecosystem has two kinds of existing PPTX generation, and neither fits "reuse the design asset":

| Approach | Examples | Problem |
| --- | --- | --- |
| Code-driven | `powerpoint`, `ruby_slides`, `caracal` (same idea for docx) | Layout is hard-coded; a designer changing one font size has to go through engineering |
| Low-level libraries | `ruby_pptx` (released 2026-09, a python-pptx port), `rbpptx` (released 2026-04, read/write only) | XML-level building blocks with no template layer; designers cannot reasonably work with code |

In the JS world, Carbone and Docxtemplater have proven real commercial demand for "template + JSON data → PPTX"; Ruby has no equivalent. PowerTom fills that layer: a **template engine standing on the shoulders of ruby_pptx**, without parsing OOXML itself.

### 1.3 Non-goals (explicitly out of scope for v1)

- No "declaratively build a whole deck in code" (already covered by ruby_pptx's `Pptx.build`)
- No PPT → PDF conversion (left to LibreOffice headless)
- No reading/writing the legacy PPT (97-2003 binary) format; OOXML .pptx only
- No collaborative editing, comments or other productised features

## 2. Core abstractions and target API

### 2.1 Render entry point

```ruby
require "powertom"

result = PowerTom.render(
  "templates/annual_report.pptx",
  data: {
    title: "2026 annual summary",
    quarter: "Q4",
    kpis: [
      { name: "Adoption rate", value: "29.7%", delta: "+3.2pt" },
      { name: "Monthly active campuses", value: "86", delta: "+12" }
    ],
    show_outlook: true
  }
)

result.save("out/annual_report_2026.pptx")
result.warnings.each { |w| puts w }   # unused fields, truncated text, etc.
```

### 2.2 Data model conventions

- The top level is an arbitrarily nested Hash / Array / scalar; Strings use `to_s`, numbers use `to_s` (formatting is left to template formatters, see 3.4)
- nil values: text tags render as an empty string; conditional tags treat nil as falsy
- Dates and times: accept `Date` / `Time` / `DateTime`; formatting is decided by the formatter

### 2.3 Error model

| Situation | Behaviour |
| --- | --- |
| The template references a field absent from the data | Raises `PowerTom::MissingDataError` by default (with slide number and text box name); with `strict: false`, degrades to an empty string and records a warning |
| The data has fields the template does not use | Records a warning; no error |
| Tag syntax error (for example `{{each kpis}}` missing `#`) | Raises `PowerTom::TemplateSyntaxError` during the pre-render scan |
| ruby_pptx cannot open the file / it is not a pptx | Wrapped and re-raised as `PowerTom::InvalidTemplateError` |

Error messages always carry location: slide number, shape (`name` attribute) and the original tag text. This is the key to designers using a template engine independently.

## 3. Template syntax specification (v0)

### 3.1 Design principles

1. **Directives in notes, tags in the body**: notes are invisible during a presentation but visible to the designer while building, so they never pollute the artwork
2. A single delimiter form `{{ }}`; no full Jinja2/ERB control flow
3. A tag inherits the style of the run it is written in. The placeholder's style is the output style

### 3.2 Text tags

```text
{{title}}
{{kpis[0].value}}
```

Only dot paths and indices are supported; no method calls, expressions or pipes. The path mirrors the data structure, so template review can reconcile by eye.

### 3.3 Page directives (written in slide notes)

```text
{{#each kpis}}      # clone the whole page per array item; tags on the page use each iteration's scope
{{#if show_outlook}}  # remove the whole page when falsy
```

- One directive per notes page; more than one is an error during the scan
- `#if` may coexist with any tags other than `#each`
- Ordinary text tags may still be written in notes (cases that need rendered notes are rare; not supported in v0, a warning is recorded)

### 3.4 Formatters (optional, phase 2)

```text
{{price:currency}}
{{ratio:percent.1}}
{{date:year_month}}
```

The word after the colon maps to a formatter proc registered on the Ruby side. Four built-in families: currency / percent / number / date, plus user registration. Not in v0: the caller does its own `to_s`.

## 4. Architecture

```mermaid
flowchart TD
  subgraph Public["Public API layer"]
    R["PowerTom.render(template, data:)"]
    C["rake powertom:check template checker"]
  end
  subgraph Core["PowerTom core (pure Ruby, unit-testable)"]
    S["Scanner<br/>collects all tags and directives"]
    B["Binder<br/>path lookup / iteration scope / formatters"]
    K["Cloner<br/>page copy and removal plans"]
    V["Validator<br/>template tags vs data structure"]
  end
  subgraph Adapter["Adapter layer (isolates upstream changes)"]
    A["ruby_pptx adapter<br/>the only entry point for reads/writes"]
  end
  subgraph Upstream["Upstream dependencies"]
    P["ruby_pptx (0.x, pinned)"]
    Z["rubyzip / Nokogiri (indirect via ruby_pptx)"]
  end
  R --> S --> B --> K --> A
  C --> S
  C --> V
  A --> P --> Z
```

Layering:

- **Scanner / Binder / Validator never touch XML**; inputs and outputs are plain Ruby structures (tag AST + data), so they unit-test quickly
- The adapter layer is the only place that imports `ruby_pptx`. The upstream API will change before 1.0, and those changes stay locked in one module
- Render pipeline: scan (collect tags across the file) → validate/reconcile → build an "edit plan" (which text to replace, which pages to clone, which pages to remove) → execute once through the adapter → save

## 5. Technical notes and known pitfalls

### 5.1 Run splitting (pitfall #1)

PowerPoint stores `{{title}}` across several runs: IME composition, spell check and repeated editing all trigger it. The symptom is `{{ti` + `tle}}` in two separate `<a:r>` elements.

Solution: concatenate all run text at **paragraph level** into one string, match tags with a regex, write the replacement back into the first run and clear the text of the remaining runs (keeping the run nodes themselves so style references survive). This had to be solved on day one in v0, with full test coverage.

### 5.2 Slide cloning

Cloning a slide requires: copying the slide part and notes part, rebuilding all relationships for the new part (pictures, media, notesSlide links), inserting a new `sldId` (new id and rId) into `presentation.xml`'s `sldIdLst`, and updating `[Content_Types].xml`.

Principle: leave these XML details to ruby_pptx as much as possible; PowerTom only declares "clone slide N K times per some array". **Checked against upstream 0.2.0 source: `Slides#add_table_pages` adds a page per `add(layout)` and builds a new table, with no slide-part copying; `Slides` also has no delete / duplicate.** Clone and delete therefore live in the adapter layer, built on `Opc::Part#relate_to / rels` + `Oxml::BaseElement#import`. Another implicit constraint: `next_slide_partname` names parts as `sldIdLst.size + 1`, so deleting pages without `renumber_slide_parts` collides with existing part names. When upstream lacks a capability, send a PR first; PowerTom does not hoard XML operations, to keep the adapter layer from leaking.

### 5.3 Picture replacement

Placeholder pictures are located by shape name or alt text (convention: name is `powertom:image:field_name`). When replacing the media part, keep the extension and content type consistent. The aspect-ratio strategy is fixed in v0 as "fill the shape and crop from the centre" (proportional scaling via ruby_pptx's crop attributes), with no configurability.

### 5.4 Chart data binding (candidate after v1.0)

Drive `c:ser` series values and category names from data. The difficulty is that when the series count differs from the template, `c:ser` nodes must be added/removed while keeping `c:idx` / `c:order` consistent. It goes last because it may be better as a separate gem (powertom-charts) or an upstream PR.

### 5.5 Fidelity acceptance

The output must open in PowerPoint without a "repair" dialog. CI strategy: after rendering each golden sample, convert to PDF with LibreOffice headless and assert three things — conversion succeeds, the page count is correct, and a PDF text spot-check contains the expected values. LibreOffice is more lenient than PowerPoint, so a manual acceptance checklist remains (for every new golden sample, open it once in real PowerPoint).

## 6. Milestones

| Phase | Content | Acceptance |
| --- | --- | --- |
| M0 · week 1 | Dissect the run structure of a real pptx; get ruby_pptx reads/writes working; reproduce run splitting | A 50-line script: read a template, replace one tag, open normally in PowerPoint |
| M1 · weeks 2-3 | Scanner + Binder + paragraph-level run merge/replace; golden sample 1 (single page, multiple tags) | Golden sample renders in CI; tags split across runs are still replaced |
| M2 · weeks 4-6 | `#each` page cloning, `#if` page removal; error model and location info | Golden sample 2 (loop pages) passes; errors carry slide number and shape name |
| M3 · weeks 7-8 | Validator reconciliation + `rake powertom:check` + warnings | Bad templates fail in CI, and errors guide designers to self-diagnose |
| M4 · weeks 9-10 | Picture replacement; formatters; dogfooding: one real export scenario in a company product | Real business output, with template changes needing no developer involvement |
| After 1.0 | Chart binding, Docxtemplater compatibility layer (evaluation), standalone site and docs | Scheduled by dogfooding feedback |

Between milestones, completeness of the library is not the goal; every phase should produce something "that can really be used".

## 7. Template checker (the differentiating core)

Competitors generally treat validation as a by-product of logging; PowerTom makes it a first-class citizen:

- **`powertom:check`** takes a template + one sample data set (or a data schema) and outputs a human-readable report: every issue names "slide X, shape Y, tag Z, expected data path"
- The report has two levels: error (referenced a missing field, directive syntax error) blocks rendering; warning (unused fields, suspected placeholder overflow) does not
- Ships a Template Guide for designers: master usage conventions, suggested placeholder lengths (with autofit off, overflowing text is not clipped), naming convention `powertom:image:*`
- The designer-facing "template lint" is the most sustainable differentiator versus JS competitors; the guide itself is part of the moat

## 8. Testing and quality strategy

- **Golden fixtures**: produced in real PowerPoint, covering: single page with multiple tags, tags split across runs, loop pages, conditional pages, Chinese fonts, chart pages (later). Each golden sample = template + data + assertions (page count, key text, LibreOffice PDF conversion succeeds)
- **Unit layer**: Scanner / Binder / Validator do no file I/O, pure structure in and out, target coverage > 90%
- **Double regression safety net**: LibreOffice headless conversion + `ruby_pptx` read-back assertions (a successful read-back proves the package structure is self-consistent)
- **Fuzzy inputs**: under `strict: false`, missing tags, nil data and empty arrays (a loop page should become 0 pages by removing the whole group) all need explicit semantics tests

## 9. Risks and mitigations

| Risk | Probability | Mitigation |
| --- | --- | --- |
| ruby_pptx is 0.x and its API changes | High | Single-file adapter isolation + pinned Gemfile versions + full golden-sample run on every upgrade |
| Upstream lacks slide cloning | Medium | Spike before M2; if lacking, send a PR to ruby_pptx (cloning is a common need, so upstream is motivated to accept it) |
| LibreOffice is more lenient than PowerPoint, so broken files slip through | Medium | Manually open golden samples in real PowerPoint; add a Windows/PowerPoint CI job if conditions allow |
| Designers ignore the guide and produce odd templates | Medium | Check tool + guide + errors that locate shape names, minimising self-diagnosis cost |
| Non-standard pptx saved by Keynote / WPS | Low | On open failure, explicitly say "please re-save with PowerPoint / LibreOffice"; no attempt at full compatibility |
| Fewer features than mature options such as Carbone | Certain | Clear positioning as part of the native Ruby ecosystem: one Gemfile line in Rails, no Node dependency, no external service |
| Name collides with existing products in search | Certain | Always use the combined phrases `PowerTom ruby` / `PowerTom pptx` in outward copy; the README title carries product name, domain word and language; see §10 |

## 10. Naming, search and compliance

- Module name `PowerTom`, gem name `powertom` (lowercase, following RubyGems convention, `require "powertom"`). Checked on RubyGems: both `powertom` / `power_tom` were available
- **Origin of the name**: "The Tom in PowerTom is a dedication — left unexplained, on purpose." That wording is authoritative. It appears in three places, never above the fold: a "Why PowerTom" section at the end of the README, one line in the 0.1.0 CHANGELOG, and an optional tagline sub-line
- **Known cost**: `power tom` is a drum-kit term in English (a deep tom drum), and search results are dominated by drum bags, TomTom's "Tom" voice assistant and gaming peripherals; `PowerTom` also differs from Microsoft PowerToys by only a few letters. So do not rely on bare-word search; always use combined phrases in outward copy
- **Trademark boundaries**: not affiliated with Microsoft or TomTom. Keep a permanent line at the top of the README: "Not affiliated with Microsoft or TomTom." Do not borrow the visual language of Microsoft's Power family (Power BI / PowerToys etc.), to avoid being read as official or semi-official
- The name does not describe the function; the tagline carries the outward meaning: `PowerTom — PowerPoint template engine for Ruby`; the README's first screen should hold a 30-second gif: template (designer view) → one terminal command → finished deck
- **Visual identity**: the logo uses restrained marks — an initial, a dot, or a typographic treatment — with no cartoon mascot, to avoid reading as a toy and avoid confusion with drum hardware or TomTom
- MIT licence; no vendoring of upstream template files (ruby_pptx's NOTICE states its templates come from python-pptx; PowerTom's golden samples are all self-made, avoiding secondary attribution issues)
- Release cadence: 0.1.0 after M3 (read-only replacement + checker), no releases during dogfooding, semantic versioning after M4

## 11. Open questions

1. Should nested loops (arrays inside arrays, cloning the whole page per level) be supported in v0? Leaning no: placing directives in notes naturally supports only one page-level loop
2. Should table row-level loops (adding rows to a table on one page from an array) make 1.0? It is the most requested feature, but the implementation touches XML, so it leans toward a separate 0.x milestone
3. Which real company export need should be the dogfooding scenario? This decides the design bias of the golden samples (reporting decks and course-material decks have very different master complexity)
4. Should Rails integration be provided (generator + rake task templates)? Decide after dogfooding feedback
