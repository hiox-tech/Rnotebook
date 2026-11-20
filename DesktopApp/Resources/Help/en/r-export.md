# Running R and Rendering

Interactive execution supports exploration; Quarto rendering creates a report. Both use document code, but their sessions and execution contexts differ.

## Execution ranges

| Action | Entry point |
| --- | --- |
| Current R chunk | ⌘↩ or the chunk-side Run button |
| Selected code | ⌥⌘↩ |
| All R chunks | ⇧⌘↩ |
| Chunks above or below the caret | Notebook menu / Run menu |
| Interrupt running code | ⌘. or the active Stop button |

Fences must be complete, and the caret/selection must identify runnable R content. Above/Below uses the current position. Common RMD headers such as `{r setup, include=FALSE}` and ordinary R chunks inside Quarto Divs are supported. Math, closed HTML and longer literal fences do not disable unrelated R chunks; example code inside literal regions never runs.

Complex list/quote nesting and HTML-embedded Markdown without a reliable source mapping remain unsupported. An unclosed region can affect the remainder of the document. Unrelated, clearly located chunks can run manually; batches preflight their entire requested range.

## Batch and manual execution

All/Above/Below respects static boolean eval: `#| eval: false` or RMD `eval=FALSE` skips the chunk. Current Chunk, chunk-side Run and selected-code execution are explicit manual actions: they run the specified source, with a status note when eval is disabled. An entirely skipped batch neither starts R nor asks for a save location.

The default is to stop on the first error. `#| error: true` or `error=TRUE` allows ordinary runtime errors to be followed by later expressions and chunks; failures still count as failures. Selected code always stops at the first error. Interrupts, disconnected processes and resource limits always stop execution.

After a batch, hover over the inspector R status or version to see completed, skipped, failed and not-run counts. Skipped chunks retain previous output without counting it as a new success.

## Supported execution controls

Interactive batches read document YAML `knitr.opts_chunk` and `execute`, followed by chunk-header and leading `#|` overrides. Document `execute.enabled: false` disables the whole batch even if a chunk sets eval true; explicit manual actions remain available. Common block/inline mappings, comments and quoted scalars are supported. Labels must be unique and use a supported format.

Only boolean eval/error controls are interpreted statically; parameter expressions are never evaluated. Expression-index vectors, YAML tags/aliases/merges, external metadata and child/code/ref.label substitutions cannot silently turn into ordinary execution: unsupported scheduling configurations stop batch preflight with an explanation. Runtime `knitr::opts_chunk$set()` does not control app scheduling. Use Quarto rendering for full semantics; project configuration is not scanned automatically.

Quarto handles rendering effects of echo/include/warning/message, figure options and cache/freeze. Interactive output remains available for debugging; include false does not skip execution.

## Sessions and variables

Each document has its own R session. The inspector power button starts/stops it; the neighboring button restarts it. Stop and Restart clear variables and ask for confirmation. Interrupting a run is different from ending the whole session.

Variable previews are read-only, lists expand by level and large objects load on demand. Clearing variables also requires confirmation. Save R Workspace explicitly saves RData; saving notebook text does not save R memory. Reopening a notebook does not restore historical output or automatically run code.

The initial working directory is the notebook folder. Use `getwd()` in R to inspect it. Restart the session after changing R or its package library.

Choose Notebook → Restart R and Run All… to check the document in a clean session. Confirm clearing variables; cancelling runs nothing. After confirmation, the current source and batch options are checked again.

## Packages and R help

Choose a CRAN mirror, search for packages, select them and explicitly start installation in the inspector installation sheet. You can also select a local package. The destination library comes from Environment settings.

Inspector help search opens official R search results directly, without requiring R to start or the notebook to be saved. The Help menu retains official R, Quarto and QMD syntax web links.

## Render options

Use the Quarto toolbar button or ⇧⌘E. Choose HTML, Word, PDF/LaTeX or PDF/Typst, select a destination, and optionally open the completed output.

Document YAML is the default parameter source. Choose Custom for grouped document, style, code and figure options. When you return to YAML, hidden custom drafts do not affect rendering or get written to the notebook.

Custom HTML uses the chosen theme with locally available font fallbacks instead of automatically downloading theme web fonts during single-file resource embedding. YAML mode keeps document styling. Remote images, fonts or other resources explicitly referenced by the document can still require a network connection.

## Reproducibility and failures

Rendering reruns code in a separate execution context instead of carrying over interactive objects. Put data loading, package loading and object creation in the notebook, and check relative paths.

Configure the required PDF engine and dependencies first; the app does not automatically install TeX. For missing packages, code errors or output failures, read the render log and address the reported issue. Cancelled or failed work is not published as a successful completed result.

See [Quarto Syntax](rnotebook-help://article/syntax) for Edmund compatibility, and the [Quarto Guide](https://quarto.org/docs/guide/) for complete options.

## Reading results and variables

Run All/Above/Below buffers this batch’s results and displays executed content together when the batch ends or is interrupted. Old results for unexecuted chunks remain and are not counted as new successes. Manually running a chunk still streams output. The sector beside R status counts processed chunks.

Variables load in pages of at most 500 entries; Load More retrieves the rest. Name, type and summary filters cover full session metadata, including unloaded entries. While R is busy, filtering waits for the current operation. Object previews are read-only; clearing variables requires confirmation.
