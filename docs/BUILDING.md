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
   with the previous product. For an application update, verify the new app
   payload and matching app/extension version metadata; preserve the runtime
   component bytes unless those components are explicitly being updated. Run
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

## File-type compatibility release acceptance

Version 0.1.1 adds `org.quarto.qmarkdown` and `com.rstudio.rmarkdown` to the
app and Quick Look declarations, retaining both 0.1.0 identifiers. The Open
panel uses an extension-based delegate so conflicting or dynamic UTIs cannot
disable QMD/RMD files. Both the application and extension use version 0.1.1,
build 2; the project sync script supplies these values.

Local tests were not run for this update at the user's request. Before
calling the issue resolved, install the new build on the affected computer,
quit the previous app first, and verify each of the following separately:

- Finder recommends Rnotebook for QMD and RMD files.
- File > Open enables existing `.qmd`, `.QMD`, `.rmd`, `.Rmd`, and `.RMD`
  documents while rejecting unrelated files; folders remain navigable.
- New, Open, save, and reopen retain the document extension and source.
- Finder Space previews both formats using the Rnotebook Code/Visual UI.
  An installed extension notification alone does not verify provider selection.

If Quick Look still fails, record the current file UTIs with `mdls`, the
extension state/version with `pluginkit -m -A -D -i org.hiox.Rnotebook.Preview`,
and extension launch errors. Do not change all plain-text file associations
or clear the entire Launch Services database as an installation step.

## Version 0.1.2 app-only update

The app and extension use version 0.1.2, build 3. The app now creates a fresh
public NSOpenPanel with its own delegate. It does not forward the document
controller's type-filtering callbacks. Supported suffixes remain selectable
without requiring complete resource metadata; selected documents are still
validated and opened through NSDocumentController.

Include `scripts/installer` as the `pkgbuild --scripts` directory for the app
component. Use a non-relocatable component with install location `/` and root
path `Applications/Rnotebook.app`. The same app component is also distributed
as `Rnotebook-0.1.2-{arm64,x86_64}-app-only.pkg`; it installs no offline runtime.
The postinstall verifies both installed bundles are version 0.1.2/build 3,
then attempts to register that app and extension for the console user. It
neither changes default handlers nor forces extension enablement. This
postinstall is packaged and statically checked, not executed locally.

Follow-up evidence from the affected computer showed that its installed app
and registered preview were still 0.1.0. Always verify the installed version
before interpreting acceptance results. Version 0.1.1 functionality was not
established to have failed by that evidence.

For read-only diagnostics without Xcode or a Swift installation, run the
installed application executable directly. This mode prints JSON and exits
without opening the UI or changing registrations:

```sh
/Applications/Rnotebook.app/Contents/MacOS/Rnotebook --diagnose-document-types \
  "/actual/path/document.qmd" "/actual/path/document.Rmd"
```

The report includes the executing app path and version, registered copies,
live file UTIs, extension-to-type mappings, candidate/default applications,
and the bundled preview's version and supported types. It does not prove that
the preview extension was enabled, selected, or launched; inspect `pluginkit`
and system logs separately if needed. Local functional tests remain deferred
to the affected computer at the user's request.
