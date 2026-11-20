# Quarto Syntax

**A compact reference · Copy into Code and adapt**

## Text and mathematics

| Purpose | Syntax |
| --- | --- |
| Headings and paragraphs | `# Heading`, `## Section`; leave a blank line between paragraphs |
| Text | `**bold**`, `*italic*`, `~~strike~~`, backticks for inline code |
| Lists and tasks | `- Item`, `1. Step`, `- [ ] Task` |
| Quote | `> Quoted text` |
| Links and images | `[Text](https://example.com)`, `![Caption](images/plot.png)` |
| Math | `$x^2$`; put display math between separate `$$` lines |
| Footnote | `Text[^1]` and a final `[^1]: Footnote text` |

## A report skeleton

````markdown
---
title: "Analysis report"
lang: en-US
format:
  html:
    toc: true
    number-sections: true
execute:
  echo: true
---

## Results {#sec-results}

```{r}
#| label: fig-trend
#| fig-cap: "Measurement trend"
#| echo: false
plot(1:5)
```

See @fig-trend and @sec-results.
````

## R block options

Inside an R chunk, prefix each option with `#|`, for example `#| echo: false`.

| Option | Effect |
| --- | --- |
| `echo: false` | Hide code in the report; retain results |
| `eval: false` | Skip batch execution/rendering; manual execution still works |
| `include: false` | Compute during rendering, but hide code and results |
| `warning: false` | Hide report warnings; `message: false` controls messages |
| `fig-width: 6` | Width in inches; use `fig-height: 4` for height |
| `label: tbl-summary` | Pair with `tbl-cap`; cite the table as `@tbl-summary` |

## Tables, callouts and diagrams

A Markdown table starts with `| Name | Value |`, then `| --- | ---: |`, then data rows. The `{r}` fence executes R; a plain `r` fence displays code only. A `mermaid` fence can contain `flowchart TD` followed by `A --> B`.

Start a callout with `::: {.callout-note}` and close with a separate `:::`. Indent YAML and `#|` options with spaces; reference labels must be unique. `.Rmd` commonly places options in headers such as `{r, echo=FALSE}`; the YAML and `#|` example above targets Quarto `.qmd`.
