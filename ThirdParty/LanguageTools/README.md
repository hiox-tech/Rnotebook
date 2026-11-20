# Native editor language services

Pinned upstream sources and download checksums are in SOURCES.json. The app
compiles Tree-sitter 0.25.10, the R grammar at
8ac99ed1e7ad319737fc11dde20c07d1e1942383, and Markdown grammar 0.5.3 as C.
Generated parser/scanner sources, query files and MIT licenses are retained.
Visual Markdown rendering continues to use the existing swift-markdown path.

The pinned R scanner includes the reviewed allocation-failure fix in
`TreeSitter-R-allocation.patch`: free its scope buffer if allocating the stack
object fails. `LOCAL-PATCHES.json` records the original and patched hashes;
the upstream revision and grammar are unchanged. The native failure-injection
test covers both failed allocations and successful create/destroy. This patch
only recompiles the App/Preview grammar; it does not rebuild Raven or Air.

The app bundles Air 0.13.0 (official arm64 and x86_64 releases) and Raven 0.21.1
built from the source archive with the local patch, for both architectures.
Air’s MIT license and Raven’s GPL v3 license are included in app resources.
The unmodified Raven source archive and Cargo.lock are retained here so the
patch can be reviewed and reapplied. Normal Xcode builds need neither Cargo
nor network access. These assets do not update the old Intel trial ZIP.

## Raven patch

- Use real structured formals for package signatures, shared with named argument
  completion; this avoids confusing functions that share one Rd help page.
- Resolve namespace calls and unfinished calls through the same call context.
- Serialize package formals misses, recheck the 500-entry successful cache and
  use a bounded 5-second negative cache. Clear both on environment invalidation.

Raven is launched lazily per document and stopped when completion is disabled
or the editor closes. It owns a separate process group. Its temporary R helpers
are not the interactive Worker and are not kept running between queries.
User R profiles, workspace indexing, source dependency traversal, linting and
library watching are disabled. Only the current QMD's masked R source is sent.
The existing Worker can provide bounded global/list/data-frame names when idle;
completion never evaluates an expression or forces active/lazy bindings.

## Rebuild

Use Rust 1.96.0 or newer and a fresh writable build directory:

```
python3 scripts/rebuild-raven.py --work /tmp/rnotebook-raven-build
```

For the other architecture, build with Cargo's `--target x86_64-apple-darwin`
(or `aarch64-apple-darwin`) and copy the resulting `raven` to
`DesktopApp/Resources/LanguageTools/raven-<arch>`; keep the runtime path remap
and ad-hoc signature described above.

`--cargo /absolute/path/to/cargo` supports a private toolchain (put its rustc
beside cargo on PATH). `--prepare-only` checks archive and patch application.
Cargo uses the checked-in lockfile and needs a registry cache or network on the
first build. macOS 27's LINKEDIT issue is avoided by disabling profile stripping,
including build dependencies. Deployment target is macOS 14. The script signs
its output ad hoc. After review, update manifest.sha256 and repeat the language
services and full app regressions. Source rebuilds may differ byte-for-byte.

`manifest.sha256` protects the retained sources/queries/licenses, patch and tool
executables. `scripts/verify-language-tools.py` checks it before app builds/tests.
Air replacement must use the exact official archive checksum from SOURCES.json;
retain the official license and sign the extracted binary ad hoc.
