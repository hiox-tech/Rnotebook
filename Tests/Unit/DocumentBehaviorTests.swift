import AppKit
import SwiftUI
import XCTest
@testable import Rnotebook

@MainActor final class DocumentBehaviorTests: XCTestCase {
    private func preferences() throws -> DocumentBehaviorSettings {
        let suite = "DocumentBehaviorTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return DocumentBehaviorSettings(defaults: defaults)
    }
    private func document(_ settings: DocumentBehaviorSettings) throws -> (QMDDocument, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentBehavior-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("笔记.rmd")
        try Data("a\nb\nc\n".utf8).write(to: url)
        let doc = QMDDocument(recoveryStore: DocumentRecoveryStore(directory: root.appendingPathComponent("Recovery")),
                              autosaveDelay: 0.08, maximumAutosaveDelay: 0.2, behavior: settings)
        doc.sourceSettings = SourceEditorSettings(defaults: settings.defaults)
        doc.visual = VisualEditorSettings(defaults: settings.defaults)
        doc.appearance = AppearanceSettings(defaults: settings.defaults)
        try doc.read(from: url, ofType: NotebookDocumentType.rMarkdown); doc.fileURL = url
        addTeardownBlock { @MainActor in
            doc.close(); await doc.model.notebook.shutdown(); await doc.model.exporter.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        return (doc, url)
    }
    private func settle(_ milliseconds: Int = 250) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    private func show(_ window: NSWindow) async throws {
        // Placement records only after the first real key-window event.
        // A preceding native sheet or another app can leave the test host inactive.
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where !window.isKeyWindow { try await settle(25) }
        XCTAssertTrue(window.isKeyWindow, "Window-state checks require a presented key window")
        try await settle()
    }


    func testDefaultsPersistenceAndInvalidTimingFallbacks() throws {
        let settings = try preferences()
        XCTAssertTrue(settings.autosaveEnabled); XCTAssertTrue(settings.automaticallyReload); XCTAssertTrue(settings.rememberWindows)
        XCTAssertEqual(settings.idleDelay, 1); XCTAssertEqual(settings.maximumDelay, 5)
        settings.autosaveEnabled = false; settings.automaticallyReload = false; settings.rememberWindows = false
        settings.idleDelay = 2; settings.maximumDelay = 30
        let restored = DocumentBehaviorSettings(defaults: settings.defaults)
        XCTAssertFalse(restored.autosaveEnabled); XCTAssertFalse(restored.automaticallyReload); XCTAssertFalse(restored.rememberWindows)
        XCTAssertEqual(restored.idleDelay, 2); XCTAssertEqual(restored.maximumDelay, 30)
        restored.defaults.set(-1, forKey: "documents.idleDelay"); restored.defaults.set(Double.infinity, forKey: "documents.maximumDelay")
        let invalid = DocumentBehaviorSettings(defaults: settings.defaults)
        XCTAssertEqual(invalid.idleDelay, 1); XCTAssertEqual(invalid.maximumDelay, 5)
        invalid.idleDelay = .nan; invalid.maximumDelay = -10
        XCTAssertEqual(invalid.effectiveIdleDelay, 1); XCTAssertEqual(invalid.effectiveMaximumDelay, 5)
    }

    func testDisablingAutosaveCancelsPendingWritesAndPreservesRecoveryAndManualSave() async throws {
        let settings = try preferences(), (doc, url) = try document(settings)
        doc.model.source = "unsaved text\n"
        settings.autosaveEnabled = false
        try await settle(350)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\nc\n")
        XCTAssertTrue(doc.sourceIsModified); XCTAssertTrue(doc.recoveryAvailable)
        try await doc.autosave(withImplicitCancellability: false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\nc\n")
        await doc.synchronization.saveNow(manual: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "unsaved text\n")
        XCTAssertFalse(doc.sourceIsModified); XCTAssertFalse(doc.recoveryAvailable)
        doc.model.source = "resume pending edits"
        settings.autosaveEnabled = true
        try await settle(450)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "resume pending edits")
        XCTAssertFalse(doc.sourceIsModified); XCTAssertEqual(doc.model.notebook.state, .notStarted)
    }

    func testChangingIdlePreferenceReschedulesAnAlreadyEditedDocument() async throws {
        let settings = try preferences(), (_, url) = try document(settings)
        settings.idleDelay = 5
        let doc = QMDDocument(recoveryStore: .init(directory: url.deletingLastPathComponent().appendingPathComponent("TimingRecovery")), behavior: settings)
        defer { doc.close() }
        doc.fileURL = url; try doc.read(from: url, ofType: NotebookDocumentType.rMarkdown)
        doc.model.source = "live timing preference"
        try await settle(150)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\nc\n")
        settings.idleDelay = 0.5
        XCTAssertEqual(doc.synchronization.idleDelay, 0.5); XCTAssertEqual(doc.synchronization.maximumDelay, 5)
        try await settle(150)
        XCTAssertTrue(doc.sourceIsModified)
        try await settle(600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "live timing preference")
        XCTAssertFalse(doc.sourceIsModified)
    }

    func testWindowDefaultsUseLastLayoutAndEachDocumentRetainsItsOwnRecord() async throws {
        let settings = try preferences(), (first, firstURL) = try document(settings), (second, secondURL) = try document(settings)
        first.makeWindowControllers()
        let firstWindow = try XCTUnwrap(first.windowControllers.first?.window)
        try await show(firstWindow)
        firstWindow.setFrameOrigin(NSPoint(x: 60, y: 70))
        (firstWindow.contentViewController as? NotebookSplitController)?.setInspectorWidth(270)
        first.windowPlacement?.save()
        let original = try XCTUnwrap(NotebookWindowState.load(key: NotebookWindowState.documentKey(firstURL), defaults: settings.defaults))
        second.makeWindowControllers()
        let secondWindow = try XCTUnwrap(second.windowControllers.first?.window)
        try await show(secondWindow)
        XCTAssertEqual(secondWindow.frame, firstWindow.frame)
        XCTAssertEqual((secondWindow.contentViewController as? NotebookSplitController)?.inspectorWidth ?? 0, 270, accuracy: 2)
        secondWindow.setFrameOrigin(NSPoint(x: 140, y: 100))
        (secondWindow.contentViewController as? NotebookSplitController)?.setInspectorWidth(330)
        second.windowPlacement?.save()
        XCTAssertEqual(NotebookWindowState.load(key: NotebookWindowState.documentKey(firstURL), defaults: settings.defaults)?.frame, original.frame)
        let latest = try XCTUnwrap(NotebookWindowState.load(key: NotebookWindowState.documentKey(secondURL), defaults: settings.defaults))
        let untitled = QMDDocument(recoveryStore: .init(directory: secondURL.deletingLastPathComponent().appendingPathComponent("NewRecovery")), behavior: settings)
        defer { untitled.close() }
        untitled.makeWindowControllers()
        let window = try XCTUnwrap(untitled.windowControllers.first?.window)
        try await show(window)
        XCTAssertEqual(window.frame, latest.frame)
        XCTAssertEqual((window.contentViewController as? NotebookSplitController)?.inspectorWidth ?? 0, 330, accuracy: 2)
        XCTAssertNil(untitled.fileURL); XCTAssertEqual(untitled.model.notebook.state, .notStarted)
    }

    func testExternalReloadOffRequiresReviewAndNeverOverwritesIndependentChanges() async throws {
        let settings = try preferences(); settings.automaticallyReload = false; settings.autosaveEnabled = false
        let (doc, url) = try document(settings)
        doc.model.source = "A\nb\nc\n"
        try Data("a\nb\nC\n".utf8).write(to: url, options: .atomic)
        doc.synchronization.checkExternalChanges()
        XCTAssertTrue(doc.synchronization.paused); XCTAssertNotNil(doc.synchronization.conflict)
        XCTAssertEqual(doc.model.source, "A\nb\nc\n")
        await doc.synchronization.saveNow(manual: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\nC\n")
        await doc.synchronization.resolve(.external)
        XCTAssertEqual(doc.model.source, "a\nb\nC\n"); XCTAssertFalse(doc.sourceIsModified)
        XCTAssertNil(doc.synchronization.conflict); XCTAssertFalse(doc.synchronization.paused)
    }

    func testExplicitEditorResolutionSavesWithAutosaveDisabledAndRechecksNewExternalRevision() async throws {
        let settings = try preferences(); settings.automaticallyReload = false; settings.autosaveEnabled = false
        let (doc, url) = try document(settings)
        try Data("external".utf8).write(to: url, options: .atomic)
        doc.synchronization.checkExternalChanges()
        try Data("newer external".utf8).write(to: url, options: .atomic)
        await doc.synchronization.resolve(.editor)
        XCTAssertNotNil(doc.synchronization.conflict)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "newer external")
        await doc.synchronization.resolve(.editor)
        XCTAssertNil(doc.synchronization.conflict)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\nc\n")
        XCTAssertFalse(doc.sourceIsModified)
    }

    func testCloseWhenAutosaveOffHasNativeSaveDiscardCancelAndCancelRetainsEdits() async throws {
        let settings = try preferences(); settings.autosaveEnabled = false
        let (doc, url) = try document(settings)
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        try await show(window)
        doc.model.source = "close pending"
        try await settle()
        let receiver = CloseDecisionReceiver()
        func begin() { doc.canClose(withDelegate: receiver, shouldClose: #selector(CloseDecisionReceiver.decided(_:shouldClose:context:)), contextInfo: nil) }
        func button(_ index: Int) throws -> NSButton {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let content = try XCTUnwrap(window.attachedSheet?.contentView)
            let buttons = descendants(content).compactMap { $0 as? NSButton }
            return try XCTUnwrap(buttons.first { $0.tag == 1000 + index })
        }
        begin(); try await settle(); try button(2).performClick(nil); try await settle()
        XCTAssertEqual(receiver.result, false); XCTAssertTrue(doc.sourceIsModified); XCTAssertTrue(doc.recoveryAvailable)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\nc\n")
        receiver.result = nil; begin(); try await settle(); try button(1).performClick(nil); try await settle()
        XCTAssertEqual(receiver.result, true); XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\nc\n")
        receiver.result = nil; begin(); try await settle(); try button(0).performClick(nil); try await settle()
        XCTAssertEqual(receiver.result, true); XCTAssertFalse(doc.sourceIsModified)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "close pending")
    }

    func testWindowStateClampsRemovedMonitorInvalidAndSmallFrames() {
        let displays = [NSRect(x: 0, y: 40, width: 1440, height: 860), NSRect(x: -1920, y: -200, width: 1920, height: 1080)]
        let minimum = NSSize(width: 960, height: 640)
        let restored = NotebookWindowState.visibleFrame(NSRect(x: -1800, y: -100, width: 1200, height: 800), screens: displays, minimum: minimum)
        XCTAssertEqual(restored, NSRect(x: -1800, y: -100, width: 1200, height: 800))
        let moved = NotebookWindowState.visibleFrame(NSRect(x: 4000, y: -4000, width: 4000, height: 4000), screens: [displays[0]], minimum: minimum)
        XCTAssertEqual(moved, displays[0])
        let small = NotebookWindowState.visibleFrame(NSRect(x: 0, y: 0, width: 10, height: 10), screens: [displays[0]], minimum: minimum)
        XCTAssertEqual(small?.size, minimum); XCTAssertEqual(small?.minY, 40)
        XCTAssertNil(NotebookWindowState.visibleFrame(NSRect(x: CGFloat.nan, y: 0, width: 1200, height: 800), screens: displays, minimum: minimum))
    }

    func testDocumentWindowAndInspectorRestoreIndependentlyAndToggleStopsSaving() async throws {
        let settings = try preferences(), (doc, url) = try document(settings)
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        try await show(window)
        let split = try XCTUnwrap(window.contentViewController as? NotebookSplitController)
        window.setContentSize(NSSize(width: 1050, height: 690)); window.setFrameOrigin(NSPoint(x: 70, y: 70))
        split.setInspectorWidth(318); try await settle()
        doc.windowPlacement?.save()
        let expected = window.frame
        let state = try XCTUnwrap(NotebookWindowState.load(key: NotebookWindowState.documentKey(url), defaults: settings.defaults))
        XCTAssertEqual(state.frame, expected); XCTAssertEqual(state.inspectorWidth ?? 0, 318, accuracy: 2)
        doc.close(); try await settle()
        let reopened = QMDDocument(recoveryStore: .init(directory: url.deletingLastPathComponent().appendingPathComponent("Recovery2")), behavior: settings)
        reopened.sourceSettings = doc.sourceSettings; reopened.visual = doc.visual; reopened.appearance = doc.appearance
        reopened.fileURL = url; try reopened.read(from: url, ofType: NotebookDocumentType.rMarkdown)
        reopened.makeWindowControllers(); defer { reopened.close() }
        let restored = try XCTUnwrap(reopened.windowControllers.first?.window)
        try await show(restored)
        XCTAssertEqual(restored.frame, expected)
        let restoredSplit = try XCTUnwrap(restored.contentViewController as? NotebookSplitController)
        XCTAssertEqual(restoredSplit.inspectorWidth, 318, accuracy: 2)
        settings.rememberWindows = false
        restored.setFrameOrigin(NSPoint(x: 100, y: 120)); reopened.windowPlacement?.save()
        XCTAssertEqual(NotebookWindowState.load(key: NotebookWindowState.documentKey(url), defaults: settings.defaults)?.frame, expected)
        settings.rememberWindows = true
        reopened.windowPlacement?.reset(); try await settle()
        XCTAssertEqual(restoredSplit.inspectorWidth, 280, accuracy: 2)
        XCTAssertEqual(reopened.model.notebook.state, .notStarted)
    }

    func testSettingsHasFlatNativePanesAndRestoresSelectionAndPosition() async throws {
        let original = L10n.resources.language; defer { L10n.configure(language: original) }
        let behavior = try preferences()
        let language = LanguageSettings(defaults: behavior.defaults, systemLanguages: { ["en"] })
        func controller() -> NotebookSettingsController {
            NotebookSettingsController(language: language, source: .init(defaults: behavior.defaults), visual: .init(defaults: behavior.defaults),
                                       appearance: .init(defaults: behavior.defaults), behavior: behavior)
        }
        let first = controller(), window = first.makeWindow()
        try await show(window)
        for (index, pane) in NotebookSettingsPane.allCases.enumerated() {
            first.selectedTabViewItemIndex = index; try await settle(120)
            XCTAssertEqual(window.contentLayoutRect.width, 640, accuracy: 2)
            XCTAssertEqual(window.contentView?.bounds.height ?? 0,
                           pane.preferredHeight(formatMode: behavior.defaults.string(forKey: "rFormat.mode") ?? "document"), accuracy: 2)
        }
        first.selectedTabViewItemIndex = 1
        window.setFrameOrigin(NSPoint(x: 80, y: 100)); try await settle()
        let top = window.frame.maxY
        window.close()
        let second = controller(), restored = second.makeWindow(); defer { restored.close() }
        XCTAssertEqual(second.selectedTabViewItemIndex, 1)
        XCTAssertEqual(restored.frame.minX, 80, accuracy: 2); XCTAssertEqual(restored.frame.maxY, top, accuracy: 2)

        behavior.defaults.set("forest", forKey: "syntax.palette")
        for (legacy, pane) in [("typography", NotebookSettingsPane.fonts), ("highlighting", .highlighting),
                               ("completion", .completion), ("formatting", .formatting), ("unknown", .fonts)] {
            behavior.defaults.set("editor", forKey: "settings.selectedPane")
            behavior.defaults.set(legacy, forKey: "settings.editorPage")
            let migrated = controller()
            XCTAssertEqual(migrated.selectedTabViewItemIndex, NotebookSettingsPane.allCases.firstIndex(of: pane))
            XCTAssertEqual(behavior.defaults.string(forKey: "settings.selectedPane"), pane.rawValue)
            XCTAssertNil(behavior.defaults.object(forKey: "settings.editorPage"))
            XCTAssertEqual(behavior.defaults.string(forKey: "syntax.palette"), "forest")
        }
    }
}

@MainActor private final class CloseDecisionReceiver: NSObject {
    var result: Bool?
    @objc func decided(_ document: NSDocument, shouldClose: Bool, context: UnsafeMutableRawPointer?) { result = shouldClose }
}
