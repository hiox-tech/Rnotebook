# Contributing

Rnotebook is a native macOS application. Keep changes focused and verify them on
the target macOS version before opening a pull request.

## Before you start

- Read `docs/ARCHITECTURE.md` and `docs/LIMITATIONS.md`.
- Do not add a project system, editable data grid, resource archive, telemetry or
  hidden network dependency.
- QMD/RMD Markdown files are the only managed documents.
- Third-party source, licenses and patches under `ThirdParty/` are pinned. Do
  not replace them with unrelated upstream revisions without a provenance note.

## Build and test

```sh
bash scripts/build.sh Release
bash scripts/test.sh
```

`scripts/test.sh` regenerates the help book and verifies pinned dependencies
before running XCTest. Include the exact commands and the macOS/Xcode/R/Quarto
versions used in your pull request.

## Code style

- Swift 6, strict concurrency, AppKit-first UI.
- Prefer native controls and system behavior over hand-drawn replacements.
- Keep document source byte-preserving. Rendering may change attributes, never
  the Markdown source.
- Add a regression test when fixing layout, persistence, execution or
  file-association behavior.

## Third-party changes

Update `ThirdParty/LanguageTools/manifest.sha256` or the relevant
`SOURCE-HASHES.json`/patch record whenever pinned bytes change. Explain the
license and rebuild procedure in `docs/THIRD-PARTY.md`.
