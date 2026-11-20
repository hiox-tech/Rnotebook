import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class WindowAcceptanceTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(220)) }
    private func window(source: String? = nil) throws -> (QMDDocument, NSWindow) {
        let doc = QMDDocument()
        let suite = "WindowAcceptance." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        doc.sourceSettings = SourceEditorSettings(defaults: defaults)
        doc.visual = VisualEditorSettings(defaults: defaults)
        doc.appearance = AppearanceSettings(defaults: defaults)
        doc.model.source = source ?? (1...120).map { "第 \($0) 行，编辑器正文。\n" }.joined(separator: "\n")
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            doc.updateChangeCount(.changeCleared); doc.close()
            defaults.removePersistentDomain(forName: suite)
        }
        return (doc, window)
    }
    func testFullViewportInsetsKeepFirstTextBelowNativeAndVisualToolbars() async throws {
        let (doc, window) = try window()
        try await settle(); window.contentView?.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(doc.model.activeEditor), scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertGreaterThan(doc.model.windowTopInset, 0)
        XCTAssertEqual(scroll.contentInsets.top, doc.model.windowTopInset + 64, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, -scroll.contentInsets.top, accuracy: 1)
        let frame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertGreaterThan(frame.maxY, window.contentLayoutRect.maxY, "The viewport extends under the native toolbar")
        doc.model.sourceOnly = true
        try await settle()
        XCTAssertEqual(scroll.contentInsets.top, doc.model.windowTopInset, accuracy: 1)
        editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.scrollRangeToVisible(editor.selectedRange())
        let first = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let safeTop = window.convertToScreen(window.contentLayoutRect).maxY
        XCTAssertLessThanOrEqual(first.maxY, safeTop + 1)
        XCTAssertGreaterThan(first.minY, window.frame.minY)
    }
    func testResizingAppearanceFontAndScrollingPreserveTextAndVisibleCaret() async throws {
        let (doc, window) = try window(), source = doc.model.source
        for (width, height, appearance) in [(960.0,640.0,InterfaceAppearance.light), (1160,760,.dark), (1440,900,.light)] {
            window.setContentSize(NSSize(width: width, height: height)); doc.appearance.interface = appearance
            for code in [false, true] {
                doc.model.sourceOnly = code; doc.sourceSettings.fontSize = 24; doc.visual.bodySize = 24
                try await settle(); window.contentView?.layoutSubtreeIfNeeded()
                let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
                XCTAssertEqual(split.splitViewItems.count, 2)
                XCTAssertFalse(split.splitViewItems[1].isCollapsed)
                XCTAssertGreaterThanOrEqual(split.splitViewItems[1].viewController.view.bounds.width, 259)
                let editor = try XCTUnwrap(doc.model.activeEditor)
                let host = try XCTUnwrap(editor.enclosingScrollView?.superview as? RecordNativeEditorHost)
                if code {
                    XCTAssertFalse(host.minimap.isHidden)
                    let overview = host.minimap.convert(host.minimap.bounds, to: nil)
                    XCTAssertEqual(overview.maxY, window.contentLayoutRect.maxY, accuracy: 1,
                        "The minimap begins below the native toolbar after resizing or changing modes")
                    XCTAssertEqual(overview.minY, host.convert(host.bounds, to: nil).minY, accuracy: 1)
                } else {
                    XCTAssertTrue(host.minimap.isHidden)
                }
                let end = NSRange(location: editor.string.utf16.count, length: 0)
                editor.setSelectedRange(end); editor.scrollRangeToVisible(end)
                try await settle()
                var caret = editor.firstRect(forCharacterRange: end, actualRange: nil)
                // TextKit may not have published the new viewport geometry
                // after a font/mode change. Wait for measurement readiness;
                // do not reveal the selection again or relax the screen bounds.
                for _ in 0..<5 where caret.height == 0 {
                    editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                    caret = editor.firstRect(forCharacterRange: end, actualRange: nil)
                }
                let safe = window.convertToScreen(window.contentLayoutRect)
                XCTAssertGreaterThan(caret.height, 0, "Measure a real caret after viewport layout")
                XCTAssertLessThanOrEqual(caret.maxY, safe.maxY + 1)
                XCTAssertGreaterThanOrEqual(caret.minY, safe.minY - 1,
                    "mode=\(code ? "Code" : "Visual"),size=\(width)x\(height),caret=\(caret),safe=\(safe),editor=\(editor.frame),scroll=\(editor.enclosingScrollView?.contentView.bounds ?? .zero)")
                XCTAssertEqual(doc.model.source, source)
            }
        }
    }
    func testWindowCommandRoutingAndModeControlTracksModel() async throws {
        let (first, a) = try window(), (second, b) = try window()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
        XCTAssertFalse(a === b)
        for window in [a, b] {
            XCTAssertEqual(window.tabbingMode, .disallowed)
            XCTAssertTrue(window.isVisible)
            XCTAssertLessThanOrEqual(window.tabbedWindows?.count ?? 0, 1)
        }
        a.makeKeyAndOrderFront(nil); try await settle()
        XCTAssertTrue(NotebookCommandContext.shared.target(in: a) === first.model)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: a)
        XCTAssertTrue(NotebookCommandContext.shared.model === first.model)
        b.makeKeyAndOrderFront(nil); try await settle()
        XCTAssertTrue(NotebookCommandContext.shared.target(in: b) === second.model)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: b)
        XCTAssertTrue(NotebookCommandContext.shared.model === second.model)
        second.model.sourceOnly = true; try await settle()
        let item = try XCTUnwrap(b.toolbar?.items.first { $0.itemIdentifier.rawValue == "mode" })
        XCTAssertEqual((item.view as? NSSegmentedControl)?.selectedSegment, 0)
        a.makeKeyAndOrderFront(nil); try await settle()
        XCTAssertTrue(NotebookCommandContext.shared.target(in: a) === first.model)
        let menu = try XCTUnwrap(NSApp.windowsMenu)
        menu.update()
        let tabActions: Set<Selector> = [#selector(NSWindow.toggleTabBar(_:)), #selector(NSWindow.toggleTabOverview(_:)),
            #selector(NSWindow.mergeAllWindows(_:)), #selector(NSWindow.moveTabToNewWindow(_:)),
            #selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.selectPreviousTab(_:))]
        XCTAssertFalse(menu.items.contains { $0.action.map(tabActions.contains) ?? false })
        XCTAssertTrue(menu.items.contains { $0.action == #selector(NSWindow.performMiniaturize(_:)) })
    }
    func testPendingViewStateClampsSelectionAndScrollForChangedText() async throws {
        let (doc, window) = try window()
        try await settle()
        doc.model.pendingViewState = .init(sourceOnly: false, location: 99999, length: 99999, scrollY: 999999)
        let host = try XCTUnwrap(doc.model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        host.viewDidMoveToWindow(); try await settle()
        let editor = try XCTUnwrap(doc.model.activeEditor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertNil(doc.model.pendingViewState)
        XCTAssertTrue(window.isVisible)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, editor.frame.height)
    }

    func testCodeToolbarSeparatorFollowsInsetAdjustedScrollPosition() async throws {
        let (doc, window) = try window(), source = doc.model.source
        doc.model.sourceOnly = true
        try await settle()
        let editor = try XCTUnwrap(doc.model.activeEditor)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let host = try XCTUnwrap(scroll.superview as? RecordNativeEditorHost)
        for width in [960.0, 1440, 1160] {
            window.setContentSize(NSSize(width: width, height: 760))
            try await settle()
            for offset in [0.0, 220, 0, -20] {
                // Direct clip writes model an explicit user navigation here;
                // native layout corrections retain the active viewport owner.
                host.editor.explicitNavigationWillBegin?()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top + offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle()
                XCTAssertEqual(window.titlebarSeparatorStyle, offset > 0 ? .line : .none,
                    "The native separator spans the unified toolbar and disappears at the true document top")
            }
            host.minimap.navigate(topLine: 60)
            try await settle()
            XCTAssertEqual(window.titlebarSeparatorStyle, .line)
            doc.model.sourceOnly = false
            try await settle()
            XCTAssertEqual(window.titlebarSeparatorStyle, .automatic)
            doc.model.sourceOnly = true
            try await settle()
            XCTAssertEqual(window.titlebarSeparatorStyle, .line)
        }
        XCTAssertEqual(doc.model.source, source)
    }

    func testInspectorDividerKeepsQMDToolbarInsideEditor() async throws {
        let (_, window) = try window()
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let titlebarRoot = try XCTUnwrap(window.contentView?.superview)
        func control(_ title: String) throws -> NSView {
            try XCTUnwrap(allViews(titlebarRoot).first { view in
                if view.toolTip == title || view.accessibilityLabel() == title { return true }
                if let button = view as? NSButton, button.image?.accessibilityDescription == title { return true }
                if let segmented = view as? NSSegmentedControl {
                    return (0..<segmented.segmentCount).contains { segmented.toolTip(forSegment: $0) == title || segmented.image(forSegment: $0)?.accessibilityDescription == title }
                }
                return false
            }, "Native toolbar control: " + title)
        }
        try await settle()
        for width in [340.0, 260, 310, 270, 340] {
            split.splitView.setPosition(split.splitView.bounds.width - width - split.splitView.dividerThickness, ofDividerAt: 0)
            try await settle(); window.contentView?.layoutSubtreeIfNeeded()
            let inspector = split.splitViewItems[1].viewController.view
            let boundary = inspector.convert(inspector.bounds, to: nil).minX
            let separator = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == .inspectorTrackingSeparator } as? NSTrackingSeparatorToolbarItem)
            XCTAssertTrue(separator.splitView === split.splitView); XCTAssertEqual(separator.dividerIndex, 0)
            let render = try control("Quarto 渲染导出"), power = try control("启动 R")
            let renderBox = render.convert(render.bounds, to: nil), powerBox = power.convert(power.bounds, to: nil)
            XCTAssertLessThanOrEqual(renderBox.maxX, boundary + 1)
            XCTAssertGreaterThanOrEqual(renderBox.maxX, boundary - 32, "QMD actions stay at the editor's trailing edge")
            XCTAssertGreaterThanOrEqual(powerBox.minX, boundary - 1, "R controls stay inside the inspector")
        }
    }

    func testScrollIndicatorTracksTopMiddleAndBottomInBothModes() async throws {
        let (doc, window) = try window()
        try await settle()
        let editor = try XCTUnwrap(doc.model.activeEditor), scroll = try XCTUnwrap(editor.enclosingScrollView)
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            for code in [true, false] {
                doc.model.sourceOnly = code; try await settle()
                let host = try XCTUnwrap(scroll.superview as? RecordNativeEditorHost)
                let deadline = Date(timeIntervalSinceNow: 3)
                while host.editor.hasDeferredPresentation, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(host.editor.hasDeferredPresentation)
                if let manager = host.editor.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
                host.editor.sizeToFit()
                for fraction in [0.0, 0.5, 1, 0] {
                    let top = -scroll.contentInsets.top
                    let bottom = max(top, editor.frame.maxY - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
                    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: top + (bottom - top) * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await settle()
                    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                    let scroller = try XCTUnwrap(scroll.verticalScroller)
                    XCTAssertEqual(scroller.doubleValue, fraction, accuracy: 0.03,
                        "Code=\(code), style=\(style), origin=\(scroll.contentView.bounds), document=\(editor.frame)")
                    let knob = scroller.rect(for: .knob)
                    XCTAssertGreaterThanOrEqual(knob.minY, scroller.bounds.minY - 1)
                    XCTAssertLessThanOrEqual(knob.maxY, scroller.bounds.maxY + 1)
                    XCTAssertLessThanOrEqual(scroller.frame.maxX, scroll.contentView.frame.maxX + 20)
                    if fraction == 0 {
                        let knobTop = scroller.convert(knob, to: nil).maxY
                        let contentTop = scroll.convert(scroll.bounds, to: nil).maxY - scroll.contentInsets.top
                        XCTAssertEqual(knobTop, contentTop, accuracy: 6,
                            "Topmost text and the actual knob must align; a zero logical value alone is insufficient. Code=\(code), style=\(style)")
                    }
                }
            }
        }
        XCTAssertTrue(window.isVisible)
    }

    func testDividerResizeKeepsDocumentTopAndFirstLineAtSameScreenPositionInBothModes() async throws {
        let source = "TOP_ANCHOR\n\n" + (1...120).map { "段落 \($0)：" + String(repeating: "调整宽度时正文会换行。", count: 12) }.joined(separator: "\n\n")
        let (doc, window) = try window(source: source)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        for code in [true, false] {
            doc.model.sourceOnly = code; try await settle()
            let editor = try XCTUnwrap(doc.model.activeEditor), scroll = try XCTUnwrap(editor.enclosingScrollView)
            let host = try XCTUnwrap(scroll.superview as? RecordNativeEditorHost)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView); try await settle()
            let initial = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            let inset = scroll.contentInsets.top
            for width in [340.0, 260, 320, 280, 340, 260] {
                host.viewWillStartLiveResize()
                split.splitView.setPosition(split.splitView.bounds.width - width - split.splitView.dividerThickness, ofDividerAt: 0)
                window.contentView?.layoutSubtreeIfNeeded(); try await settle()
                host.viewDidEndLiveResize()
                editor.viewDidEndLiveResize()
                try await settle()
                let first = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
                XCTAssertEqual(scroll.contentInsets.top, inset, accuracy: 1, "Mode \(code), inspector \(width)")
                XCTAssertEqual(scroll.contentView.bounds.minY, -inset, accuracy: 1, "Mode \(code), inspector \(width): resizing must not consume the top inset")
                XCTAssertEqual(first.minY, initial.minY, accuracy: 2, "Mode \(code), inspector \(width): actual first-line screen position")
            }
        }
        XCTAssertEqual(doc.model.source, source)
    }

    func testLiveDividerResizePreservesReadingAnchorWhenEarlierParagraphsRewrap() async throws {
        let source = "TOP_ANCHOR\n\n" + (1...150).map {
            "PARAGRAPH_\($0)\n" + String(repeating: "调整宽度时保持正在阅读的位置。This paragraph reflows while the inspector is resized. ", count: 9)
        }.joined(separator: "\n\n")
        let (doc, window) = try window(source: source)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        for code in [true, false] {
            doc.model.sourceOnly = code; try await settle()
            let editor = try XCTUnwrap(doc.model.activeEditor), scroll = try XCTUnwrap(editor.enclosingScrollView)
            let host = try XCTUnwrap(scroll.superview as? RecordNativeEditorHost)
            let offset = (source as NSString).range(of: "PARAGRAPH_60\n").location
            XCTAssertNotEqual(offset, NSNotFound)
            let range = NSRange(location: offset, length: 1)
            // Lazy styling can finish after the first reveal, especially in
            // the full suite. Establish a visible baseline before resizing.
            for _ in 0..<5 {
                host.editor.scrollCharacterToTop(offset)
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: scroll.contentView.bounds.minY - 120))
                scroll.reflectScrolledClipView(scroll.contentView); try await settle()
                if editor.firstRect(forCharacterRange: range, actualRange: nil).height > 0 { break }
            }
            let baseline = editor.firstRect(forCharacterRange: range, actualRange: nil)
            XCTAssertGreaterThan(baseline.height, 0, "Mode \(code), offset \(offset), clip \(scroll.contentView.bounds), document \(editor.frame): measure an actually visible line")
            for width in [340.0, 260, 320, 270] {
                host.viewWillStartLiveResize()
                split.splitView.setPosition(split.splitView.bounds.width - width - split.splitView.dividerThickness, ofDividerAt: 0)
                window.contentView?.layoutSubtreeIfNeeded(); try await settle()
                host.viewDidEndLiveResize(); editor.viewDidEndLiveResize()
                try await settle()
                let rect = editor.firstRect(forCharacterRange: range, actualRange: nil)
                XCTAssertEqual(rect.minY, baseline.minY, accuracy: 2, "Mode \(code), inspector \(width): preserve the same source line")
            }
        }
        XCTAssertEqual(doc.model.source, source)
    }

}
