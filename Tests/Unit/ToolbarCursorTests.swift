import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class ToolbarCursorTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(240)) }
    func testToolbarCursorEventsUseArrowAndRestoreTextInBothModes() async throws {
        let source = "# Cursor fixture\n\nCopy code pointer.\n\n```{r}\n1 + 1\n```\n\n" + (1...90).map { "第 \($0) 行：编辑工具栏与系统工具栏使用箭头，正文使用编辑光标。" }.joined(separator: "\n\n")
        let doc = QMDDocument(); try doc.read(from: Data(source.utf8), ofType: "org.quarto.qmd")
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        addTeardownBlock { @MainActor in doc.updateChangeCount(.changeCleared); doc.close() }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); try await settle()
        let editor = try XCTUnwrap(doc.model.activeEditor)
        let host = try XCTUnwrap(editor.enclosingScrollView?.superview as? RecordNativeEditorHost)
        window.makeFirstResponder(editor)
        for code in [false, true] {
            doc.model.sourceOnly = code; try await settle()
            editor.setSelectedRange(.init(location: 0, length: 0)); editor.scrollRangeToVisible(editor.selectedRange())
            try await settle()
            XCTAssertEqual(host.toolbarCursorRects.count, code ? 1 : 2)
            let body = NSPoint(x: 80, y: 30)
            XCTAssertNil(host.toolbarCursor(at: body))
            func cursorEvent(at point: NSPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.enterExitEvent(with: .cursorUpdate,
                    location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    trackingNumber: 0, userData: nil))
            }
            if !code {
                let anchor = try XCTUnwrap(host.editor.codeBlockMarginAnchors().first)
                let copy = NSPoint(x: anchor.copyRect.midX, y: anchor.copyRect.midY)
                let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
                    location: editor.convert(copy, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                NSCursor.iBeam.set()
                host.editor.mouseMoved(with: move)
                XCTAssertEqual(NSCursor.current, .arrow, "A revealed native code-copy button must use the arrow")
                NSCursor.iBeam.set()
                host.editor.cursorUpdate(with: try cursorEvent(at: copy))
                XCTAssertEqual(NSCursor.current, .arrow, "Native cursor updates must keep the code-copy arrow")
                host.editor.cursorUpdate(with: try cursorEvent(at: NSPoint(x: 100, y: copy.y + 25)))
                XCTAssertEqual(NSCursor.current, .iBeam, "Code text keeps its normal insertion cursor")
            }
            for rect in host.toolbarCursorRects {
                let point = NSPoint(x: rect.midX, y: rect.midY)
                XCTAssertEqual(host.editor.embeddedViewCursor?(point), .arrow)
                XCTAssertEqual(host.outputs.resultCursor(at: point), .arrow)
                NSCursor.iBeam.set()
                host.editor.cursorUpdate(with: try cursorEvent(at: point))
                XCTAssertEqual(NSCursor.current, .arrow, "Toolbars must replace an existing text cursor")
                host.editor.cursorUpdate(with: try cursorEvent(at: body))
                XCTAssertEqual(NSCursor.current, .iBeam, "Returning to text must restore its cursor")
            }
        }
        XCTAssertEqual(doc.model.source, source)
    }
    func testCursorRegionsFollowToolbarResizeAndScrollWithoutChangingText() async throws {
        let source = String(repeating: "可滚动的正文段落，保留全宽minimap与原生工具栏避让。\n\n", count: 150)
        let doc = QMDDocument(); try doc.read(from: Data(source.utf8), ofType: "org.quarto.qmd"); doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        addTeardownBlock { @MainActor in doc.updateChangeCount(.changeCleared); doc.close() }
        window.makeKeyAndOrderFront(nil); try await settle()
        let editor = try XCTUnwrap(doc.model.activeEditor), scroll = try XCTUnwrap(editor.enclosingScrollView)
        let host = try XCTUnwrap(scroll.superview as? RecordNativeEditorHost)
        for width in [960.0, 1160, 1440] {
            window.setContentSize(NSSize(width: width, height: 760)); try await settle()
            for offset in [-scroll.contentInsets.top, 420.0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset)); scroll.reflectScrolledClipView(scroll.contentView); try await settle()
                let toolbar = try XCTUnwrap(doc.model.visualToolbarCursorView)
                let expected = editor.convert(toolbar.bounds, from: toolbar)
                XCTAssertTrue(host.toolbarCursorRects.contains(expected))
                XCTAssertEqual(host.editor.embeddedViewCursor?(NSPoint(x: expected.midX, y: expected.midY)), .arrow)
                XCTAssertEqual(host.outputs.resultCursor(at: NSPoint(x: expected.midX, y: expected.midY)), .arrow)
            }
        }
        XCTAssertEqual(doc.model.source, source)
    }
}
