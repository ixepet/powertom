# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.3.x | yes |
| < 0.3.0 | no |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private vulnerability reporting:
https://github.com/ixepet/powertom/security/advisories/new

When reporting, include:

- Affected PowerTom version, plus `ruby_pptx` and Ruby versions
- A minimal template + data pair that triggers the issue
  (do not attach confidential decks; a synthetic one is fine)
- Expected vs actual behaviour and your impact assessment

We aim to acknowledge reports within 3 business days, will keep you informed
during triage, and will publish a patched release with credit in the advisory
and CHANGELOG unless you prefer to stay anonymous.

## Scope

**In scope**

- The `powertom` gem itself: template scanning/binding, page surgery, table
  loops, picture replacement, TOML data loading
- Crafted `.pptx` inputs that cause crashes, unexpected file access or package
  corruption when rendered (OOXML parsing happens in `ruby_pptx`; we will
  coordinate upstream fixes when the root cause is there)
- Dependency vulnerabilities in `ruby_pptx`, `tomlrb` and transitive gems —
  CI runs `bundler-audit` on every build, but early reports are welcome

**User responsibility**

- Picture fields are read as file paths on the machine running the render.
  If your data comes from untrusted input, validate paths before passing them
  to `render` (restrict to a controlled directory and an extension allowlist) —
  see the README Security section and [dogfooding plan §7](docs/dogfooding-plan.md)
  for the reference `AssetResolver` design.
- Template tags are pure data binding (regex match + path resolution; nothing
  is evaluated), but the data you bind is your responsibility to sanitise for
  display.

## Automated checks

- `bundler-audit` runs in the CI lint job on every push
- The public fidelity job renders committed fixtures and validates the output
  packages open cleanly after LibreOffice conversion
