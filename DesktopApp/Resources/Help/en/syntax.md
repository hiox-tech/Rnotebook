# Quarto Syntax

This reference describes the current Rnotebook editor and export workflow. Code preserves and edits the full source. Visual formats common Markdown and the extensions below. Quarto output also depends on the format, engine and YAML, and may differ from Visual.

## Headings, paragraphs and inline styles

| Purpose | Syntax |
| --- | --- |
| Headings 1–6 | `# Heading` through `###### Heading` |
| Paragraphs | Separate paragraphs with a blank line |
| Hard line break | Two trailing spaces or a trailing backslash |
| Bold, italic, both | `**bold**`, `*italic*`, `***both***` |
| Strikethrough | `~~deleted~~` |
| Highlight | `==important==` |
| Inline code | `` `mean(x)` `` |
| Underline | `<u>text</u>` |
| Superscript, subscript | `<sup>2</sup>`, `<sub>i</sub>` |
| Keyboard label | `<kbd>⌘S</kbd>` |
| Escaped marker | `\*` displays a literal asterisk |

## Lists, tasks, quotes and rules

```markdown
- Item
  - Nested item

1. First step
2. Second step

- [ ] To do
- [x] Done

> Quoted text

---
```

Both rules and YAML may use `---`. A pair at the document start marks YAML; elsewhere Markdown context determines whether it is a rule.

## Links, images and dimensions

```markdown
[Quarto](https://quarto.org/)
[Another notebook](notes.qmd)
[A heading](#section)
![Description](images/plot.png)
![Description|320](images/plot.png)
![Description|320x200](images/plot.png)
[[notes]]
[[notes#section|Display text]]
![[plot.png|320x200]]
```

Import or link images from Insert. File paths are relative to the notebook location. Wiki links do not create a notebook index, add extensions or copy target files. Wiki embeds support images; they do not transclude another document’s contents.

## Tables and footnotes

```markdown
| Measure | Value |
| :--- | ---: |
| Mean | 18 |
| Sample size | 3 |

A note[^note].

[^note]: Footnote text.
```

Ordinary tables are Markdown text. Results produced by R, such as kable/flextable, are runtime previews; saving text does not restore historical output.

## Display code and executable R chunks

Ordinary fences display code. Rnotebook’s interactive execution commands target complete R chunks. The fence label distinguishes their purpose.

````markdown
```text
Display-only text.
```

```r
x <- 1  # Display-only R code
```

```{r}
x <- c(12, 18, 24)
mean(x)
```
````

Quarto chunk options use `#|` lines. The `echo` and `warning` options below are **Quarto rendering options**, not permissions or isolation controls for the interactive session.

````markdown
```{r}
#| label: example
#| echo: true
#| warning: false
summary(iris)
```
````

Close every fence. Prose, other languages and incomplete fences are not automatically run simply because they are present in a document.

Common parameterized RMD headers such as `{r setup, include=FALSE}` are supported. Batches respect static eval false; explicit chunk/selection execution can override it. Error true permits continuation after ordinary errors. See [Running R and Rendering](rnotebook-help://article/r-export) for the full rules.

## YAML document metadata

```yaml
---
title: "Analysis report"
author: "Author"
format:
  html:
    toc: true
execute:
  echo: true
---
```

Place YAML at the document start. Export in YAML mode to use the document configuration, or choose Custom to use the corresponding panel options. Custom drafts are not written back to the notebook. Consult Quarto for all options supported by each format.

## Inline and display math

```markdown
The mean is $\bar{x}$.

$$
E = mc^2
$$
```

Use LaTeX math expressions. Fonts, layout and supported commands may differ between the editor and HTML/Word/PDF; inspect the final output for complex formulas.

## Mermaid diagrams

````markdown
```mermaid
flowchart LR
    A[Prepare data] --> B[Run analysis]
    B --> C[Render report]
```
````

Built-in templates cover flowchart, sequence, class, state, entity-relationship and XY diagrams. Choose them from Insert → Mermaid Diagrams. Mermaid fences describe diagrams and do not run R. Quarto handles Mermaid in exports; the diagram syntax and output format need to be compatible.

## Callouts and collapsible callouts

```markdown
> [!NOTE] Note
> The callout body.

> [!TIP]- Expand this
> A collapsible body.

> [!WARNING]+ Initially expanded
> Check the parameters.
```

Basic types are note, tip, important, warning and caution. Extended types include info, todo, abstract, success, question, failure, danger, bug, example and quote, with aliases. Unknown types remain ordinary quotes. Static exports keep the collapsed body visible rather than reproducing an interactive collapse control.

Native Quarto callouts can also be written in Code and rendered by Quarto. This does not imply identical Visual layouts for every Quarto Div.

```markdown
::: {.callout-note}
A native Quarto callout.
:::
```

## Comments, tags and block anchors

```markdown
<!-- HTML comment -->
%%inline comment%%

%%
A multi-block comment
%%

#research
Paragraph text. ^block-id
```

Tags and block markers are recognized without creating a global tag search or resource index. Comments affect visibility or exported text; **they do not prevent code already executed by R/knitr from running**. Use Quarto execution options to control rendering execution.

## Export compatibility and more QMD syntax

Edmund syntax compatibility is enabled by default for exports. It converts highlighting, comments, callouts/collapse, wiki links/images, dimensions, block anchors and some simple HTML marks. Turn it off in the render panel if desired; user filters are retained. Colors, icons and keyboard styling can differ across formats.

Write citations, cross-references, further Divs and format-specific QMD options in Code for Quarto to process. This guide does not promise full Visual semantic previews or automatic conversion of RMD into another engine’s special semantics.

Continue to the [official QMD syntax guide](https://quarto.org/docs/authoring/markdown-basics.html), [Using R with Quarto](https://quarto.org/docs/computations/r.html), or the [Quick Start](rnotebook-help://article/quick-start).
