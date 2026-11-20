import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class EditorViewportStabilityTests: XCTestCase {
    private func fixture(code: Bool) throws -> (QMDDocument, NSWindow, RecordNativeEditorHost) {
        let document = QMDDocument()
        let suite = "ViewportStability." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        document.sourceSettings = SourceEditorSettings(defaults: defaults)
        document.visual = VisualEditorSettings(defaults: defaults)
        document.appearance = AppearanceSettings(defaults: defaults)
        document.model.source = "# Viewport stability\n\n" + (1...14).map { i in
            "## Section \(i)\n\nParagraph before block \(i).\n\n```{r}\n#| label: block-\(i)\nvalue_\(i) <- 1\nvalue_\(i) + 2\n```\n\nParagraph after block \(i).\n\n"
        }.joined()
        document.model.sourceOnly = code
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.setContentSize(NSSize(width: 1100, height: 760))
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let host = try XCTUnwrap(document.model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        window.makeFirstResponder(host.editor)
        addTeardownBlock { @MainActor in
            document.updateChangeCount(.changeCleared); document.close()
            defaults.removePersistentDomain(forName: suite)
        }
        return (document, window, host)
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
    private func snapshot(_ view: NSView, name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".local/validation/editor-viewport-2026-11-15")
        let rect = view.visibleRect
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }

    func testVisualReturnAndBackspaceInNonterminalBlocksKeepVisibleTextStable() async throws {
        let (document, _, host) = try fixture(code: false)
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        try await settle()
        let original = document.model.source
        for block in [2, 7, 13] {
            let token = "value_\(block) <- 1"
            let range = (editor.string as NSString).range(of: token)
            editor.scrollCharacterToTop(range.location)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 180))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            try await settle()
            for iteration in 0..<3 {
                let anchor = (editor.string as NSString).range(of: token).location
                let baseline = editor.firstRect(forCharacterRange: NSRange(location: anchor, length: 1), actualRange: nil)
                XCTAssertGreaterThan(baseline.height, 0)
                if block == 2 && iteration == 0 { try snapshot(editor, name: "before-return") }
                editor.insertNewline(nil)
                for tick in 0..<8 {
                    try await Task.sleep(for: .milliseconds(20))
                    let rect = editor.firstRect(forCharacterRange: NSRange(location: anchor, length: 1), actualRange: nil)
                    if tick == 0 {
                        if block == 2 && iteration == 0 { try snapshot(editor, name: "after-return") }
                    }
                    XCTAssertGreaterThan(rect.height, 0)
                    XCTAssertEqual(rect.minY, baseline.minY, accuracy: 1, "Return in block \(block); clip \(scroll.contentView.bounds)")
                }
                editor.deleteBackward(nil)
                for _ in 0..<8 {
                    try await Task.sleep(for: .milliseconds(20))
                    let rect = editor.firstRect(forCharacterRange: NSRange(location: anchor, length: 1), actualRange: nil)
                    XCTAssertGreaterThan(rect.height, 0)
                    XCTAssertEqual(rect.minY, baseline.minY, accuracy: 1, "Backspace in block \(block); clip \(scroll.contentView.bounds)")
                }
            }
            let start = (editor.string as NSString).range(of: token).location
            let preceding = (editor.string as NSString).lineRange(for: NSRange(location: start - 1, length: 0)).location
            editor.setSelectedRange(NSRange(location: start, length: 0)); try await settle()
            let above = editor.firstRect(forCharacterRange: NSRange(location: preceding, length: 1), actualRange: nil)
            editor.insertNewline(nil); try await settle()
            let unchanged = editor.firstRect(forCharacterRange: NSRange(location: preceding, length: 1), actualRange: nil)
            XCTAssertEqual(unchanged.minY, above.minY, accuracy: 1)
            editor.deleteBackward(nil); try await settle()
        }
        XCTAssertEqual(document.model.source, original)
        XCTAssertEqual(document.model.notebook.state, .notStarted)
    }

    func testInitialCodeTextDoesNotMoveHorizontallyAfterFirstScroll() async throws {
        let (_, window, host) = try fixture(code: true)
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        var samples: [CGFloat] = []
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            let rect = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            if rect.height > 0 {
                // The window itself can move while SwiftUI applies its initial
                // size. Compare glyphs within the clip, and against the ruler.
                let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                samples.append(rect.minX - viewport.minX)
                if let ruler = scroll.verticalRulerView, scroll.rulersVisible {
                    let gutter = window.convertToScreen(ruler.convert(ruler.bounds, to: nil))
                    XCTAssertGreaterThanOrEqual(rect.minX, gutter.maxX, "Initial text must not overlap the ruler")
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(samples.isEmpty)
        try snapshot(host, name: "code-initial")
        let before = samples.last ?? 0
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let after = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        let afterX = after.minX - viewport.minX
        for x in samples { XCTAssertEqual(x, afterX, accuracy: 1, "Initial glyph starts must agree with settled glyph position") }
        XCTAssertEqual(before, afterX, accuracy: 1)
        if let ruler = scroll.verticalRulerView, scroll.rulersVisible {
            let gutter = window.convertToScreen(ruler.convert(ruler.bounds, to: nil))
            XCTAssertGreaterThanOrEqual(after.minX, gutter.maxX)
        }
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        try snapshot(host, name: "code-after-scroll")
    }

    func testEditAnchorReleasesForLiveScrollNavigationAndModeSwitch() async throws {
        let (document, _, host) = try fixture(code: false)
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        try await settle()
        let range = (editor.string as NSString).range(of: "value_7 <- 1")
        editor.scrollCharacterToTop(range.location)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 180))
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        try await settle()
        editor.insertNewline(nil); try await settle()
        let origin = scroll.contentView.bounds.origin
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: origin.y + 140))
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, origin.y + 140, accuracy: 1)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let target = (editor.string as NSString).range(of: "value_13 <- 1")
        editor.setSelectedRange(NSRange(location: target.location, length: 0))
        editor.scrollCharacterToTop(target.location); try await settle()
        let caret = editor.firstRect(forCharacterRange: NSRange(location: target.location, length: 1), actualRange: nil)
        XCTAssertGreaterThan(caret.height, 0)
        for code in [true, false] {
            document.model.sourceOnly = code; host.update(); try await settle()
            XCTAssertEqual(editor.selectedRange().location, target.location)
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        }
        XCTAssertEqual(document.model.notebook.state, .notStarted)
    }

    func testEditsWithMountedResultsKeepTheirLineStableAndUndoSource() async throws {
        let (document, _, host) = try fixture(code: false)
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        try await settle()
        let block = try XCTUnwrap(host.outputs.blocks().first)
        var state = RecordOutputLayout.State(hash: block.sourceHash)
        state.isSample = false; state.events = [.text("Existing result\n42")]
        document.model.outputStates[block.id] = state
        host.outputs.apply(); try await settle()
        let source = document.model.source
        let range = (editor.string as NSString).range(of: "value_7 <- 1")
        editor.scrollCharacterToTop(range.location)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 180))
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        try await settle()
        let before = editor.firstRect(forCharacterRange: range, actualRange: nil)
        editor.insertNewline(nil); try await settle()
        let after = editor.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
        XCTAssertGreaterThan(after.height, 0)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1)
        XCTAssertGreaterThan(host.outputs.height(block.id), 0)
        host.undoSource(nil); try await settle()
        XCTAssertEqual(document.model.source, source)
        XCTAssertEqual(document.model.notebook.state, .notStarted)
    }

    func testLongInsertionStillRevealsCaretAndExplicitPageScrollMovesViewport() async throws {
        let (_, window, host) = try fixture(code: false)
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        try await settle()
        let range = (editor.string as NSString).range(of: "value_7 <- 1")
        editor.scrollCharacterToTop(range.location)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 180))
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        try await settle()
        editor.insertText(String(repeating: "\nvalue <- 1", count: 50), replacementRange: editor.selectedRange())
        try await settle()
        let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let visible = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        XCTAssertGreaterThan(caret.height, 0)
        XCTAssertGreaterThanOrEqual(caret.minY, visible.minY)
        XCTAssertLessThanOrEqual(caret.maxY, visible.maxY - scroll.contentInsets.top)
        let origin = scroll.contentView.bounds.minY
        editor.scrollPageDown(nil); try await settle()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, origin + 100)
    }
}
