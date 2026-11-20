import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class DocumentNavigationTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }
    private func host(_ source: String, code: Bool = true, configuration: RuntimeConfiguration? = nil) throws -> (RecordLayoutModel, RecordNativeEditorHost, NSWindow) {
        let model = RecordLayoutModel(notebookConfiguration: configuration.map { config in { config } }, initialSource: source, usesProcessArguments: false)
        model.sourceOnly = code
        let host = RecordNativeEditorHost(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 840, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(host.editor)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in host.detach(); window.orderOut(nil); window.close(); await model.notebook.shutdown() }
        return (model, host, window)
    }
    private func y(_ offset: Int, _ host: RecordNativeEditorHost) throws -> CGFloat {
        let manager = try XCTUnwrap(host.editor.textLayoutManager)
        let location = try XCTUnwrap(manager.location(manager.documentRange.location, offsetBy: offset))
        manager.ensureLayout(for: try XCTUnwrap(NSTextRange(location: location, end: location)))
        let fragment = try XCTUnwrap(manager.textLayoutFragment(for: location))
        return fragment.layoutFragmentFrame.minY
    }

    func testFindReindexesAfterUnicodeNormalizationChangesUTF16Offsets() async throws {
        let source = "# Title\n\ncaf\u{e9} needle\n"
        let (model, host, _) = try host(source)
        model.findInDocument(action: .showFindInterface)
        host.documentFinder.bar.query.stringValue = "needle"
        host.documentFinder.bar.queryChanged?("needle")
        try await settle()
        XCTAssertEqual(host.documentFinder.matches, [(source as NSString).range(of: "needle")])
        host.editor.insertText("e\u{301}", replacementRange: (source as NSString).range(of: "\u{e9}"))
        host.publishCommittedText()
        try await settle()
        XCTAssertEqual(host.documentFinder.matches, [(host.editor.string as NSString).range(of: "needle")])
        XCTAssertEqual(Data(model.source.utf8), Data("# Title\n\ncafe\u{301} needle\n".utf8))
    }

    func testStructureRespectsLiteralContextsSetextHierarchyAndUTF16() throws {
        let source = "---\ntitle: Test\n# yaml\n---\n\n# 中文😀\n\nText\n\n```{r setup, echo=FALSE}\n# not heading\nx <- 1\n```\n\n### Child\n\nChild body\n\nSetext\n======\n\nTail\n"
        let structure = RecordDocumentStructure(source), ns = source as NSString
        XCTAssertEqual(structure.headings.map(\.title), ["中文😀", "Child", "Setext"])
        XCTAssertEqual(structure.regions.filter { $0.kind == .fence }.count, 1)
        let section = try XCTUnwrap(structure.regions.first)
        XCTAssertEqual(section.hidden.upperBound, ns.range(of: "Setext").location)
        XCTAssertTrue(ns.substring(with: section.hidden).contains("### Child"))
        let setext = try XCTUnwrap(structure.regions.last)
        XCTAssertEqual(ns.substring(with: setext.hidden), "\nTail\n")
        let literals = RecordDocumentStructure("# Real\n\n```text\n# code\n```\n\n$$\n# math\n$$\n\n<!--\n# comment\n-->\n\n<div>\n# html\n</div>\n\n## End\n\nbody\n")
        XCTAssertEqual(literals.headings.map(\.title), ["Real", "End"])
    }

    func testFoldingRemovesRealLayoutHeightAndPreservesFullSourceCopyAndUndo() async throws {
        let source = "# Top\n\n```{r setup}\na <- 1\nb <- 2\nc <- 3\n```\n\n## Child\n\nBody\n\n# End\n\nLast\n"
        let (model, host, _) = try host(source)
        try await settle()
        let ns = source as NSString, end = ns.range(of: "# End").location
        let before = try y(end, host)
        let fence = try XCTUnwrap(host.folding.structure.regions.first { $0.kind == .fence })
        host.folding.toggle(fence.key); try await settle()
        XCTAssertTrue(host.folding.collapsed.contains(fence.key))
        XCTAssertLessThan(try y(end, host), before - 40, "Folded paragraphs must consume no vertical space")
        XCTAssertEqual(host.editor.string, source); XCTAssertEqual(host.editor.rawSource, source); XCTAssertEqual(model.source, source)
        let section = try XCTUnwrap(host.folding.structure.regions.first { $0.kind == .heading })
        host.folding.toggle(section.key); try await settle()
        XCTAssertLessThan(try y(end, host), before - 100)
        host.editor.selectAll(nil); host.editor.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), source)
        host.folding.setAll(collapsed: false); try await settle()
        XCTAssertEqual(try y(end, host), before, accuracy: 1)
        host.editor.setSelectedRange(NSRange(location: ns.range(of: "Last").upperBound, length: 0))
        host.editor.insertText(" edited", replacementRange: host.editor.selectedRange()); host.publishCommittedText()
        host.undoSource(nil); host.publishCommittedText(); XCTAssertEqual(model.source, source)
    }

    func testNestedFoldsRevealAncestorsRetainModeStateAndRemapAfterEdits() async throws {
        let source = "# Parent\n\n## Child\n\n```{r}\nx <- 1\n```\n\n# End\n\nTail\n"
        let (model, host, _) = try host(source)
        host.folding.setAll(collapsed: true); try await settle()
        XCTAssertEqual(host.folding.collapsed.count, 4)
        model.sourceOnly = false; host.update(); try await settle()
        XCTAssertTrue(host.folding.hiddenRanges.isEmpty)
        XCTAssertFalse(host.outline.isHidden); XCTAssertTrue(host.foldGutter.isHidden)
        model.sourceOnly = true; host.update(); try await settle()
        XCTAssertEqual(host.folding.collapsed.count, 4)
        host.folding.reveal((source as NSString).range(of: "x <- 1")); try await settle()
        XCTAssertEqual(host.folding.collapsed, Set(host.folding.structure.regions.filter { $0.title == "End" }.map(\.key)))
        let key = try XCTUnwrap(host.folding.structure.regions.first { $0.kind == .fence }?.key)
        host.folding.toggle(key)
        host.editor.insertText("intro😀\n\n", replacementRange: NSRange(location: 0, length: 0)); host.publishCommittedText()
        XCTAssertTrue(host.folding.collapsed.contains(key + "intro😀\n\n".utf16.count))
        XCTAssertTrue(model.source.contains("x <- 1"))
        let body = (host.editor.string as NSString).range(of: "x <- 1")
        host.editor.setSelectedRange(NSRange(location: body.location, length: 0)); try await settle()
        XCTAssertEqual(host.folding.collapsed, Set(host.folding.structure.regions.filter { $0.title == "End" }.map(\.key)), "Programmatic navigation never leaves an invisible caret")
    }

    func testFindBarFitsTextPaneAndDoesNotDimSyntaxInBothModesAndScrollerStyles() async throws {
        let source = "# Test\n\n```{r}\nx <- 1\n```\n\nword word\n"
        let (model, host, window) = try host(source)
        let scroll = try XCTUnwrap(host.editor.enclosingScrollView)
        for code in [true, false] {
            for style in [NSScroller.Style.overlay, .legacy] {
                model.sourceOnly = code; host.update(); scroll.scrollerStyle = style
                model.findInDocument(action: .showReplaceInterface); try await settle()
                host.layoutSubtreeIfNeeded()
                let bar = host.documentFinder.bar
                let nav = code ? host.minimap.frame : host.outline.frame
                XCTAssertLessThanOrEqual(bar.convert(bar.bounds, to: host).maxX, nav.minX + 1)
                XCTAssertLessThanOrEqual(scroll.contentView.convert(scroll.contentView.bounds, to: host).maxX, nav.minX + 1)
                XCTAssertEqual(scroll.frame, host.bounds, "Keep the full native scroll surface under the toolbar")
                XCTAssertFalse(scroll.isFindBarVisible, "Floating Find never installs a dimming native find bar")
                XCTAssertTrue(host.documentFinder.isPresented)
                window.setContentSize(NSSize(width: 620, height: 500)); try await settle()
                XCTAssertLessThanOrEqual(bar.convert(bar.bounds, to: host).maxX, (code ? host.minimap.frame : host.outline.frame).minX + 1)
                model.findInDocument(action: .hideFindInterface); try await settle()
                XCTAssertFalse(host.documentFinder.isPresented)
            }
        }
        XCTAssertEqual(model.source, source)
    }

    func testFindRevealsFoldedHitsReplacesAndUndoesWithoutLosingSource() async throws {
        let source = "# Section\n\n```{r}\nneedle <- 1\n```\n\n# End\n\nneedle\n"
        let (model, host, window) = try host(source)
        let first = (source as NSString).range(of: "needle")
        host.editor.setSelectedRange(first)
        model.findInDocument(action: .setSearchString)
        host.folding.setAll(collapsed: true); try await settle()
        host.editor.setSelectedRange(NSRange(location: 0, length: 0))
        model.findInDocument(action: .nextMatch); try await settle()
        XCTAssertEqual(host.editor.selectedRange(), first)
        XCTAssertEqual(host.folding.collapsed, Set(host.folding.structure.regions.filter { $0.title == "End" }.map(\.key)))
        XCTAssertGreaterThan(host.editor.firstRect(forCharacterRange: first, actualRange: nil).height, 0)
        model.findInDocument(action: .showReplaceInterface); try await settle()
        XCTAssertFalse(window.firstResponder === host.editor)
        host.documentFinder.bar.replacement.stringValue = "replacement"
        model.findInDocument(action: .replace); host.publishCommittedText()
        XCTAssertTrue(model.source.contains("replacement <- 1"))
        host.undoSource(nil); host.publishCommittedText(); XCTAssertEqual(model.source, source)
    }

    func testOutlineHierarchyCollapseTrackingAndNavigationPreserveText() async throws {
        let source = "# Parent\n\n## Child\n\nBody\n\n### Deep\n\nBody\n\n# Next\n\nEnd\n"
        let (model, host, _) = try host(source, code: false)
        try await settle()
        let tree = host.outline.tree
        XCTAssertEqual(tree.numberOfRows, 4)
        let parent = try XCTUnwrap(tree.item(atRow: 0))
        tree.collapseItem(parent); XCTAssertEqual(tree.numberOfRows, 2)
        host.outline.track(offset: (source as NSString).range(of: "### Deep").location)
        XCTAssertFalse(tree.isItemExpanded(parent)); XCTAssertEqual(tree.selectedRow, 0)
        let selectionBeforeTracking = host.editor.selectedRange()
        try await settle()
        XCTAssertEqual(host.editor.selectedRange(), selectionBeforeTracking, "Tracking must never navigate via delayed selection notifications")
        host.editor.insertText("new text", replacementRange: NSRange(location: source.utf16.count, length: 0))
        host.publishCommittedText(); try await settle()
        XCTAssertEqual(tree.numberOfRows, 2, "Typing must preserve collapsed outline branches")
        tree.expandItem(tree.item(atRow: 0), expandChildren: true)
        tree.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let insertionBeforeNavigation = host.editor.selectedRange()
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: tree.window?.windowNumber ?? 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        tree.keyDown(with: enter); try await settle()
        XCTAssertEqual(host.editor.selectedRange(), insertionBeforeNavigation, "Outline navigation preserves the independent insertion point")
        let target = (source as NSString).range(of: "### Deep").location
        let targetRect = host.editor.firstRect(forCharacterRange: NSRange(location: target + 4, length: 1), actualRange: nil)
        XCTAssertGreaterThan(targetRect.height, 0)
        XCTAssertEqual(tree.selectedRow, 2)
        XCTAssertTrue(model.source.hasPrefix(source))
    }

    func testIncrementalSearchHighlightsOnlyMatchesAndKeepsSelectionThroughRestyles() async throws {
        let source = "# Search\n\nneedle first\n\nneedle second\n"
        let (model, host, window) = try host(source, code: false)
        try await settle()
        model.findInDocument(action: .showFindInterface); try await settle()
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(fieldEditor === host.editor)
        fieldEditor.selectAll(nil); fieldEditor.insertText("needle", replacementRange: fieldEditor.selectedRange())
        try await settle()
        XCTAssertEqual(host.documentFinder.matches.count, 2)
        XCTAssertFalse(host.editor.enclosingScrollView?.isFindBarVisible == true)
        model.findInDocument(action: .nextMatch); try await settle()
        let match = try XCTUnwrap(host.documentFinder.currentMatch)
        XCTAssertEqual(match.length, 6)
        XCTAssertNotNil(host.documentFinder.highlightedIndex, "The current hit stays emphasized while the native finder keeps the insertion point")
        XCTAssertEqual(host.editor.rawSource, source)
        model.findInDocument(action: .hideFindInterface); try await settle()
        XCTAssertEqual(host.editor.selectedRange(), match, "Closing native Find commits its current match as a normal text selection")
        host.editor.rerenderStyles(); try await settle()
        XCTAssertEqual(host.editor.selectedRange(), match, "Appearance and restyling must not collapse the find selection")
        XCTAssertFalse(host.documentFinder.isPresented)
        XCTAssertTrue(host.editor.findMatches.isEmpty)
        XCTAssertFalse(host.editor.findActive)
    }

    func testGutterButtonsFoldVisibleOpenersAndMinimapRevealsHiddenTarget() async throws {
        let source = "# Top\n\n```{r}\na <- 1\nb <- 2\n```\n\n# End\n\nLast\n"
        let (_, host, _) = try host(source)
        try await settle(); host.foldGutter.refresh()
        let fence = try XCTUnwrap(host.folding.structure.regions.first { $0.kind == .fence })
        let button = try XCTUnwrap(host.foldGutter.subviews.compactMap { $0 as? NSButton }.first { $0.tag == fence.key })
        XCTAssertFalse(button.isHidden)
        let content = try XCTUnwrap(host.editor.enclosingScrollView?.contentView)
        XCTAssertLessThanOrEqual(host.foldGutter.frame.maxX, content.frame.minX)
        button.performClick(nil); try await settle()
        XCTAssertTrue(host.folding.collapsed.contains(fence.key))
        host.minimap.navigate(topLine: 4); try await settle()
        XCTAssertFalse(host.folding.collapsed.contains(fence.key))
        XCTAssertEqual(host.editor.rawSource, source)
    }

    func testVisualToolsAreCenteredInTextPaneAndNavigationHasNoTitle() async throws {
        let doc = QMDDocument()
        doc.model.source = "# Title\n\n## Child\n\nBody\n"
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        window.makeKeyAndOrderFront(nil)
        let host = try XCTUnwrap(doc.model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        addTeardownBlock { @MainActor in
            host.detach(); doc.discardRecovery(); doc.updateChangeCount(.changeCleared); doc.close()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        for width in [960.0, 1180, 1440] {
            window.setContentSize(NSSize(width: width, height: 740)); try await settle()
            let toolbar = try XCTUnwrap(doc.model.visualToolbarCursorView)
            let box = host.convert(toolbar.bounds, from: toolbar)
            XCTAssertEqual(box.midX, host.outline.frame.minX / 2, accuracy: 1)
            XCTAssertLessThan(box.maxX, host.outline.frame.minX)
            XCTAssertNil(host.outline.tree.headerView)
            XCTAssertFalse(views(host.outline).compactMap { $0 as? NSTextField }.contains { $0.stringValue == L10n.string("大纲") })
            XCTAssertEqual(host.outline.frame, host.minimap.frame)
            XCTAssertEqual(host.editor.selectedRange(), NSRange(location: 0, length: 0), "Opening or tracking headings must not move the editor to the end")
            XCTAssertGreaterThan(host.editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil).height, 0)
        }
    }

    func testNavigationBackgroundCannotPaintOverAdjacentEditorWithOversizedDirtyRect() throws {
        let navigation = RecordDocumentOutline(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertTrue(navigation.clipsToBounds)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 220, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.magenta.setFill(); NSRect(x: 0, y: 0, width: 220, height: 80).fill()
        let transform = AffineTransform(translationByX: 120, byY: 0)
        (transform as NSAffineTransform).concat()
        // AppKit may provide a dirty rectangle larger than a view's bounds.
        navigation.draw(NSRect(x: -120, y: 0, width: 220, height: 80))
        let adjacent = try XCTUnwrap(bitmap.colorAt(x: 20, y: 40)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(adjacent.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(adjacent.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(adjacent.blueComponent, 1, accuracy: 0.01)
    }

    func testFoldedRMDKeepsLoadedExecutableSourceAndRunsEachChunkOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoldedRMD-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = try XCTUnwrap(NotebookRExecutable.locate(selected: nil))
        let worker = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap"))
        let config = RuntimeConfiguration(executable: executable, workerScript: worker, projectDirectory: root, startupTimeout: 10, taskTimeout: 12)
        let source = "# 中文😀\r\n\r\n```{r setup, include=FALSE}\r\nfold_counter <- 1L\r\n```\r\n\r\n## Next\r\n\r\n```{r second}\r\nfold_counter <- fold_counter + 1L\r\n```\r\n"
        let (model, host, _) = try host(source, configuration: config)
        try await settle(); host.publishCommittedText()
        // The existing editor loader normalizes CRLF before folding is enabled.
        // Compare the committed loaded source so this checks folding, not a new
        // line-ending preservation policy.
        let loaded = host.editor.rawSource
        XCTAssertEqual(loaded, source.replacingOccurrences(of: "\r\n", with: "\n"))
        let jobs = model.notebookJobs(all: true).map(\.request.source)
        host.folding.setAll(collapsed: true); try await settle()
        XCTAssertFalse(host.folding.hiddenRanges.isEmpty)
        XCTAssertEqual(model.notebookJobs(all: true).map(\.request.source), jobs)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 2)
        let result = try await model.notebook.runtime.evaluate(.init(cellID: "check-folds", source: "stopifnot(fold_counter == 2L)"))
        XCTAssertEqual(result.events.last?.payload.status, "completed")
        XCTAssertEqual(host.editor.rawSource, loaded); XCTAssertEqual(model.source, loaded)
    }

    func testFloatingReplacementExpandsUpwardAndReplaceAllHasOneUndo() async throws {
        let source = "# Title\n\nvalue value\n\n```{r}\nvalue <- 1\n```\n"
        let (model, host, window) = try host(source, code: false)
        model.findInDocument(); try await settle()
        let bar = host.documentFinder.bar, compact = bar.frame
        let field = try XCTUnwrap(window.firstResponder as? NSTextView)
        field.selectAll(nil); field.insertText("value", replacementRange: field.selectedRange()); try await settle()
        XCTAssertEqual(host.documentFinder.matches.count, 3)
        bar.replaceToggle.performClick(nil); try await settle()
        XCTAssertEqual(bar.frame.minY, compact.minY, accuracy: 0.1)
        XCTAssertEqual(bar.frame.height, compact.height + 40, accuracy: 0.1)
        XCTAssertEqual(bar.frame.midX, host.outline.frame.minX / 2, accuracy: 0.1)
        XCTAssertLessThan(bar.frame.maxX, host.outline.frame.minX)
        XCTAssertFalse(bar.replacement.isHidden)
        bar.replacement.stringValue = "changed"
        model.findInDocument(action: .replaceAll); host.publishCommittedText(); try await settle()
        XCTAssertEqual(model.source, source.replacingOccurrences(of: "value", with: "changed"))
        host.undoSource(nil); host.publishCommittedText(); try await settle()
        XCTAssertEqual(model.source, source)
        bar.replaceToggle.performClick(nil); try await settle()
        XCTAssertEqual(bar.frame, compact)
        model.findInDocument(action: .hideFindInterface); try await settle()
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(host.editor.enclosingScrollView?.contentInsets.bottom, 0)
    }

    func testOutlineCellsAreCenteredAndUseExactMinimapAccentInBothAppearances() async throws {
        let (_, host, window) = try host("# Parent\n\n## Child\n\nBody\n", code: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            host.outline.selectionAccentColor = .systemRed; host.minimap.selectionAccentColor = .systemRed
            try await settle()
            XCTAssertEqual(host.outline.viewportFillColor.usingColorSpace(.sRGB), host.minimap.viewportFillColor.usingColorSpace(.sRGB))
            let cell = try XCTUnwrap(host.outline.tree.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
            cell.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(cell.textField)
            XCTAssertEqual(field.frame.midY, cell.bounds.midY, accuracy: 0.1)
            XCTAssertEqual(cell.frame.minX, host.outline.tree.frameOfOutlineCell(atRow: 0).maxX + 1, accuracy: 0.1)
            XCTAssertEqual(host.outline.navigationBackground.usingColorSpace(.sRGB), host.editor.backgroundColor.usingColorSpace(.sRGB))
            XCTAssertEqual(host.outline.tree.backgroundColor.usingColorSpace(.sRGB), host.editor.backgroundColor.usingColorSpace(.sRGB))
        }
    }

    func testCodeAndVisualNavigationAlwaysUseTheSameWidth() async throws {
        let (model, host, window) = try host("# Parent\n\n## Child\n\nBody\n", code: true)
        for width in [620.0, 840, 1100] {
            window.setContentSize(NSSize(width: width, height: 640)); try await settle()
            model.sourceOnly = true; host.update(); host.layoutSubtreeIfNeeded()
            let codeWidth = host.minimap.frame.width
            model.sourceOnly = false; host.update(); host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.outline.frame.width, codeWidth)
            XCTAssertEqual(host.outline.frame, host.minimap.frame)
        }
    }

    func testFindHighlightRemainsVisibleInsideCodeAfterReplacementBarExpands() async throws {
        let source = "# Title\n\n```{r}\nneedle <- 1\n```\n\nneedle\n"
        let (model, host, window) = try host(source, code: false)
        window.appearance = NSAppearance(named: .aqua)
        host.appearanceSettings.accent = .blue; host.update()
        try await settle()
        model.findInDocument(); try await settle()
        let field = try XCTUnwrap(window.firstResponder as? NSTextView)
        field.selectAll(nil); field.insertText("needle", replacementRange: field.selectedRange()); try await settle()
        host.documentFinder.bar.replaceToggle.performClick(nil); try await settle()
        let manager = try XCTUnwrap(host.editor.textLayoutManager)
        let match = (source as NSString).range(of: "needle")
        let start = try XCTUnwrap(manager.location(manager.documentRange.location, offsetBy: match.location))
        let end = try XCTUnwrap(manager.location(start, offsetBy: match.length))
        let textRange = try XCTUnwrap(NSTextRange(location: start, end: end))
        var area = NSRect.null
        manager.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
            area = area.union(frame.offsetBy(dx: host.editor.textContainerOrigin.x, dy: host.editor.textContainerOrigin.y))
            return true
        }
        XCTAssertFalse(area.isEmpty)
        let bitmap = try XCTUnwrap(host.editor.bitmapImageRepForCachingDisplay(in: area))
        host.editor.cacheDisplay(in: area, to: bitmap)
        var highlightedPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.blueComponent > 0.8,
                   color.blueComponent - color.redComponent > 0.15 { highlightedPixels += 1 }
            }
        }
        XCTAssertGreaterThan(highlightedPixels, 20, "Actual code glyph background must remain visibly highlighted after expanding Replace")
        XCTAssertEqual(model.source, source)
    }

    func testFloatingFindUsesLiteralUnicodeQueriesAndCaseAndWordOptions() async throws {
        let source = "A.b a.b aXb xa.b 中文词 中文词尾\n"
        let (model, host, _) = try host(source, code: false)
        model.findInDocument(); try await settle()
        let bar = host.documentFinder.bar
        bar.query.stringValue = "a.b"; bar.queryChanged?("a.b"); try await settle()
        XCTAssertEqual(host.documentFinder.matches.count, 3)
        bar.wholeWord = true; bar.optionsChanged?(); try await settle()
        XCTAssertEqual(host.documentFinder.matches.count, 2)
        bar.caseSensitive = true; bar.optionsChanged?(); try await settle()
        XCTAssertEqual(host.documentFinder.matches.count, 1)
        bar.query.stringValue = "中文词"; bar.queryChanged?("中文词"); try await settle()
        XCTAssertEqual(host.documentFinder.matches.count, 1)
        XCTAssertEqual((source as NSString).substring(with: try XCTUnwrap(host.documentFinder.matches.first)), "中文词")
        XCTAssertEqual(model.source, source)
    }
}
