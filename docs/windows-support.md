---
layout: page
title: Windows support and verification
---

# Windows support and verification

> Status: verified on Windows 11 · Ruby 4.0.9 (scoop) · Microsoft Office 16 (Click-to-Run)
> Scope: how PowerTom behaves on Windows, why file locking needed explicit work,
> and how the behaviour is verified. Last updated: 2026-11-19.

---

## 1. Summary

| | |
| --- | --- |
| Supported | Windows 11, Ruby 3.3 / 3.4 / 4.0, Microsoft Office 16 (Click-to-Run) |
| Template handle after a render | Released — the template can be deleted or renamed immediately |
| Output handle after a render | Released — the deck can be deleted or renamed immediately |
| Suite on Ruby 4.0.9 | 384 examples, 0 failures, 86 pending |
| PowerPoint 16 open test | 9 / 9 decks opened without a repair prompt, `Presentation.Saved == -1` |
| L3 schema gate | Microsoft's OpenXmlValidator on a Windows runner (`.github/workflows/l3.yml`) |

The pending examples are designed-in skips: 80 need a private golden template
that is not committed, 6 need LibreOffice.

## 2. The problem: zip file handles are not released

### 2.1 What happened

On Windows, a file with an open handle cannot be deleted, renamed or
overwritten. After a render, both the template and the produced deck stayed
locked, and the test suite reported the consequence as

```text
Errno::EACCES: Permission denied - apply2files .../each_xxx.pptx
```

The failure count moved with the random seed — 19, 32, 33, 34 across four
seeds — and single examples often passed when run alone. That signature
(a green test in isolation, a red suite in bulk) is what ruled out a logic
error and pointed at resource lifetime.

### 2.2 The root cause

`rubyzip` 3.x does not keep a handle in `Zip::File` itself. The handle lives
on each `Zip::InputStream` it hands out:

```ruby
# rubyzip-3.7.0/lib/zip/input_stream.rb
def get_io(io_or_file)
  return io_or_file if io_or_file.respond_to?(:read)

  if @filename
    ::File.open(io_or_file, 'rb')   # an independent handle per entry
  else
    io_or_file
  end
end
```

`Zip::Entry#get_input_stream` closes the stream only when it is given a
block:

```ruby
def get_input_stream(&block)
  zis = ::Zip::InputStream.new(self)
  return zis unless block

  begin
    yield zis
  ensure
    zis.close
  end
end
```

So `entry.get_input_stream.read` — reading without a block — leaks one handle
per entry until the GC finalizer runs. Because `Zip::File` holds no handle of
its own, `Zip::File.open(path) { ... }` closing at the end of the block does
**not** release them. The decisive experiment:

| Read pattern | File deletable afterwards? |
| --- | --- |
| `entry.get_input_stream.read` (no block) | **No** — locked |
| `entry.get_input_stream(&:read)` (block) | Yes |
| `entry.get_input_stream.read` + `GC.start` | Yes, but the timing is not controllable |

A second, independent factor: Ruby 4.0 changed `Tempfile` to a delegate with a
`FinalizerManager` (`tempfile.rb:386-397`), so `File.unlink` is deferred to GC.
The upstream source comments acknowledge the finalizer may be delayed and must
not be relied upon. On Windows, an explicit unlink that races an open zip
handle raises `Errno::EACCES` as well.

### 2.3 The fix

| Change | Where | Why |
| --- | --- | --- |
| Every read passes a block | `lib/`, `spec/`, `spec/support/`, `tools/` (25 sites) | The stream closes as soon as it is consumed |
| `PageSurgery` reads through `open_buffer` over a `StringIO` | `lib/powertom/adapter/page_surgery.rb` | The template handle exists only during the read; the whole surgery runs in memory |
| The workbook rewrite runs in memory and returns bytes | `lib/powertom/adapter/ruby_pptx_adapter.rb` | No temporary `.xlsx`, so no `Tempfile` finalizer race |
| `Tempfile.create` (a plain `File`, no finalizer) plus an explicit unlink | `lib/powertom/render.rb`, `lib/powertom/adapter/ruby_pptx_adapter.rb` | The lifetime is fully explicit |
| `FileUtils.rm_f` for cleanup, never raising | `PowerTom.dispose_tempfile` | A leftover file in the OS temp directory must never mask a successful render |

One subtlety worth recording: the rewrite originally read

```ruby
Zip::OutputStream.write_buffer do |out|
  ...
end.string
```

The `do...end` block binds to the innermost method call, so `.string` was
parsed as part of the inner block and the expression evaluated to a
`StringIO` rather than a byte string. Downstream, `Zlib::Deflate` refused it
with *"no implicit conversion of StringIO into String"*. The nested form is now
split through an explicit intermediate variable.

## 3. How it is verified

### 3.1 The suite

```bash
bundle exec rspec
# 384 examples, 0 failures, 86 pending
```

Repeated with four fixed seeds to rule out order-dependent flakiness:

```bash
for seed in 111 222 333 444; do
  bundle exec rspec --seed $seed
done
# every run: 0 failures
```

Before the fix, the same tree reported 19 failures on the unmodified baseline
and 32–34 depending on the seed.

### 3.2 Real user scenario

The behaviour that matters is not the test count but what a user can do after
a render:

```ruby
result = PowerTom.render("template.pptx", data: data)
result.save("out.pptx")
result.close

File.delete("template.pptx")   # succeeds on Windows
File.delete("out.pptx")        # succeeds on Windows
```

Before the fix, the template was still locked at this point.

### 3.3 Microsoft PowerPoint 16

The suite renders decks that are structurally valid, but only PowerPoint can
say whether it accepts them. Verification opens each deck through COM
automation and reads two signals:

- the presentation opens with **no repair dialogue**;
- `Presentation.Saved == -1` — PowerPoint did not modify the file, which
  means it considers the structure valid.

Covered decks: the mini golden sample (8 pages), the score report v1
(10 pages) and v2 (9 pages), and rendered column / radar / pie chart decks.
**9 / 9 opened cleanly**, and `Saved` was `-1` for every one.

Two ways to drive COM on Windows, both verified here:

- **PowerShell + `New-Object -ComObject`** hits `TYPE_E_CANTLOADLIBRARY
  (0x80029C4A)` — the strongly typed PowerShell interop layer cannot load the
  type library of the Click-to-Run installation.
- **Ruby + `win32ole` late binding** works:

  ```ruby
  require "win32ole"
  pp = WIN32OLE.new("PowerPoint.Application")
  pres = pp.Presentations.Open(path, -1, 0, 0)
  pres.Saved            # -1 => PowerPoint did not touch the file
  pres.Export(dir, "PNG", 1600, 900)
  pres.Close
  ```

  `pp.Visible = 0` is rejected by PowerPoint — it does not allow a hidden
  window — but that is harmless for headless verification.

### 3.4 Visual inspection

`pres.Export(dir, "PNG", 1600, 900)` renders each slide through PowerPoint
itself. The exported images were inspected for:

- column charts: both series present, all four categories drawn, correct values;
- radar charts: the polygon closes correctly, and **no smoothed curve appears**
  — the defect `ruby_pptx` 0.3.1 fixed (`Largo/ruby_pptx#3`), which the
  version-gated local normalisation now leaves to upstream;
- CJK text: KPI cards render `82.4` / `31.2%` / `94.6%` / `486` with no tofu
  boxes or mojibake.

### 3.5 L3 schema validation

The strongest machine check is Microsoft's own validator, wired as a hard gate
in `.github/workflows/l3.yml`: the deck set is rendered on Ubuntu, downloaded
to a Windows runner, and validated with `tools/openxml_validator`
(`net8.0` + `DocumentFormat.OpenXml`). Any schema-level finding fails the
build and blocks the merge. It also runs on a daily schedule to catch upstream
drift.

A local Windows machine without the .NET SDK cannot run this job; that is why
the PowerPoint COM check above exists as a local substitute.

## 4. Notes for contributors on Windows

- `bundle install` needs the `x64-mingw-ucrt` platform in `Gemfile.lock`;
  without it the install fails on Windows.
- Ruby 4.0 removed the `parser` gem's precompiled path for some platforms.
  On 4.0.9 the install succeeds; on 4.0.6 it did not and the suite had to be
  run against the system gems directly.
- `Tempfile.new` is not usable for anything whose deletion must be
  deterministic on Windows. Use `Tempfile.create` and unlink explicitly, or
  keep the data in memory.
- Any new code that reads a zip entry must pass a block. `grep -rn
  "get_input_stream" --include="*.rb"` should show no call without `(&:read)`
  or an explicit block.

## 5. Related documents

- [project-design.md §7.3](project-design.md) — the Windows file-locking rules
  as a design constraint, and the checker's "never raises" contract.
- [chart-binding-design.md §10](chart-binding-design.md) — the upstream
  `ruby_pptx` chart defects and the version-gated workaround.
- [../index.html](../index.html) — the user-facing summary and the enterprise
  delivery section.
