# Known limitations

Rnotebook is intentionally narrower than a full IDE or a general R GUI.

## Platform and distribution

- The deployment target is macOS 14. The current release was built and tested
  on macOS 27 arm64. macOS 14 and Intel hardware have not been physically
  re-tested for this release.
- The Intel app is cross-compiled and statically verified on an arm64 machine.
  Its R/Qt/Chrome payloads are x86_64, but it should be treated as a preview
  until run on an Intel Mac.
- The app and installers are ad-hoc signed, not Developer ID signed or
  notarized. Gatekeeper may require right-click → Open. There is no automatic
  update channel.
- The PKG installs a system-wide runtime under `/Library/Rnotebook`; it needs an
  administrator. There is no uninstaller. Remove `/Library/Rnotebook`,
  `~/Library/Application Support/Rnotebook` and
  `~/Library/Caches/org.hiox.Rnotebook` to remove user data.
- When existing R, Quarto, TeX or an existing Rnotebook installation is found,
  the PKG shows a native alert with the detected versions and paths before
  copying files. It has a single Continue button and proceeds automatically
  after 45 seconds; it is skipped when no GUI session is available. This prompt
  is implemented with an installer preinstall script and has not been exercised
  in a real administrator install in this build environment.
- The first-run prompt for choosing Rnotebook as the default `.qmd`/`.Rmd`
  application is not implemented in this release. The app declares both
  document types; choose the default in Finder's Get Info or System Settings.
  Quick Look is installed with the app and may need to be enabled in
  Extensions settings.
- The PKG's optional PATH links are off by default and never overwrite an
  existing `/usr/local/bin` command. Existing shell sessions do not pick up new
  links automatically.

## Runtime and export

- The offline bundle includes common and Chinese LaTeX support (ctex/xeCJK),
  not all of TeX Live. Arbitrary templates, fonts, bibliography styles and
  packages may still be missing; install them into the user TeX tree or use
  Typst. Remote images, online data and R packages not in the bundle are not
  available offline.
- R Markdown execution implements a static, documented subset of knitr options
  (`eval`, `error`, chunk labels and common headers). Dynamic knitr
  configuration, arbitrary output hooks and full project semantics are left to
  Quarto rendering.
- The app does not install R packages automatically. Missing
  `evaluate`/`jsonlite`/`knitr`/`rmarkdown` or a missing Quarto is reported
  explicitly.
- PDF output needs a working TeX distribution or Typst. The offline PKG supplies
  both TeX and Typst through Quarto; the DMG-only build does not.
- Custom HTML themes may reference resources not covered by the local-font
  fix. Explicit remote resources still require network access.
- Quarto export is a separate process; the app cannot make an arbitrary
  document render if its own code, data or template is unavailable.

## Editor and document model

- Only QMD/RMD Markdown files are managed. There is no project system, file
  tree, data grid, editable table, resource archive, notebook tabs, debugger or
  arbitrary-language notebook kernel.
- Historical R output and R memory are not saved or restored. Reopening a
  document does not rerun code.
- Images, CSV files and other dependencies are ordinary external references.
  Moving a document does not move or rewrite them.
- Finder Quick Look is read-only, has an 8 MiB source limit and never executes
  code. It shares the editor's native highlighting where possible, but it is
  not a full rendered HTML preview.
- Visual mode is a Markdown presentation, not a pixel-identical Word/LaTeX
  preview. Complex nested lists, unusual HTML and some extension syntaxes are
  shown conservatively.
- Some native layout tests are timing-sensitive on a loaded machine. A single
  failing reading-band test should be rerun in isolation before being treated
  as a product regression.

## Privacy

- No telemetry, analytics or automatic update check is included.
- Remote resources referenced by a document are requested by Quarto/Pandoc as
  part of a render, just like any Quarto installation.
- R help search uses the official online R search endpoint; local help does not
  require R or network.
