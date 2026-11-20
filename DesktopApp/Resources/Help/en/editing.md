# Editing and Resources

Code and Visual edit the same source. Choose the view that suits the content, then use the toolbar and menus.

## Code and Visual

Use Code for YAML, longer code and precise markup. Use Visual for prose layout, images, formulas, diagrams and formatting tools. Format commands remain available; you decide whether they suit the current content. Undo can reverse edits.

Switching views does not run R. Set separate fonts and sizes for the two views, and a highlighting theme for Code.

## Folding and navigation

In Code, arrows beside the line numbers fold fenced blocks or sections beneath headings. View offers Toggle Current Fold, Fold All Code Blocks, Fold All Sections and Expand All. Folding only changes the display: saving, copying and running use the complete source. Visual shows the full document; returning to Code retains this window's folds.

Visual has compact heading navigation on the right, in the position occupied by Code's minimap. Click a heading to jump, or use its arrow to expand or collapse child headings. A subtle highlight marks the current section. The formatting toolbar is centered over the text pane.

## Formatting and insertion

Use Format for headings, emphasis, underline, highlighting, lists and quotes. Use Insert for links, images, tables, R/display code, math and Mermaid. Narrow windows move some tools into the overflow menu.

Choose a heading level on an empty line before typing. Formatting changes the Markdown source; switch to Code to inspect the markers.

## R completion and formatting

Press Control-Space inside a complete R chunk to request completion. Turn it off in Settings → Completion if desired. Completion edits text; it does not execute code.

Press ⇧⌘I, choose Edit → Format R Chunk or use the chunk-side format button to format the current complete R chunk. It does not start R and normally uses one Undo step. Finish input-method composition before running the command.

## Find and text size

⌘F opens document Find, ⌥⌘F opens Replace, and ⌘G / ⇧⌘G find the next/previous match. The toolbar magnifying glass also opens Find. A floating bar sits near the bottom of the text pane, clear of the navigation. Enabling Replace expands a second row upward, with current/all replacement, case matching and whole-word options. Only matches are highlighted; the document keeps its colors. Navigating to a folded match reveals it.

Use View to increase, decrease or reset text size for the current editing mode. Code/Visual typography remains independent in Settings.

## Images, data and paths

Import images or use ordinary links. The app does not automatically archive images, data or other dependencies into a project. Organize dependencies with relative paths such as `images/plot.png` and `data/input.csv`.

Maintain references when saving into another folder. R starts in the document directory by default. If your code calls `setwd()`, use `getwd()` to check the actual directory.

See [Quarto Syntax](rnotebook-help://article/syntax) for examples.

In Settings → Formatting, R formatting can follow the nearest `air.toml` or use custom line width, indentation and multiline-call preferences. The block button formats directly without moving the reading caret into code.

## Highlighting and completion preferences

Fonts, Highlighting, Completion and Formatting are directly accessible in the settings toolbar. Default, Ocean, Forest and Warm palettes each adapt to light and dark appearances. Syntax colors, italic comments and bold keywords are optional. Code appearance always follows the interface light/dark appearance. Palettes apply to Code and Visual code blocks without changing the document source.

Completion offers automatic suggestions, delay, minimum prefix length and candidate limits, plus separate parameter-name, signature and current-session-object options. Control-Space still works with automatic suggestions off. Turn off Return acceptance to retain newline behavior; Tab accepts and Esc dismisses. Session-object completion does not start R or execute the notebook.
