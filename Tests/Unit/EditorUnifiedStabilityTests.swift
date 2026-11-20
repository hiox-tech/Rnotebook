import AppKit
import EdmundCore
import XCTest
@testable import Rnotebook

@MainActor final class EditorUnifiedStabilityTests: XCTestCase {
    private func fixture(_ source: String, code: Bool) throws -> (RecordLayoutModel, RecordNativeEditorHost, NSWindow) {
        let suite = "EditorUnified." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = RecordLayoutModel(visualDefaults: defaults, initialSource: source, usesProcessArguments: false)
        model.sourceOnly = code
        let host = RecordNativeEditorHost(model: model, sourceSettings: .init(defaults: defaults), appearanceSettings: .init(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1080, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(host.editor)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            host.detach(); window.close(); await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
        return (model, host, window)
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
    private func click(_ view: NSView, at point: NSPoint? = nil) throws {
        let window = try XCTUnwrap(view.window)
        let point = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true); window.sendEvent(down)
    }
    private func source(_ count: Int) -> String {
        "# Editor stability\n\n" + (1...count).map { i in
            "## Section \(i)\n\nParagraph before \(i).\n\n```{r block-\(i)}\n" + (1...6).map { "row_\(i)_\($0) <- \($0)\n" }.joined() + "```\n\nParagraph after \(i).\n\n"
        }.joined()
    }
    func testResultImageAndPaddingClicksDoNotMoveSourceCaretOrActivateCode() async throws {
        let source = "# Results\n\nRead this paragraph.\n\n```{r result}\n1 + 1\n```\n\nAfter the result.\n"
        let (model, host, window) = try fixture(source, code: false)
        try await settle()
        let block = try XCTUnwrap(model.visualBlocks.blocks(in: source).first)
        let image = NSImage(size: NSSize(width: 300, height: 140), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        model.outputStates[block.id] = .init(hash: block.sourceHash, events: [.image(image)])
        model.outputRevision &+= 1; host.update(); try await settle()
        let shelf = try XCTUnwrap(host.outputs.shelves[block.id])
        let before = NSRange(location: (source as NSString).range(of: "Read this").location, length: 0)
        host.editor.setSelectedRange(before); try await settle()
        func images(_ view: NSView) -> [NSImageView] { (view is NSImageView ? [view as! NSImageView] : []) + view.subviews.flatMap(images) }
        let imageView = try XCTUnwrap(images(shelf).first { $0.frame.width > 100 })
        for point in [NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY), NSPoint(x: 2, y: 2)] {
            try click(imageView, at: point); try await settle()
            XCTAssertEqual(host.editor.selectedRange(), before, "Result image must not position the source caret")
        }
        try click(shelf, at: NSPoint(x: shelf.bounds.maxX - 3, y: shelf.bounds.maxY - 3)); try await settle()
        XCTAssertEqual(host.editor.selectedRange(), before, "Result padding is not code text")
        XCTAssertEqual(model.source, source); XCTAssertEqual(model.notebook.state, .notStarted)
        XCTAssertTrue(window.isVisible)
    }
    func testOutlineTracksReadingBandBeforeHeadingReachesTopEdge() async throws {
        let (_, host, _) = try fixture(source(20), code: false)
        try await settle()
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        let target = (editor.string as NSString).range(of: "## Section 8").location
        editor.scrollCharacterToTop(target); try await settle()
        let band = max(0, scroll.contentSize.height - scroll.contentInsets.top) / 3
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - band + 10))
        scroll.reflectScrolledClipView(scroll.contentView); try await settle()
        let row = host.outline.tree.selectedRow
        let node = try XCTUnwrap(host.outline.tree.item(atRow: row) as? OutlineNode)
        XCTAssertEqual(node.heading.title, "Section 8", "Reading-band tracking must not wait for the heading to leave through the top")
    }
    func testVisualEOFClickAndFirstInsertionHaveMatchingCaretMetrics() async throws {
        let (_, host, _) = try fixture("# Heading\n\nBody.\n\n```{r}\n1\n```\n\n", code: false)
        try await settle()
        let editor = host.editor
        editor.scrollToEndOfDocument(nil); editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)); try await settle()
        let before = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let caretWindow = editor.window!.convertFromScreen(before)
        try click(editor, at: editor.convert(NSPoint(x: caretWindow.minX + 2, y: caretWindow.midY), from: nil)); try await settle()
        let clicked = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        editor.insertText("x", replacementRange: editor.selectedRange()); try await settle()
        let inserted = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        XCTAssertGreaterThan(clicked.height, 0); XCTAssertGreaterThan(inserted.height, 0)
        XCTAssertEqual(clicked.height, inserted.height, accuracy: 1, "EOF insertion line must use the same font metrics before typing")
        editor.insertNewline(nil); try await settle()
        XCTAssertEqual(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil).height, inserted.height, accuracy: 1)
    }
    func testEOFMetricsFollowFontSizeAndCompositionCommitsWithoutSourceLoss() async throws {
        for size in [12.0, 18.0, 24.0] {
            let original = "# 标题\n\n正文。\n\n"
            let (model, host, _) = try fixture(original, code: false)
            model.fontSize = size; host.update(); try await settle()
            let editor = host.editor
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)); try await settle()
            let before = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            editor.insertText("x", replacementRange: editor.selectedRange()); try await settle()
            let latin = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            XCTAssertGreaterThan(before.height, 0)
            XCTAssertEqual(before.height, latin.height, accuracy: 1, "Font size \(size)")
            editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: editor.selectedRange())
            XCTAssertTrue(editor.hasMarkedText())
            editor.insertText("中文", replacementRange: editor.markedRange())
            editor.unmarkText(); try await settle()
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertEqual(editor.string, original + "x中文")
            let committed = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            // Native CJK fallback faces may have different metrics from the
            // selected Latin face; composition must retain a visible caret.
            XCTAssertGreaterThan(committed.height, size * 0.8)
            editor.insertNewline(nil); try await settle()
            XCTAssertEqual(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil).height, before.height, accuracy: 1)
            host.publishCommittedText(); XCTAssertEqual(model.source, original + "x中文\n")
        }
    }
    func testCodeLocalEditsKeepUnchangedVisibleRowsStableAndReleaseToScrolling() async throws {
        try await verifyCodeEdits(count: 180, sections: [2, 90, 178])
    }
    func testLargeCodeLocalEditsAndDeletionKeepScrollRangeUsable() async throws {
        try await verifyCodeEdits(count: 700, sections: [2, 350, 698])
    }
    private func verifyCodeEdits(count: Int, sections: [Int]) async throws {
        let source = source(count)
        let (model, host, _) = try fixture(source, code: true)
        try await settle()
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        for section in sections {
            let token = "row_\(section)_4 <- 4"
            let range = (editor.string as NSString).range(of: token)
            editor.scrollCharacterToTop(range.location)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 180)); scroll.reflectScrolledClipView(scroll.contentView)
            editor.setSelectedRange(NSRange(location: range.upperBound, length: 0)); try await settle()
            for _ in 0..<3 {
                let before = editor.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
                editor.insertNewline(nil)
                for _ in 0..<4 {
                    let after = editor.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
                    XCTAssertEqual(after.minY, before.minY, accuracy: 1, "Code Return section \(section)")
                    try await Task.sleep(for: .milliseconds(16))
                }
                editor.deleteBackward(nil)
                for _ in 0..<4 {
                    let after = editor.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
                    XCTAssertEqual(after.minY, before.minY, accuracy: 1, "Code Backspace section \(section)")
                    try await Task.sleep(for: .milliseconds(16))
                }
            }
            let y = scroll.contentView.bounds.minY
            editor.scrollPageDown(nil); try await settle()
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, y + 100)
        }
        host.publishCommittedText(); XCTAssertEqual(model.source, source)
    }
    func testUserNavigationInterruptsResizeWithoutLeavingViewportTransactionOpen() async throws {
        let (_, host, _) = try fixture(source(180), code: true)
        try await settle()
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        let range = (editor.string as NSString).range(of: "row_90_4 <- 4")
        editor.scrollCharacterToTop(range.location)
        editor.setSelectedRange(NSRange(location: range.upperBound, length: 0)); try await settle()
        host.viewWillStartLiveResize()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        host.viewDidEndLiveResize(); editor.viewDidEndLiveResize(); try await settle()
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let before = scroll.contentView.bounds.minY
        editor.scrollPageDown(nil); try await settle()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, before + 100)
        editor.scrollCharacterToTop(range.location)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 120))
        editor.setSelectedRange(NSRange(location: range.upperBound, length: 0)); try await settle()
        let baseline = editor.firstRect(forCharacterRange: range, actualRange: nil)
        editor.insertNewline(nil); try await settle()
        XCTAssertGreaterThan(baseline.height, 0)
        XCTAssertEqual(editor.firstRect(forCharacterRange: range, actualRange: nil).minY, baseline.minY, accuracy: 1)
    }
    func testLateCodeFoldKeepsItsHeaderVisibleAndCanScrollToEndAfterExpanding() async throws {
        let source = source(180)
        let (model, host, _) = try fixture(source, code: true)
        try await settle()
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        let region = try XCTUnwrap(host.folding.structure.regions.last { $0.kind == .fence })
        editor.setSelectedRange(NSRange(location: region.hidden.location + 5, length: 0))
        editor.scrollCharacterToTop(region.header.location)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 150)); try await settle()
        for _ in 0..<3 {
            host.folding.toggle(region.key); try await settle()
            let rect = editor.firstRect(forCharacterRange: NSRange(location: region.header.location, length: 1), actualRange: nil)
            let viewport = editor.window!.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            XCTAssertGreaterThan(rect.height, 0); XCTAssertGreaterThan(rect.maxY, viewport.minY)
            XCTAssertLessThan(rect.minY, viewport.maxY - scroll.contentInsets.top)
        }
        if host.folding.collapsed.contains(region.key) { host.folding.toggle(region.key) }
        editor.scrollToEndOfDocument(nil); try await settle()
        let end = editor.firstRect(forCharacterRange: NSRange(location: source.utf16.count, length: 0), actualRange: nil)
        XCTAssertGreaterThan(end.height, 0)
        XCTAssertEqual(model.source, source)
    }
    func testNativeSupplementaryFragmentSpacePreservesTextAndEOFMetrics() async throws {
        let source = "# Prototype\n\n```{r}\n1\n```\n\nTail\n"
        let (_, host, _) = try fixture(source, code: false)
        try await settle()
        let editor = host.editor, manager = try XCTUnwrap(editor.textLayoutManager)
        let tail = (source as NSString).range(of: "Tail").location
        let closing = (source as NSString).range(of: "```\n\nTail").location
        manager.ensureLayout(for: manager.documentRange)
        let before = editor.firstRect(forCharacterRange: NSRange(location: tail, length: 1), actualRange: nil)
        editor.paragraphSupplementaryHeights = [closing: 200]
        editor.textStorage?.edited(.editedAttributes, range: NSRange(location: closing, length: 1), changeInLength: 0)
        manager.invalidateLayout(for: manager.documentRange); manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
        let after = editor.firstRect(forCharacterRange: NSRange(location: tail, length: 1), actualRange: nil)
        XCTAssertEqual(before.minY - after.minY, 200, accuracy: 1)
        XCTAssertEqual(editor.string, source); XCTAssertEqual(editor.rawSource, source)
        editor.paragraphSupplementaryHeights = [:]
        editor.textStorage?.edited(.editedAttributes, range: NSRange(location: closing, length: 1), changeInLength: 0)
        manager.invalidateLayout(for: manager.documentRange); manager.ensureLayout(for: manager.documentRange)
        XCTAssertEqual(editor.firstRect(forCharacterRange: NSRange(location: tail, length: 1), actualRange: nil).minY, before.minY, accuracy: 1)
    }

    func testEveryVisibleOutlineRowCanBeClickedWithoutMovingEditorInsertionPoint() async throws {
        let source = source(32)
        let (_, host, window) = try fixture(source, code: false)
        try await settle()
        let editor = host.editor, tree = host.outline.tree, scroll = try XCTUnwrap(editor.enclosingScrollView)
        let selection = editor.selectedRange()
        for index in [1, 14, 31, 3, 20, 7, 32] {
            tree.scrollRowToVisible(index); try await Task.sleep(for: .milliseconds(20))
            let row = tree.rect(ofRow: index)
            let cell = tree.frameOfCell(atColumn: 0, row: index)
            let point = NSPoint(x: cell.minX + min(12, max(2, cell.width / 2)), y: row.midY)
            let hit = window.contentView?.hitTest(tree.convert(point, to: window.contentView?.superview))
            XCTAssertFalse(hit is NSScroller, "Click the actual title cell, outside the overlay scrollbar")
            try click(tree, at: point)
            let heading = try XCTUnwrap(tree.item(atRow: index) as? OutlineNode).heading
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(20))
                let glyph = editor.firstRect(forCharacterRange: NSRange(location: heading.range.location + 3, length: 1), actualRange: nil)
                let visible = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                XCTAssertGreaterThan(glyph.height, 0)
                XCTAssertLessThanOrEqual(glyph.maxY, visible.maxY - scroll.contentInsets.top + 1)
                XCTAssertGreaterThan(glyph.minY, visible.minY)
                XCTAssertEqual(editor.selectedRange(), selection, "Reading navigation must not activate source editing")
                XCTAssertEqual(tree.selectedRow, index)
            }
        }
        XCTAssertEqual(editor.string, source)
    }
    func testResultSpaceDoesNotAlterParagraphAttributesAndSurvivesCodeEditing() async throws {
        let source = "# Results\n\n```{r result}\nx <- 1\n```\n\nTail\n"
        let (model, host, _) = try fixture(source, code: false)
        try await settle()
        let editor = host.editor, block = try XCTUnwrap(model.visualBlocks.blocks(in: source).first)
        let closing = (source as NSString).range(of: "```\n\nTail").location
        let original = try XCTUnwrap(editor.textStorage?.attribute(.paragraphStyle, at: closing, effectiveRange: nil) as? NSParagraphStyle)
        model.outputStates[block.id] = .init(hash: block.sourceHash, events: [.text("output\noutput")])
        model.outputRevision &+= 1; host.update(); try await settle()
        XCTAssertEqual(editor.textStorage?.attribute(.paragraphStyle, at: closing, effectiveRange: nil) as? NSParagraphStyle, original)
        XCTAssertGreaterThan(editor.paragraphSupplementaryHeights[closing] ?? 0, 0)
        let range = (editor.string as NSString).range(of: "x <- 1")
        editor.setSelectedRange(NSRange(location: range.upperBound, length: 0)); editor.insertText("0", replacementRange: editor.selectedRange())
        host.publishCommittedText(); try await settle()
        let newClosing = (editor.string as NSString).range(of: "```\n\nTail").location
        XCTAssertGreaterThan(editor.paragraphSupplementaryHeights[newClosing] ?? 0, 0)
        model.sourceOnly = true; host.update(); try await settle()
        XCTAssertTrue(editor.paragraphSupplementaryHeights.isEmpty)
        model.sourceOnly = false; host.update(); try await settle()
        XCTAssertGreaterThan(editor.paragraphSupplementaryHeights[newClosing] ?? 0, 0)
    }
    func testLateFoldWithOffscreenCaretAndNoTerminalNewlineKeepsLocalContext() async throws {
        let source = source(700).trimmingCharacters(in: .newlines)
        let (_, host, window) = try fixture(source, code: true)
        try await settle()
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        let originalSelection = editor.selectedRange()
        let region = try XCTUnwrap(host.folding.structure.regions.last { $0.kind == .fence })
        editor.scrollCharacterToTop(region.header.location)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 170)); try await settle()
        for _ in 0..<4 {
            host.folding.toggle(region.key)
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(20))
                let line = editor.firstRect(forCharacterRange: NSRange(location: region.header.location, length: 1), actualRange: nil)
                let visible = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                XCTAssertGreaterThan(line.height, 0); XCTAssertGreaterThan(line.maxY, visible.minY)
                XCTAssertLessThan(line.minY, visible.maxY - scroll.contentInsets.top)
                XCTAssertEqual(editor.selectedRange(), originalSelection)
            }
        }
        editor.scrollToEndOfDocument(nil); try await settle()
        let end = editor.firstRect(forCharacterRange: NSRange(location: source.utf16.count, length: 0), actualRange: nil)
        XCTAssertGreaterThan(end.height, 0)
        XCTAssertEqual(editor.string, source)
    }

}
