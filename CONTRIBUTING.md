# Contributing to PowerTom

Thanks for your interest in improving PowerTom. This document covers the setup
and the conventions the project follows.

## Development setup

- Ruby >= 3.3 (required by `ruby_pptx` and `tomlrb`)
- LibreOffice (`soffice`) is needed only for the fidelity tests

```bash
bundle install
bundle exec rspec                        # full suite
bundle exec rubocop                      # style
bundle exec yard doc --no-output         # API docs check
bundle exec bundler-audit check --update # dependency advisories
```

## Test suite

- The unit suite runs everywhere; 278 examples are expected to pass.
- End-to-end examples that need the private golden-sample template
  (`spec/fixtures/hai_mate/template.pptx`) **skip automatically** when the file
  is absent, so a fresh clone always runs a green suite.
- The committed scaffolds (`examples/score_report/*.pptx`) and the public
  fidelity CI job cover the full render + LibreOffice PDF pipeline without
  private assets.
- If you have the original golden template, regenerate its snapshot with:

  ```bash
  bundle exec rake fixtures:generate TEMPLATE=/path/to/template.pptx OUT=spec/fixtures/hai_mate
  bundle exec rake fixtures:check OUT=spec/fixtures/hai_mate
  ```

## Conventions

- **User-facing messages are English.** Errors, warnings and `PowerTom.check`
  reports must be in English; code comments may be either language, but new
  comments are preferably English too.
- Every error message carries location information (slide number, shape name,
  tag). Keep that property when adding new checks.
- Failing loudly beats silent fallbacks: missing fields and structural mistakes
  raise or produce errors, never blank output.
- Add or update tests for any behaviour change; table syntax changes need
  structural-invariant tests (row `tc` count == `tblGrid` column count).
- Add a `CHANGELOG.md` entry under the unreleased/next version.

## Pull requests

1. Fork and create a feature branch.
2. Make the change with tests.
3. Run the full suite, RuboCop and YARD locally.
4. Open the PR with a short description of the behaviour change and the reasoning.

Bug reports and feature requests: use the issue templates. For security
issues, please do not open a public issue — see the Security section of the
README and open a private security advisory instead.

## Releasing (maintainers)

Releases are published by pushing a `v*` tag; `.github/workflows/release.yml`
publishes the gem via RubyGems trusted publishing (OIDC). No manual
`gem push` or OTP.
