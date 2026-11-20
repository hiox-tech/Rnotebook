# Quick Start

**New notebook → Write → Run R → Render a report**

## Get ready

⌘N creates a notebook; ⌘S names it `.qmd` or `.Rmd`. Check Rscript, Quarto and required R packages in **Settings → Environment**. You can start writing without them.

## Your first runnable notebook

Copy this into Code; switch to Visual to read it. Place the caret inside the R block and press ⌘↩. The result is **18**; `x` appears in Variables.

````markdown
---
title: "My first notebook"
format: html
---

# Measurements

```{r}
x <- c(12, 18, 24)
mean(x)
```
````

## Everyday actions

| Task | Action |
| --- | --- |
| Write and read | Edit source in Code; use formatting tools and outline in Visual |
| Find and replace | ⌘F; expand Replace; arrows move to the previous/next hit |
| Run and interrupt | ⌘↩ current R block; ⇧⌘↩ all blocks; ⌘. interrupts |
| Format R | Use the block button; adjust style in Settings → Formatting |
| Inspect objects | Filter and preview in Variables; Load More shows later objects |

## Render and share

⇧⌘E opens rendering. Choose a format, destination and parameter source. **HTML** is easy to share, **Word** supports collaboration, and **Typst PDF** provides print output; LaTeX PDF needs a suitable TeX installation. Rendering recomputes according to document settings and does not read interactive results.

## Keep in mind

- Named notebooks autosave by default. External changes can merge; conflicts open a comparison.
- R objects belong to the current session. Save R Workspace exports `.RData`; stopping or restarting clears variables.
- Data and images remain ordinary files. Prefer relative paths and share those files too. Reopening a notebook does not run R or restore earlier results.
