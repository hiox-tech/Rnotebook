# Saving, Recovery and Settings

Notebook text, recovery drafts, R memory and exported reports are different things. Their save behavior matters when external changes occur.

## Save and Auto Save

⌘S saves; ⇧⌘S saves as another file. Write before naming a new document if you prefer. A native Save panel establishes its location before the first run or render. Saving into another directory does not automatically copy images or data.

Settings → Document enables Auto Save for named files by default: about 1 second after typing stops and at most every 5 seconds during continuous input. Choose an idle delay of 0.5/1/2/5 seconds and a maximum interval of 5/10/30/60 seconds. With Auto Save off, save manually and choose Save, Don’t Save or Cancel when closing modified documents.

## External changes and comparison

Changes without conflicts are automatically reloaded or merged using a common baseline. Turn automatic reload off to review changes first. External monitoring and pre-write checks remain active regardless of Auto Save.

Saving pauses on a conflict. Review complete versions with line numbers, orange/green differences, previous/next change, synchronized scrolling and the common base:

- **Use External Version** loads disk content and replaces the editor content.
- **Use Editor Version** writes the editor content to the file.
- **Decide Later** keeps saving paused. Reopen the comparison from File → Document Sync → Compare Versions.

Both versions are checked again before applying the choice. An external version cannot be selected when the file is missing. Reading the comparison does not execute code.

## Recovery and cache

Private recovery protection keeps unsaved edits even when Auto Save is off. After an interruption, use File → Recover Unsaved Documents… or Settings → General → Manage Recovery Drafts…. Recovery opens a copy instead of directly overwriting the original; it does not restore R memory or historical output.

Settings → General can clear finished task caches. Running tasks, recovery drafts, package libraries and user files are protected from cache cleanup. Clearing cache does not delete notebooks or uninstall packages.

## Window and editing preferences

Document window size, position and inspector width are remembered by default; new documents use the most recent layout. Settings retains its position and selected page. Turn memory off in Settings → Document, or restore the current default layout from Window.

General controls language, appearance, accent and storage. Document controls autosave, external changes and window memory. Fonts, Highlighting, Completion and Formatting each have a separate page. Environment selects Rscript, Quarto and the R package library. Restart R after changing R or its package library.

## Finder preview

Preview QMD/RMD files with Finder Quick Look and switch between Code and Visual. Preview is read-only, does not run R and supports scrolling long documents. Open a document window to edit or run code.
