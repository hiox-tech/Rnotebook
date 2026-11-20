import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class NativeDraftLifecycleTests: XCTestCase {
    private func draft(_ text: String = "") throws -> QMDDocument {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDraft-" + UUID().uuidString)
        let doc = QMDDocument(recoveryStore: DocumentRecoveryStore(directory: root))
        doc.model.source = text
        doc.model.sourceOnly = true
        doc.makeWindowControllers(); doc.showWindows()
        addTeardownBlock { @MainActor in
            doc.windowControllers.first?.window?.attachedSheet.map { ($0 as? NSSavePanel)?.cancel(nil) }
            doc.close(); await doc.model.notebook.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        return doc
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }
    @MainActor private final class CloseDecision: NSObject {
        var result: Bool?
        @objc func checked(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { result = shouldClose }
    }
    func testEmptyNewDraftClosesWithoutPromptOrRecovery() async throws {
        let doc = try draft(), decision = CloseDecision()
        try await settle()
        doc.canClose(withDelegate: decision, shouldClose: #selector(CloseDecision.checked(_:shouldClose:contextInfo:)), contextInfo: nil)
        try await settle()
        XCTAssertEqual(decision.result, true)
        XCTAssertNil(doc.windowControllers.first?.window?.attachedSheet)
        XCTAssertFalse(doc.recoveryAvailable); XCTAssertNil(doc.fileURL)
    }
    func testDirtyDraftGetsNativeCloseReviewAndCancelKeepsTextAndRecovery() async throws {
        let doc = try draft("尚未命名的正文"), decision = CloseDecision()
        try await settle()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        doc.canClose(withDelegate: decision, shouldClose: #selector(CloseDecision.checked(_:shouldClose:contextInfo:)), contextInfo: nil)
        try await settle()
        let sheet = try XCTUnwrap(window.attachedSheet)
        // AppKit's native new-document close review is a remote save panel;
        // its buttons are not local NSView children.
        try XCTUnwrap(sheet as? NSSavePanel).cancel(nil)
        try await settle()
        XCTAssertEqual(decision.result, false)
        XCTAssertEqual(doc.model.source, "尚未命名的正文")
        XCTAssertTrue(doc.recoveryAvailable); XCTAssertTrue(doc.isDocumentEdited)
    }
    func testRunAndRenderUseNativeInitialSaveAndCancelNeverExecutes() async throws {
        let doc = try draft("```{r}\nstop('must not execute before save')\n```\n")
        try await settle()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        doc.model.runAllNotebookCells()
        try await settle()
        let runSave = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        doc.model.runAllNotebookCells()
        XCTAssertTrue(window.attachedSheet === runSave, "Repeated clicks must not stack save requests")
        runSave.cancel(nil); try await settle()
        XCTAssertNil(doc.fileURL); XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertTrue(doc.model.outputStates.isEmpty)
        XCTAssertTrue(doc.recoveryAvailable)
        _ = doc.model.exporter.present(window: window)
        try await settle()
        let renderSave = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        XCTAssertFalse(doc.model.showingExport)
        renderSave.cancel(nil); try await settle()
        XCTAssertNil(window.attachedSheet); XCTAssertFalse(doc.model.showingExport)
        XCTAssertNil(doc.fileURL); XCTAssertEqual(doc.model.notebook.state, .notStarted)
        var continued = false
        doc.ensureSaved { continued = true }
        try await settle()
        try XCTUnwrap(window.attachedSheet as? NSSavePanel).cancel(nil)
        try await settle(); XCTAssertFalse(continued)
    }
    func testUntitledWindowUsesNativeDocumentTitleAndModernDocumentModel() async throws {
        let doc = try draft("系统标题命名")
        try await settle()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        XCTAssertTrue(QMDDocument.autosavesInPlace)
        XCTAssertEqual(doc.fileType, "org.quarto.qmd")
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertNil(window.representedURL)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 0)
        XCTAssertTrue(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "r-session" } is NSToolbarItemGroup)
        // AppKit creates the document-status button lazily (e.g. on title
        // hover); an untouched untitled window need not have one yet.
        XCTAssertFalse(window.title.isEmpty)
        XCTAssertEqual(doc.model.source, "系统标题命名")
    }

    func testExplicitStartUsesNativeSaveAndCancelDoesNotLaunchR() async throws {
        let doc = try draft("启动 R 前先命名\n")
        try await settle()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        doc.model.toggleRSession(); try await settle()
        let save = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        doc.model.toggleRSession()
        XCTAssertTrue(window.attachedSheet === save)
        save.cancel(nil); try await settle()
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertNil(doc.model.notebook.sessionID); XCTAssertNil(doc.fileURL)
        XCTAssertEqual(doc.model.source, "启动 R 前先命名\n")
        XCTAssertTrue(doc.recoveryAvailable)
    }
}
