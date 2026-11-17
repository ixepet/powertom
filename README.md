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
- One directive per notes page, maximum.
- TOML dates are written unquoted (`report_date = 2026-01-20`), normalised to Ruby `Date`, and can be formatted with `{{report_date:date.cn}}`.
- Full guide for designers (Chinese): [docs/模板制作规范.md](https://github.com/ixepet/powertom/blob/main/docs/模板制作规范.md).
- Full usage reference (English): [docs/usage.md](https://github.com/ixepet/powertom/blob/main/docs/usage.md).

Built-in formatters: `currency`, `percent`, `number`, `date` (with `.year_month` / `.cn` / `.short`).
Register your own:

```ruby
# Formateur personnalisé — reçoit (value, arg) et renvoie le texte à écrire
PowerTom.register_formatter("rmb") { |value, _arg| "#{value} RMB" }
# Utilisation dans le modèle : {{amount:rmb}}
```

## Template checker

Most tools treat validation as a side effect of logging. PowerTom makes it a first-class step: bad templates fail in CI before anything is rendered.

```bash
bundle exec rake powertom:check TEMPLATE=templates/report.pptx DATA=data/sample.toml
```

Example report (messages are currently emitted in Chinese):

```text
PowerTom 模板校验 — report.pptx
[warning] 第 9 页 形状'(备注)' {{scenarios}} 数组 'scenarios' 为空(0 项):渲染时该组页面将被整组删除
[error  ] 第 2 页 形状'圆角矩形 4' {{workload}} 数据里没有字段 'workload'
[error  ] 第 5 页 形状'powertom:image:banner' {{banner}} 图片文件不存在:/tmp/a.png
[warning] 数据字段 'unused_field' 未被模板使用
------------------------------------------------
2 个 error,2 个 warning(error 阻断渲染,修正后再调用 PowerTom.render)
```

Programmatic API:

```ruby
# Vérifie sans rendre ; les erreurs sont rapportées, pas levées
result = PowerTom.check("templates/report.pptx", data: "data/sample.toml")
result.ok?          # => false
result.errors       # chaque entrée porte slide_no / shape / label / message
result.report       # le rapport lisible ci-dessus
result.exit_code    # 0 ou 1 — utilisable en CI
```

Checks: missing fields (including each item of an `#each` array), unregistered formatters, directive syntax, more than one directive per page, picture fields and missing files, placeholder overflow warnings, unused data fields, leftover tags in notes.

## Error model

| Situation | Behaviour |
| --- | --- |
| Missing field | `PowerTom::MissingDataError` by default, with slide number, shape name and tag; with `strict: false`, fills in blank and records a warning |
| Invalid tag syntax | `PowerTom::TemplateSyntaxError` before rendering |
| Not a valid pptx | `PowerTom::InvalidTemplateError` |
| Missing `#each` path | Always raises — pages are never silently dropped |

Output is **all or nothing**: every check runs before anything is written to disk.

## Limitations (v0.1)

| Limitation | Notes |
| --- | --- |
| Tables support row loops, paired row blocks, nesting and dynamic columns; charts are not bound | `{{classes[].name}}` clones one row; `{{#rows ...}} ... {{/rows}}` clones multi-row records (3 levels); `{{#grid ...}}` / `{{#cols ...}}` clone columns; merged cells inside loops are rejected |
| Notes are not rendered | Notes are only read for page directives |
| Tags on masters/layouts are ignored | Only shapes on slides are processed |
| No PPT → PDF | Use LibreOffice headless |
| `.pptx` only | No legacy 97-2003 binary format |
| TOML or Hash only | No YAML / JSON loader |
| Fixed picture cropping | Always fill the shape and crop from the centre |
| Messages are Chinese-only | Localisation is planned; the report format is language-neutral |

## Development

```bash
bundle install
bundle exec rspec
```

The golden-sample template used by the end-to-end tests (split runs, cloning, picture replacement, fidelity) is not committed, because of size and ownership; only its structural snapshot `spec/fixtures/hai_mate/manifest.toml` is. With the original template at hand:

```bash
bundle exec rake fixtures:generate TEMPLATE=/path/to/template.pptx OUT=spec/fixtures/hai_mate
bundle exec rake fixtures:check OUT=spec/fixtures/hai_mate
```

Without `template.pptx`, fixture-dependent examples are skipped and the unit suite still runs. Fidelity tests need LibreOffice (`soffice`).

## License

MIT.

## Why PowerTom

The Tom in PowerTom is a dedication — left unexplained, on purpose.

Le Tom de PowerTom est une dédicace — laissée sans explication, à dessein.

---
---

# PowerTom — moteur de modèles PowerPoint pour Ruby

> Les designers maintiennent le modèle dans PowerPoint. Les développeurs passent un Hash Ruby (ou un fichier TOML) et obtiennent une présentation finalisée.
> La mise en page, les polices, les couleurs, les masques et le thème restent sous le contrôle du designer ; le code se contente de scanner les balises, de lier les données et de dupliquer les diapositives.

<sub>Non affilié à Microsoft ni à TomTom.</sub>

---

## En 30 secondes

```text
Designer                                   Développeur
┌──────────────────────────┐              ┌──────────────────────────┐
│ Un pptx ordinaire dans    │              │ report.toml              │
│ PowerPoint :              │              │   title = "Examens"       │
│   corps : {{title}}       │  ─────────▶  │   [[classes]]            │
│   notes : {{#each classes}}│              │   name = "8e (3)"         │
│   image nommée            │              │   avg  = 82.4             │
│   powertom:image:cover    │              │                          │
└──────────────────────────┘              └──────────────────────────┘
                    │                                  │
                    └──────────────┬───────────────────┘
                                   ▼
                    PowerTom.render("template.pptx", data: "report.toml")
                                   ▼
                    Présentation finale : balises liées, pages dupliquées
                    ou supprimées, images remplacées — s'ouvre dans
                    PowerPoint sans message de réparation.
```

## Pourquoi un nouveau moteur

Ruby propose aujourd'hui deux façons de produire des PPTX, et aucune ne convient à la réutilisation d'un actif de design :

| Approche | Exemples | Problème |
| --- | --- | --- |
| Génération pilotée par le code | `powerpoint`, `ruby_slides` | La mise en page est codée en dur ; changer une taille de police exige un développeur |
| Bibliothèque OOXML bas niveau | `ruby_pptx`, `rbpptx` | Des briques XML, pas de couche modèle ; inutilisable par un designer |

PowerTom occupe la couche intermédiaire : un **moteur de modèles au-dessus de [`ruby_pptx`](https://rubygems.org/gems/ruby_pptx)**, sans analyser OOXML lui-même. L'équivalent Ruby de Carbone / Docxtemplater — sans dépendance Node, sans service externe, une ligne dans le Gemfile.

## Installation

```ruby
# Gemfile
gem "powertom"
```

Nécessite Ruby >= 3.3 ; dépend de `ruby_pptx ~> 0.2.0` (lecture/écriture) et de `tomlrb ~> 3.0` (fichiers de données).

## Démarrage rapide

**1. Le designer construit le modèle** — un pptx normal, les balises dans le corps, les directives de page dans les notes :

```text
Corps : Bienvenue sur {{product_name}}
        Taux d'adoption {{kpis[0].value}}
Notes : {{#each scenarios}}
```

**2. Le développeur prépare les données** — TOML est le format de données par défaut :

```toml
# TOML — format de données par défaut
product_name = "Espace de travail enseignant"
show_compare = true

[[kpis]]
name = "Taux d'adoption"
value = "29.7%"

[[scenarios]]
headline = "Pack de lecture du matin"
detail = "Prêt automatiquement chaque dimanche"
```

**3. Rendu :**

```ruby
require "powertom"

# Lecture du modèle, liaison des balises, duplication/suppression de pages,
# remplacement des images
result = PowerTom.render("templates/report.pptx", data: "data/report.toml")
result.save("out/report.pptx")
result.warnings.each { |w| warn w }   # champs inutilisés, valeurs de repli…
```

Ou passez directement un Hash quand les données viennent d'une base ou d'une API :

```ruby
# Même appel avec des données en mémoire
result = PowerTom.render("templates/report.pptx", data: {
  product_name: "Espace de travail enseignant",
  kpis: [{ name: "Taux d'adoption", value: "29.7%" }],
  scenarios: [{ headline: "Pack de lecture", detail: "Prêt chaque dimanche" }]
})
```

## Syntaxe des modèles

> Référence complète : [docs/usage.md](https://github.com/ixepet/powertom/blob/main/docs/usage.md) — données, balises, blocs de tableaux, formateurs, images et erreurs.

| Syntaxe | Emplacement | Signification |
| --- | --- | --- |
| `{{title}}` | corps | Lier un champ |
| `{{kpis[0].value}}` | corps | Chemin pointé + indice de tableau |
| `{{classes[].name}}` | cellule de tableau | Boucle de lignes : duplique la ligne pour chaque élément |
| `{{#rows groups}}` | ligne de tableau | Marqueur de boucle imbriquée : déclare le tableau parent (la ligne de marqueur n'est pas imprimée) |
| `{{#rows groups[].items}}` | ligne de tableau | Marqueur de boucle imbriquée : déclare le tableau enfant |
| `{{#grid rows: .. cols: ..}}` | en-tête de tableau | Colonnes dynamiques : duplique la colonne modèle pour chaque élément de `cols` |
| `{{#rows groups}} ... {{/rows}}` | lignes de tableau | Bloc de lignes apparié : duplique toutes les lignes entre les marqueurs par élément (3 niveaux max) |
| `{{#cols subjects}} ... {{/cols}}` | ligne de tableau | Bande de colonnes : une ou plusieurs colonnes modèles ; peut être déclarée dans l'en-tête ou dans un bloc de lignes |
| `{{#if groups[].flag}} ... {{/if}}` | lignes de tableau | Bloc de lignes conditionnel à l'intérieur d'un bloc `#rows` |
| `{{price:currency}}` | corps | Formateur : `¥1,234.56` |
| `{{ratio:percent.1}}` | corps | Formateur : `29.7%` |
| `{{day:date.year_month}}` | corps | Formateur : 2026年11月 |
| `{{#each scenarios}}` | notes | Duplique la page pour chaque élément (tableau vide = groupe supprimé) |
| `{{#if show_compare}}` | notes | Supprime la page si la valeur est fausse |

- **Les runs fractionnés sont gérés** : si PowerPoint découpe `{{title}}` en plusieurs runs, le moteur fusionne le paragraphe et remplace correctement ; le résultat hérite du style du premier run.
- **Lignes de tableau imbriquées** : `{{#rows groups}}` occupe une ligne entière (première cellule uniquement), et la ligne suivante est la ligne de contenu parent ; `{{#rows groups[].items}}` suivie de sa propre ligne de contenu ajoute un niveau. Deux niveaux maximum ; les balises parent et enfant utilisent le chemin complet (`{{groups[].name}}`, `{{groups[].items[].name}}`).
- **Colonnes dynamiques** : placez `{{#grid rows: distribution cols: bands value: counts}}` dans la première cellule de l'en-tête. La deuxième cellule de l'en-tête est le modèle de colonne (`{{col.label}}`), et la ligne suivante est le modèle de ligne (`{{row.name}}` dans la première cellule, `{{cell}}` dans les colonnes de données). Exactement deux colonnes ; `value:` est facultatif (par défaut `row[col.key]`).
- **Blocs de lignes (v0.2.x)** : `{{#rows groups}} ... {{/rows}}` occupent chacun une ligne entière ; tout ce qui se trouve entre eux est le modèle d'un enregistrement, dupliqué par élément. Jusqu'à 3 niveaux ; `{{row.name}}` désigne l'enregistrement courant. Une bande `{{#cols ...}}` peut être déclarée dans l'en-tête ou directement dans un bloc de lignes, et couvrir plusieurs colonnes modèles ; `value: scores,rates` associe un champ à chaque colonne modèle (un seul champ est partagé par toutes). Un bloc `{{#if ...}} ... {{/if}}` dans un bloc de lignes supprime toutes ses lignes pour les éléments dont la condition est fausse.
- **Images** : nommez la forme ou son texte de remplacement `powertom:image:cover` et fournissez un chemin de fichier dans les données. Le remplacement remplit toujours la forme et recadre depuis le centre.
- Une seule directive par page de notes, au maximum.
- Les dates TOML s'écrivent sans guillemets (`report_date = 2026-01-20`), sont normalisées en `Date` Ruby et peuvent être formatées avec `{{report_date:date.cn}}`.
- Guide complet pour les designers (en chinois) : [docs/模板制作规范.md](https://github.com/ixepet/powertom/blob/main/docs/模板制作规范.md).

Formateurs intégrés : `currency`, `percent`, `number`, `date` (avec `.year_month` / `.cn` / `.short`).
Ajoutez les vôtres :

```ruby
# Formateur personnalisé — reçoit (value, arg) et renvoie le texte à écrire
PowerTom.register_formatter("rmb") { |value, _arg| "#{value} RMB" }
# Utilisation dans le modèle : {{amount:rmb}}
```

## Vérificateur de modèles

La plupart des outils traitent la validation comme un effet de bord des logs. PowerTom en fait une étape de premier ordre : un modèle défectueux échoue en CI avant tout rendu.

```bash
bundle exec rake powertom:check TEMPLATE=templates/report.pptx DATA=data/sample.toml
```

Exemple de rapport (les messages sont actuellement en chinois) :

```text
PowerTom 模板校验 — report.pptx
[warning] 第 9 页 形状'(备注)' {{scenarios}} 数组 'scenarios' 为空(0 项):渲染时该组页面将被整组删除
[error  ] 第 2 页 形状'圆角矩形 4' {{workload}} 数据里没有字段 'workload'
[error  ] 第 5 页 形状'powertom:image:banner' {{banner}} 图片文件不存在:/tmp/a.png
[warning] 数据字段 'unused_field' 未被模板使用
------------------------------------------------
2 个 error,2 个 warning(error 阻断渲染,修正后再调用 PowerTom.render)
```

API programmatique :

```ruby
# Vérifie sans rendre ; les erreurs sont rapportées, pas levées
result = PowerTom.check("templates/report.pptx", data: "data/sample.toml")
result.ok?          # => false
result.errors       # chaque entrée porte slide_no / shape / label / message
result.report       # le rapport lisible ci-dessus
result.exit_code    # 0 ou 1 — utilisable en CI
```

Contrôles : champs manquants (y compris chaque élément d'un tableau `#each`), formateurs non enregistrés, syntaxe des directives, plus d'une directive par page, champs d'image et fichiers absents, avertissements de débordement de texte, champs de données inutilisés, balises oubliées dans les notes.

## Modèle d'erreurs

| Situation | Comportement |
| --- | --- |
| Champ manquant | `PowerTom::MissingDataError` par défaut, avec numéro de diapositive, nom de forme et balise ; avec `strict: false`, remplit par du vide et enregistre un avertissement |
| Syntaxe de balise invalide | `PowerTom::TemplateSyntaxError` avant le rendu |
| Fichier pptx invalide | `PowerTom::InvalidTemplateError` |
| Chemin `#each` manquant | Lève toujours — aucune page n'est supprimée silencieusement |

La sortie est **tout ou rien** : tous les contrôles ont lieu avant la moindre écriture sur disque.

## Limites (v0.1)

| Limite | Précision |
| --- | --- |
| Tableaux : boucles de lignes, blocs appariés, imbrication et colonnes dynamiques ; graphiques non liés | `{{classes[].name}}` duplique une ligne ; `{{#rows ...}} ... {{/rows}}` duplique des enregistrements multi-lignes (3 niveaux) ; `{{#grid ...}}` / `{{#cols ...}}` dupliquent des colonnes ; les cellules fusionnées dans une boucle sont refusées |
| Les notes ne sont pas rendues | Elles servent uniquement aux directives de page |
| Les balises sur les masques/dispositions sont ignorées | Seules les formes des diapositives sont traitées |
| Pas de PPT → PDF | Utilisez LibreOffice en mode headless |
| `.pptx` uniquement | Pas de format binaire 97-2003 |
| TOML ou Hash uniquement | Pas de chargeur YAML / JSON |
| Recadrage d'image fixe | Toujours remplir la forme et recadrer depuis le centre |
| Messages en chinois uniquement | La localisation est prévue ; le format du rapport est neutre |

## Développement

```bash
bundle install
bundle exec rspec
```

Le modèle de référence utilisé par les tests de bout en bout (runs fractionnés, duplication, remplacement d'images, fidélité) n'est pas versionné, pour des raisons de taille et de propriété ; seule son empreinte structurelle `spec/fixtures/hai_mate/manifest.toml` l'est. Avec le modèle d'origine :

```bash
bundle exec rake fixtures:generate TEMPLATE=/chemin/vers/modele.pptx OUT=spec/fixtures/hai_mate
bundle exec rake fixtures:check OUT=spec/fixtures/hai_mate
```

Sans `template.pptx`, les exemples qui en dépendent sont ignorés et la suite unitaire s'exécute normalement. Les tests de fidélité nécessitent LibreOffice (`soffice`).

## Licence

MIT.

## Pourquoi PowerTom

The Tom in PowerTom is a dedication — left unexplained, on purpose.

Le Tom de PowerTom est une dédicace — laissée sans explication, à dessein.
