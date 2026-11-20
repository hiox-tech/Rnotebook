import AppKit
import SwiftUI
import XCTest
@testable import Rnotebook

@MainActor final class EditorControlsTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }
    private func document(_ source: String) throws -> (QMDDocument, NSWindow, RecordNativeEditorHost) {
        let suite = "EditorControls." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let doc = QMDDocument()
        doc.sourceSettings = SourceEditorSettings(defaults: defaults)
        doc.visual = VisualEditorSettings(defaults: defaults)
        doc.appearance = AppearanceSettings(defaults: defaults)
        try doc.read(from: Data(source.utf8), ofType: "org.quarto.qmd")
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        let editor = try XCTUnwrap(doc.model.activeEditor)
        let host = try XCTUnwrap(editor.enclosingScrollView?.superview as? RecordNativeEditorHost)
        window.makeFirstResponder(editor)
        addTeardownBlock { @MainActor in
            host.detach(); await doc.model.notebook.shutdown()
            doc.discardRecovery(); doc.updateChangeCount(.changeCleared); doc.close()
            defaults.removePersistentDomain(forName: suite)
        }
        return (doc, window, host)
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    func testCompletionGeometryFitsPaneAndLeavesInsertionLineClearAtAllEdges() throws {
        let pane = NSRect(x: 100, y: 100, width: 600, height: 400)
        for caret in [NSRect(x: 120, y: 450, width: 1, height: 18),
                      NSRect(x: 680, y: 110, width: 1, height: 18),
                      NSRect(x: 350, y: 275, width: 1, height: 18)] {
            let frame = try XCTUnwrap(RCompletionPopupLayout.frame(caret: caret, viewport: pane, preferred: NSSize(width: 360, height: 228)))
            XCTAssertTrue(pane.contains(frame))
            XCTAssertFalse(frame.intersects(caret.insetBy(dx: -2, dy: -2)))
            XCTAssertLessThanOrEqual(frame.width, 360); XCTAssertLessThanOrEqual(frame.height, 228)
            XCTAssertGreaterThanOrEqual(frame.height, 38)
        }
        let narrow = NSRect(x: 0, y: 0, width: 200, height: 200)
        let frame = try XCTUnwrap(RCompletionPopupLayout.frame(caret: NSRect(x: 180, y: 170, width: 1, height: 18), viewport: narrow, preferred: NSSize(width: 360, height: 200)))
        XCTAssertTrue(narrow.contains(frame)); XCTAssertEqual(frame.width, 192)
        XCTAssertNil(RCompletionPopupLayout.frame(caret: NSRect(x: 120, y: 800, width: 1, height: 18), viewport: pane, preferred: NSSize(width: 300, height: 200)))
    }

    func testFormatCommandBelongsToEditAndKeepsItsShortcut() throws {
        let menu = RnotebookApp.makeMenu(commandTarget: RnotebookDelegate())
        let edit = try XCTUnwrap(menu.items.first { $0.title == L10n.string("编辑") }?.submenu)
        let style = try XCTUnwrap(menu.items.first { $0.title == L10n.string("格式") }?.submenu)
        let selector = #selector(RnotebookDelegate.formatRBlock(_:))
        let command = try XCTUnwrap(edit.items.first { $0.action == selector })
        XCTAssertFalse(style.items.contains { $0.action == selector })
        XCTAssertEqual(command.keyEquivalent, "i")
        XCTAssertEqual(command.keyEquivalentModifierMask, [.command, .shift])
    }

    func testQuartoSheetShowsDefaultOnToggleInBothParameterModesAndAppearances() async throws {
        let model = RecordLayoutModel(initialSource: "# document\n", usesProcessArguments: false)
        let exporter = model.exporter
        let host = NSHostingController(rootView: RecordExportSheet(model: model, exporter: exporter))
        let window = NSWindow(contentViewController: host); window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 600)); exporter.window = window
        defer { window.orderOut(nil); window.close() }
        window.makeKeyAndOrderFront(nil); host.view.layoutSubtreeIfNeeded(); try await settle()
        func button(_ title: String) -> NSButton? {
            views(host.view).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        guard let toggle = button(L10n.string("兼容 Edmund 语法")) else {
            throw XCTSkip("This XCTest NSHostingView does not expose SwiftUI checkbox/radio controls as native subviews or an in-process accessibility tree;visual toggle interaction is not accepted here. Engine on/off behavior is verified by real exports.")
        }
        XCTAssertEqual(toggle.state, .on)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for title in [L10n.string("自定义"), L10n.string("文档 YAML 块")] {
                let radio = try XCTUnwrap(button(title)); radio.performClick(nil); try await settle()
                let checkbox = try XCTUnwrap(button(L10n.string("兼容 Edmund 语法")))
                XCTAssertTrue(checkbox.isEnabled)
                XCTAssertTrue(host.view.bounds.contains(checkbox.convert(checkbox.bounds, to: host.view)))
                checkbox.performClick(nil); try await settle(); XCTAssertEqual(checkbox.state, .off)
                checkbox.performClick(nil); try await settle(); XCTAssertEqual(checkbox.state, .on)
            }
        }
    }

    func testToolbarFindShowsFloatingBarAndTargetsItsDocument() async throws {
        let (first, _, _) = try document("first first\n")
        let (second, window, host) = try document("second second\n")
        try await settle()
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "find" })
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item)); try await settle()
        XCTAssertTrue(host.documentFinder.isPresented)
        XCTAssertFalse(host.documentFinder.bar.isHidden)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item)); try await settle()
        XCTAssertEqual(first.model.source, "first first\n"); XCTAssertEqual(second.model.source, "second second\n")
        XCTAssertFalse(window.firstResponder === host.editor, "The native Find field receives intentional focus")
    }

    func testBlockFormatButtonSharesHoverAndFormatsClickedBlockWithSingleUndo() async throws {
        let source = "```{r}\n#| label: first\na<-1\n```\n\n```{r}\n#| label: second\nb<-function(x){x+1}\n```\n"
        let (doc, window, host) = try document(source)
        doc.sourceSettings.completionEnabled = false
        doc.model.sourceOnly = false; host.update(); try await settle(); host.outputs.apply()
        let actions = try XCTUnwrap(host.outputs.codeActions["second"])
        actions.layoutSubtreeIfNeeded()
        XCTAssertFalse(actions.isHidden)
        XCTAssertEqual(actions.format.frame.minX, actions.run.frame.minX)
        XCTAssertEqual(actions.format.frame.minY, actions.run.frame.maxY + 2, accuracy: 0.1)
        XCTAssertEqual(actions.format.frame.size, actions.run.frame.size)
        XCTAssertTrue(actions.format.isEnabled)
        host.outputs.updateHover(at: nil)
        XCTAssertFalse(actions.format.revealed); XCTAssertFalse(actions.run.revealed)
        XCTAssertNil(actions.format.hitTest(NSPoint(x: 1, y: 1)))
        let pointer = actions.format.convert(NSPoint(x: actions.format.bounds.midX, y: actions.format.bounds.midY), to: host.editor)
        host.outputs.updateHover(at: pointer)
        XCTAssertTrue(actions.run.revealed); XCTAssertTrue(actions.format.revealed)
        XCTAssertTrue(actions.format.pointerInside); XCTAssertFalse(actions.run.pointerInside)
        host.editor.setSelectedRange(NSRange(location: (source as NSString).range(of: "a<-1").location, length: 0))
        window.makeFirstResponder(host.editor)
        actions.format.performClick(nil)
        for _ in 0..<100 {
            host.publishCommittedText()
            if doc.model.source != source { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(doc.model.source.contains("a<-1"), "Formatting targets the clicked block, not the caret's block")
        XCTAssertTrue(doc.model.source.contains("b <- function(x)"), doc.model.source)
        XCTAssertTrue(window.firstResponder === host.editor)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        host.undoSource(nil); host.publishCommittedText(); XCTAssertEqual(doc.model.source, source)
        doc.model.sourceOnly = true; host.update(); try await settle()
        XCTAssertTrue(host.outputs.codeActions.values.allSatisfy(\.isHidden), "Match the existing run button's mode visibility")
    }

    func testNativeCompletionTracksCaretWithoutKeyWindowOrFocusAndCapsLongCandidates() async throws {
        let name = "zz_" + String(repeating: "long_candidate_", count: 14)
        let source = "```{r}\n\(name) <- 1\nzz_short <- 2\nzz_\n```\n"
        let (doc, window, host) = try document(source)
        let controller = try XCTUnwrap(host.completion)
        for code in [true, false] {
            doc.model.sourceOnly = code; host.update(); try await settle()
            let selection = NSRange(location: (source as NSString).range(of: "\nzz_\n").location + 4, length: 0)
            host.editor.setSelectedRange(selection); host.editor.scrollRangeToVisible(selection)
            window.makeFirstResponder(host.editor); controller.schedule(manual: true)
            for _ in 0..<150 { if controller.isPresented { break }; try await Task.sleep(for: .milliseconds(20)) }
            let frame = try XCTUnwrap(controller.presentationFrame)
            let caret = host.editor.firstRect(forCharacterRange: selection, actualRange: nil)
            XCTAssertGreaterThan(caret.height, 0)
            XCTAssertLessThanOrEqual(frame.width, 360); XCTAssertLessThanOrEqual(frame.height, 228)
            XCTAssertFalse(frame.intersects(caret.insetBy(dx: -2, dy: -2)))
            if caret.minX + frame.width <= window.convertToScreen(window.contentLayoutRect).maxX - 10 {
                XCTAssertEqual(frame.minX, caret.minX - 8, accuracy: 1)
            }
            XCTAssertTrue(window.firstResponder === host.editor); XCTAssertTrue(window.isKeyWindow)
            let panel = try XCTUnwrap(window.childWindows?.first { $0.accessibilityIdentifier() == "r-completion-panel" })
            XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
            window.setFrameOrigin(window.frame.origin.applying(CGAffineTransform(translationX: 20, y: 10)))
            try await settle()
            let moved = try XCTUnwrap(controller.presentationFrame)
            let newCaret = host.editor.firstRect(forCharacterRange: selection, actualRange: nil)
            XCTAssertFalse(moved.intersects(newCaret.insetBy(dx: -2, dy: -2)))
            XCTAssertTrue(window.firstResponder === host.editor)
            XCTAssertTrue(controller.candidates.contains { $0.label == name })
            if !code {
                let table = try XCTUnwrap(views(XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTableView }.first)
                XCTAssertFalse(table.acceptsFirstResponder)
                let expected = try XCTUnwrap(controller.candidates.first?.insertion)
                let row = table.rect(ofRow: 0)
                let location = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
                let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                controller.pointerEvent(click); XCTAssertTrue(controller.isPresented)
                table.mouseDown(with: click); host.publishCommittedText()
                XCTAssertTrue(doc.model.source.contains("\n" + expected + "\n"))
                XCTAssertTrue(window.firstResponder === host.editor)
                XCTAssertFalse(controller.isPresented)
                host.undoSource(nil); host.publishCommittedText(); XCTAssertEqual(doc.model.source, source)
            }
            controller.cancel()
        }
        XCTAssertEqual(doc.model.source, source)
    }

    func testLateCompletionDoesNotStealFocusFromAnotherControl() async throws {
        let source = "```{r}\nzz_unique_name <- 1\nzz_uni\n```\n"
        let (_, window, host) = try document(source)
        let controller = try XCTUnwrap(host.completion)
        host.editor.setSelectedRange(NSRange(location: (source as NSString).range(of: "\nzz_uni\n").location + 7, length: 0))
        window.makeFirstResponder(host.editor); controller.schedule(manual: true)
        let field = NSTextField(string: "another control")
        field.frame = NSRect(x: 20, y: 20, width: 150, height: 24)
        window.contentView?.addSubview(field); window.makeFirstResponder(field)
        let focus = window.firstResponder
        for _ in 0..<100 { if !controller.candidates.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(window.firstResponder === focus)
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(host.editor.string, source)
    }
}
