# Architecture

Rnotebook is a single native macOS application with one embedded Quick Look
extension. It deliberately has no project system, data grid, resource archive
or telemetry service.

## Modules

| Module | Responsibility |
| --- | --- |
| `Documents` | QMDDocument lifecycle, autosave, recovery, external-change detection, merge/compare, window state |
| `Editor` | Cell index, fence scanner, syntax preferences, source typography, Markdown/R highlighting |
| `AppShell` | Window shell, native editor host, toolbar, find, outline, minimap, result layout, inspector |
| `LanguageServices` | Tree-sitter highlighting, Raven LSP completion, Air formatting, completion controller |
| `NotebookRuntime` | R process channel, runtime envelopes, execution policy, inspector, cache, workspace save, bundled runtime discovery |
| `NotebookExport` | Quarto render options, YAML/custom parameter routing, Edmund compatibility filter, export engine |
| `Help` | Native help browser, local articles, guides, About and third-party notices |
| `Localization` | Chinese/English resources, native settings pages and environment dependency checks |
| `Preview` | Embedded sandboxed Quick Look controller with Code/Visual source preview |
| `Storage` | Bounded cache tasks, recovery data and application-support locations |
| `QuickLook` | Finder extension Info.plist and localizations |

Third-party source lives in `ThirdParty/`: EdmundCore (editor/TextKit 2),
swift-markdown, cmark-gfm, SwiftMath, Tree-sitter and the native R/Markdown
grammars, Air and Raven.

## Document and editor flow

```text
QMD/RMD file
  → QMDDocument / QMDFileSynchronization
  → RecordLayoutModel
  → RecordNativeEditorHost
      ├─ EditorTextView (TextKit 2, shared Code/Visual source)
      ├─ RecordRSyntaxAdapter (Tree-sitter code blocks)
      ├─ RecordCodeFolding / RecordDocumentOutline / RecordSourceMinimap
      ├─ RecordEditorFinder (draw-only search highlights)
      ├─ RCompletionController → Raven
      └─ RecordOutputLayout (native result shelves)
```

The editor stores the exact QMD/RMD source. Code mode and Visual mode apply
different presentation attributes to the same source; there is no second
document model. Source edits are reconciled through the document controller
and autosaved only after the editor and model agree byte-for-byte.

Search highlights are a background-only render artifact. They never write to
text storage and are computed only from already-laid-out line fragments, so
opening Find cannot force layout or move an in-progress edit.

## R execution

```text
NotebookExecution
  → NotebookExecutionPolicy (static eval/error, manual overrides)
  → RProcessChannel (one Worker per document)
  → private Rscript or user-selected Rscript
  → evaluated blocks → response frames → RecordOutputLayout
```

Each document has an independent R session. The app does not restore R
memory, historical output or hidden project state. Results are visible only
for the current session. Completion uses a separate lazy Raven process; Air
formatting is a one-shot child process.

## Quarto export

Export writes a temporary source snapshot and invokes Quarto with explicit
paths. It never edits the user's document. The bundled Edmund Lua filter runs
in a pre-AST pass to preserve editor features; custom YAML parameter files are
merged through a temporary metadata file. HTML/Word/Typst/LaTeX output is
published atomically only after a successful render and target revalidation.

## Offline runtime

`NotebookBundledRuntime` knows one optional installer location:

```text
/Library/Rnotebook/
  R.framework/                 R 4.6.2
  R/library/                   basic and shared R packages
  quarto/                      Quarto 1.10.18
  TinyTeX/                     TeX Live 2026
  chrome-headless-shell/       Chrome Headless Shell
  licenses/                    runtime licenses and package manifest
  runtime-manifest.json
```

A path explicitly chosen in Settings always wins. Otherwise the app tries the
private runtime, then the system R/Quarto. When the private runtime is used,
the R process receives `R_LIBS` with the user library first and the shared
runtime library second; Quarto receives private R, TeX and Chrome paths through
its environment. User packages stay in
`~/Library/Application Support/Rnotebook/R/library`; user TeX packages use
`~/Library/Application Support/Rnotebook/texmf`.

## Storage and privacy

- Documents are plain QMD/RMD files. There is no sidecar project or resource
  directory.
- Cache tasks live under `~/Library/Caches/org.hiox.Rnotebook`, are protected by
  process locks and are bounded/cleaned by policy.
- Unsaved recovery is private application data under Application Support.
- Rnotebook does not include telemetry or an update service. Remote images,
  online data and R packages not present in the offline bundle remain the
  user's responsibility.
