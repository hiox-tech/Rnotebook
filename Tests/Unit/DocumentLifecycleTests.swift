import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class DocumentLifecycleTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func document(in root: URL) -> (QMDDocument, DocumentRecoveryStore) {
        let store = DocumentRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let doc = QMDDocument(recoveryStore: store)
        addTeardownBlock { @MainActor in await doc.model.notebook.shutdown(); await doc.model.exporter.shutdown(); doc.close() }
        return (doc, store)
    }
    func testDirtyDraftKeepsLatestUnicodeAndSaveRemovesRecoveryOnly() async throws {
        let root = try directory(), (doc, store) = document(in: root)
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).isEmpty)
        doc.model.source = "第一版"
        doc.model.source = "---\ntitle: 最新正文\n---\n\n```{r}\nx <- '001'\n```\n![](images/a.png)\n"
        XCTAssertEqual(try store.drafts(includeLiveOwners: true).map(\.source), [doc.model.source])
        XCTAssertTrue(try store.drafts().isEmpty, "A live owner must not be offered by another instance")
        let url = root.appendingPathComponent("保存.qmd")
        try await doc.save(to: url, ofType: "org.quarto.qmd", for: .saveOperation)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), doc.model.source)
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["recovery", "保存.qmd"])
        doc.model.source += "\n新的未保存修改"
        let draft = try XCTUnwrap(store.drafts(includeLiveOwners: true).first)
        XCTAssertEqual(draft.originalURL, url)
        XCTAssertEqual(draft.source, doc.model.source)
    }
    func testLegacyRecoveryAndRestoredCopyNeverOverwriteOriginalOrRunR() throws {
        let root = try directory(), (doc, store) = document(in: root)
        let original = root.appendingPathComponent("原文.qmd")
        try Data("磁盘上更新的正文".utf8).write(to: original)
        let id = UUID()
        try store.write(id: id, source: "尚未保存的恢复正文", originalURL: original)
        let metadata = DocumentRecoveryStore.Metadata(originalURL: original, updatedAt: Date(), ownerPID: Int32.max)
        try JSONEncoder().encode(metadata).write(to: store.directory.appendingPathComponent(id.uuidString + ".json"))
        let legacyID = UUID().uuidString
        try Data("旧版本留下的非空草稿".utf8).write(to: store.directory.appendingPathComponent(legacyID + ".qmd"))
        try Data().write(to: store.directory.appendingPathComponent(UUID().uuidString + ".qmd"))
        let drafts = try store.drafts()
        XCTAssertEqual(drafts.count, 2)
        doc.restore(try XCTUnwrap(drafts.first { $0.id == id.uuidString }))
        XCTAssertNil(doc.fileURL)
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertEqual(doc.model.source, "尚未保存的恢复正文")
        XCTAssertTrue(doc.model.outputStates.isEmpty)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "磁盘上更新的正文")
    }
    func testClosingDiscardedDraftRemovesItsRecoveryButNotOtherDrafts() throws {
        let root = try directory(), (doc, store) = document(in: root)
        let otherID = UUID()
        try store.write(id: otherID, source: "另一个窗口", originalURL: nil)
        doc.model.source = "要放弃的修改"
        doc.close()
        XCTAssertEqual(try store.drafts(includeLiveOwners: true).map(\.source), ["另一个窗口"])
    }
    func testFailedRecoveryWriteKeepsOriginalDraftUntilExplicitDiscard() throws {
        let root = try directory(), store = DocumentRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let originalID = UUID(), newID = UUID()
        try store.write(id: originalID, source: "必须保留的恢复正文", originalURL: nil)
        let draft = try XCTUnwrap(store.drafts(includeLiveOwners: true).first)
        // A directory at the new snapshot path causes a real atomic-write
        // failure while the original draft remains readable/removable.
        try FileManager.default.createDirectory(at: store.directory.appendingPathComponent(newID.uuidString + ".qmd"), withIntermediateDirectories: true)
        let doc = QMDDocument(recoveryStore: store, recoveryID: newID)
        defer { doc.close() }
        doc.restore(draft)
        XCTAssertFalse(doc.recoveryAvailable)
        XCTAssertNotNil(doc.model.notice)
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertEqual(doc.model.source, draft.source)
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).contains { $0.id == originalID.uuidString })
        doc.close()
        XCTAssertFalse(try store.drafts(includeLiveOwners: true).contains { $0.id == originalID.uuidString }, "Explicit discard may remove the original recovery record")
    }
    func testRecoveredEmptySourceStaysUnsavedThroughEditsUntilSaved() async throws {
        let root = try directory(), (doc, store) = document(in: root)
        let id = UUID()
        try store.write(id: id, source: "", originalURL: nil)
        doc.restore(try XCTUnwrap(store.drafts(includeLiveOwners: true).first))
        XCTAssertTrue(doc.isDocumentEdited)
        doc.model.source = "临时输入"; doc.model.source = ""
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertEqual(try store.drafts(includeLiveOwners: true).map(\.source), [""])
        let url = root.appendingPathComponent("empty.qmd")
        try await doc.save(to: url, ofType: "org.quarto.qmd", for: .saveOperation)
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        XCTAssertEqual(doc.displayName, "empty.qmd")
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).isEmpty)
    }
    func testExternalModificationWithSameTimestampCannotBeOverwritten() async throws {
        let root = try directory(), (doc, _) = document(in: root)
        let url = root.appendingPathComponent("conflict.qmd")
        try Data("original".utf8).write(to: url)
        doc.fileURL = url; try doc.read(from: url, ofType: "org.quarto.qmd")
        let timestamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        doc.model.source = "local edit"
        try Data("external".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        do {
            try await doc.save(to: url, ofType: "org.quarto.qmd", for: .saveOperation)
            XCTFail("External edit must not be overwritten")
        } catch { XCTAssertEqual((error as NSError).domain, "Rnotebook") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        XCTAssertEqual(doc.model.source, "local edit")
        XCTAssertTrue(doc.isDocumentEdited)
        let copy = root.appendingPathComponent("保留修改.qmd")
        try await doc.save(to: copy, ofType: "org.quarto.qmd", for: .saveAsOperation)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "local edit")
    }
    func testSaveAsPreservesReferencesAndActiveRDirectoryUntilExplicitChange() async throws {
        let root = try directory(), (doc, _) = document(in: root)
        let moved = root.appendingPathComponent("另一个位置")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old.qmd"), new = moved.appendingPathComponent("new.qmd")
        let source = "![](images/external.png)\n\n```{r}\nkept <- 42L\n```\n"
        try Data(source.utf8).write(to: old)
        doc.fileURL = old; try doc.read(from: old, ofType: "org.quarto.qmd")
        doc.model.runAllNotebookCells(); await doc.model.notebook.waitUntilIdle()
        XCTAssertEqual(doc.model.notebook.completedCount, 1, doc.model.notebook.diagnostic ?? "")
        let sessionID = doc.model.notebook.sessionID
        try await doc.save(to: new, ofType: "org.quarto.qmd", for: .saveAsOperation)
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), source)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), source)
        XCTAssertTrue(doc.model.notice?.contains("文档位置已改变") == true)
        let before = try XCTUnwrap(doc.model.notebook.inspectorSnapshot?.workingDirectory)
        XCTAssertEqual(URL(fileURLWithPath: before).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        doc.model.notebook.manage(.init(operation: .setWorkingDirectory, name: moved.path))
        await doc.model.notebook.waitUntilIdle()
        let after = try XCTUnwrap(doc.model.notebook.inspectorSnapshot?.workingDirectory)
        XCTAssertEqual(URL(fileURLWithPath: after).resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
        XCTAssertEqual(doc.model.notebook.sessionID, sessionID)
        let retained = try await doc.model.notebook.runtime.evaluate(.init(cellID: "readback", source: "stopifnot(kept == 42L); cat('KEEP_OK')"))
        XCTAssertTrue(retained.events.contains { $0.payload.text?.contains("KEEP_OK") == true })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["new.qmd"])
    }
    func testDocumentsHaveIndependentSessionsAndClosingOneKeepsOtherUsable() async throws {
        let root = try directory(), (first, _) = document(in: root), (second, _) = document(in: root)
        for (doc, name, value) in [(first, "first.qmd", 1), (second, "second.qmd", 2)] {
            let url = root.appendingPathComponent(name)
            doc.model.source = "```{r}\nprivate_value <- \(value)L\n```\n"
            try await doc.save(to: url, ofType: "org.quarto.qmd", for: .saveOperation)
            doc.model.runAllNotebookCells(); await doc.model.notebook.waitUntilIdle()
            XCTAssertEqual(doc.model.notebook.completedCount, 1)
        }
        XCTAssertNotEqual(first.model.notebook.sessionID, second.model.notebook.sessionID)
        await first.model.notebook.shutdown(); first.close()
        let result = try await second.model.notebook.runtime.evaluate(.init(cellID: "isolated", source: "stopifnot(private_value == 2L); cat('ISOLATED_OK')"))
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains("ISOLATED_OK") == true })
    }
    func testViewStateStaysInternalAndClampsSelectionToChangedSource() throws {
        let root = try directory(), url = root.appendingPathComponent("view.qmd")
        let suite = "ViewStateTests." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = DocumentViewState(sourceOnly: true, location: 9999, length: 200, scrollY: 10000)
        state.save(for: url, defaults: defaults)
        XCTAssertEqual(DocumentViewState.load(for: url, defaults: defaults)?.location, 9999)
        XCTAssertNil(DocumentViewState.load(for: root.appendingPathComponent("other.qmd"), defaults: defaults))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
