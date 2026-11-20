# Third-party components and licenses

Rnotebook itself is MIT licensed. The application and the optional offline
runtime include the following components under their own licenses. Original
license/notice files are installed in the app bundle
(`Contents/Resources/ThirdPartyNotices`) and in
`/Library/Rnotebook/licenses`; pinned source/checksum records are under
`ThirdParty/` and `ThirdParty/LanguageTools/SOURCES.json`.

## Application dependencies

| Component | Version / pin | License | Use |
| --- | --- | --- | --- |
| Edmund / EdmundCore | pinned source + recorded host patches | Apache-2.0 | Native Markdown editor and TextKit 2 presentation |
| swift-markdown | local pinned package | Apache-2.0 + NOTICE | Visual Markdown parsing |
| cmark-gfm | local pinned package | BSD/MIT notices | CommonMark parsing |
| SwiftMath | local pinned package | MIT | Math typesetting |
| Air | 0.13.0 official release | MIT | R code formatting |
| Raven | 0.21.1 + reviewed patch | GPL-3.0 | R completion language server |
| Tree-sitter | 0.25.10 | MIT | Parsing runtime |
| tree-sitter-r | pinned commit | MIT | R grammar |
| tree-sitter-markdown | 0.5.3 | MIT | Markdown grammar |
| Mermaid / elkjs / entities / beautiful-mermaid | bundled resources | See notices | Diagram rendering support |
| STIX / GUST / math fonts | bundled with SwiftMath | SIL OFL 1.1 / see notices | Math fonts |
| Unicode data | bundled | Unicode license | Character data |

Raven is GPL-3.0. The unmodified upstream source archive, Cargo.lock and the
reviewed patch are included in `ThirdParty/LanguageTools/`; the rebuilt binary
is distributed under the same license. See
`ThirdParty/LanguageTools/README.md` for the rebuild procedure.

## Offline runtime components

The four installers in `dist/` include the following optional payloads.

| Component | Version | License / source |
| --- | --- | --- |
| R | 4.6.2 (arm64 and x86_64 CRAN builds) | GPL-2.0-or-later; https://cran.r-project.org/src/base/R-4/R-4.6.2.tar.gz |
| Basic R packages | evaluate 1.0.5, jsonlite 2.0.0, rlang 1.3.0, knitr 1.52, rmarkdown 2.32 and recursive dependencies | Each package's DESCRIPTION/license; source available from CRAN |
| Quarto | 1.10.18 | MIT; https://github.com/quarto-dev/quarto-cli/releases/tag/v1.10.18 |
| TinyTeX / TeX Live | 2026.11 / TeX Live 2026 | TeX Live and CTAN collection licenses; see `LICENSE.TL` and `LICENSE.CTAN` in `/Library/Rnotebook` |
| Chrome Headless Shell | 158.0.8127.36 | Chromium/Chrome for Testing license; see `LICENSE.headless_shell` |

Exact source download URLs and SHA-256 checksums are recorded in
`/Library/Rnotebook/runtime-manifest.json` after installation. The package
versions are also listed in `/Library/Rnotebook/R-PACKAGES.tsv`.

## Rebuilding / source availability

- Air: official release archive checksum in
  `ThirdParty/LanguageTools/SOURCES.json`; extract the binary and retain
  `AIR-LICENSE`.
- Raven: build from `raven-0.21.1-source.tar.gz` with
  `scripts/rebuild-raven.py`; retain `RAVEN-LICENSE`.
- R: use the matching CRAN `R-4.6.2-{arm64,x86_64}.pkg` and
  `scripts/prepare-private-runtime.py`; the R source is available from CRAN.
- Quarto/TinyTeX: use the exact releases listed above; their source and
  licenses are available from the upstream projects.
- Chrome Headless Shell: use the Chrome for Testing version listed above;
  keep the archive's `LICENSE.headless_shell`.

If you redistribute a modified version, preserve these notices and provide the
corresponding source for GPL components as required by their licenses.
