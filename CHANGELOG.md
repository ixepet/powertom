# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Engineering design document moved to `docs/PowerTom-ruby-pptx-模板引擎项目设计文档.md`.

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
