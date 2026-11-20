# Building Rnotebook

## Prerequisites

- macOS 14 or later
- Xcode 27 or later with the macOS SDK
- Python 3 (used only by the repository scripts)
- Optional: Rust 1.96 for rebuilding Raven
- Optional: network access for the first Raven build or for preparing an
  offline runtime

Normal app builds do not need Rust, Cargo, R or Quarto. The repository already
contains the pinned Air/Raven executables, Tree-sitter sources, Swift packages
and app resources.

## arm64 Release

```sh
bash scripts/build.sh Release
open .build/Rnotebook/Build/Products/Release/Rnotebook.app
```

The script verifies pinned sources, regenerates the Apple Help book, syncs the
Xcode project and builds with ad-hoc signing. `ARCHS` and
`RNOTEBOOK_DERIVED_DATA` are optional overrides.

## Intel Release

Cross-compiling from Apple silicon works with Xcode's generic macOS
destination:

```sh
ARCHS=x86_64 RNOTEBOOK_DERIVED_DATA=.build/Rnotebook-x86_64 \
  bash scripts/build.sh Release
```

The resulting application is x86_64. Intel Quick Look, Raven and Air slices are
included. The offline runtime for Intel must use x86_64 R and x86_64 R binary
packages; Quarto and TinyTeX ship universal macOS tools, Chrome Headless Shell
is architecture-specific.

## Tests

```sh
bash scripts/test.sh
```

The test host uses `org.hiox.Rnotebook.TestHost` and a temporary main bundle
display name, so it does not compete with the production document identity.
The full suite takes several minutes and creates a large `.xcresult` under
`.build/Rnotebook/Logs/Test`.

Some native layout tests are timing-sensitive on a loaded machine. Re-run a
single failing test with `-only-testing:RnotebookTests/...` before treating it
as a product regression.

## Release sanitization

Release executables can retain build-machine paths from Swift/Clang debug
metadata. Strip and ad-hoc re-sign before packaging:

```sh
bash scripts/sanitize-release.sh \
  .build/Rnotebook/Build/Products/Release/Rnotebook.app
```

The script strips the app and Quick Look executables, strips the bundled
Air/Raven tools, signs the sandboxed Quick Look extension with
`QuickLook/Preview.entitlements`, signs the app without extra entitlements,
and verifies the result.

## Rebuilding Raven

```sh
python3 scripts/rebuild-raven.py --work /tmp/rnotebook-raven-build
```

See `ThirdParty/LanguageTools/README.md` for the source archive, patch,
checksums and the Rust requirement. The script signs the output ad hoc; update
`ThirdParty/LanguageTools/manifest.sha256` after reviewing the result. For a
cross-architecture build, use Cargo with `--target x86_64-apple-darwin` (or
`aarch64-apple-darwin`) and set `MACOSX_DEPLOYMENT_TARGET=14.0`.

## Preparing the private offline R

`scripts/prepare-private-runtime.py` extracts the official CRAN framework from
a signed `.pkg`, rewrites its hard-coded `/Library/Frameworks/R.framework`
paths to `/Library/Rnotebook/R.framework`, re-signs the touched Mach-O files
and verifies `R.home()` for the native architecture:

```sh
python3 scripts/prepare-private-runtime.py \
  --pkg R-4.6.2-arm64.pkg \
  --output /tmp/runtime-arm64 \
  --prefix /Library/Rnotebook \
  --verify-native
```

The same command works with `R-4.6.2-x86_64.pkg`; cross-architecture output
can be inspected with `otool` but cannot be executed without Rosetta.

R packages can be installed into `R/library` with a native R 4.6.2. For the
other architecture, download the matching CRAN binary packages, unpack them,
and rewrite their `libR.dylib` load command to
`/Library/Rnotebook/R.framework/Versions/<version>/Resources/lib/libR.dylib`.

## Building the four installers

The checked-in `dist/` files are generated artifacts and are intentionally
ignored by Git. The reproducible outline is:

1. Build the arm64 and x86_64 Release apps with the commands above.
2. Run `scripts/sanitize-release.sh` on both.
3. Stage `/Library/Rnotebook` with R, R packages, Quarto, TinyTeX and Chrome.
4. Build component packages with `pkgbuild --root ... --identifier ...`.
5. Add a hidden, always-selected preflight component
   (`pkgbuild --nopayload --scripts ...`) whose `preinstall` reports existing
   R/Quarto/TeX through `launchctl asuser` + `sudo -u` and a native `display
   dialog`. Keep its script defensive: no GUI session, timeout or missing icon
   must still `exit 0`.
6. Build a distribution product with `productbuild` and a choice list for the
   app, R, basic R packages, Quarto, TinyTeX, Chrome and optional PATH links.
   Use `<domains enable_localSystem="true" .../>` so the component list is
   shown, and `start_selected` (not `selected`) for initial states: macOS 27
   re-applies `selected` defaults after every click, which prevents more than
   one component from being deselected. Put the localized `Welcome.html` and
   `Conclusion.html` under `Resources/en.lproj` and `Resources/zh-Hans.lproj`.
7. Create the software-only DMGs with `hdiutil create -format UDZO`.
8. Mount every DMG read-only and verify `lipo -archs`, `codesign --verify
   --deep --strict` and the `Applications` symlink.
9. Expand each PKG and compare its component `Payload`, `Bom` and `PackageInfo`
   with the previous product; only `Distribution`, `Resources` and the
   preflight package should change. Run
   `installer -pkg ... -target / -showChoicesXML` for both architectures.

The exact component versions and source URLs used for this release are listed
in `docs/THIRD-PARTY.md` and in the runtime manifest installed at
`/Library/Rnotebook/runtime-manifest.json`.

## Signing and notarization

The repository builds use `CODE_SIGN_IDENTITY=-` (ad hoc). For a public
notarized release, replace it with a Developer ID Application identity, sign
the embedded Quick Look extension and language tools, build the product
archive with a Developer ID Installer identity, then notarize and staple both
the app and the installer. Ad-hoc builds are not a substitute for notarization.
