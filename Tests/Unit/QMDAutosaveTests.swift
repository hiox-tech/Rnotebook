import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class QMDAutosaveTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QMDAutosave-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func document(_ text: String = "one\ntwo\nthree\n", delay: TimeInterval = 0.08, maximum: TimeInterval = 0.3) throws -> (QMDDocument, URL, DocumentRecoveryStore) {
        let root = try folder(), url = root.appendingPathComponent("文件.qmd")
        try Data(text.utf8).write(to: url)
        let store = DocumentRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let doc = QMDDocument(recoveryStore: store, autosaveDelay: delay, maximumAutosaveDelay: maximum)
        doc.fileURL = url; try doc.read(from: url, ofType: "org.quarto.qmd")
        addTeardownBlock { @MainActor in doc.close(); await doc.model.notebook.shutdown(); await doc.model.exporter.shutdown() }
        return (doc, url, store)
    }
    private func wait(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Condition did not become true")
    }
    func testMergePreservesIndependentChangesAndRefusesOverlappingVersions() {
        XCTAssertEqual(QMDMerge.merge(base: "a\nb\nc\n", editor: "A\nb\nc\n", external: "a\nb\nC\n"), "A\nb\nC\n")
        XCTAssertEqual(QMDMerge.merge(base: "a\nb\nc", editor: "a\nb\nc\nx", external: "A\nb\nc"), "A\nb\nc\nx")
        XCTAssertEqual(QMDMerge.merge(base: "a\nb\nc", editor: "a\nc", external: "a\nb\nC"), "a\nC")
        XCTAssertEqual(QMDMerge.merge(base: "中文\n```{r}\nx<-1\n```\n", editor: "中文\n```{r}\nx<-2\n```\n", external: "新标题\n```{r}\nx<-1\n```\n"), "新标题\n```{r}\nx<-2\n```\n")
        XCTAssertNil(QMDMerge.merge(base: "a\nb", editor: "a\nLOCAL", external: "a\nDISK"))
        XCTAssertNil(QMDMerge.merge(base: "a\nb", editor: "a\nx\nb", external: "a\ny\nb"))
        XCTAssertEqual(QMDMerge.merge(base: "a\nb", editor: "a\nx\nb", external: "a\nx\nb"), "a\nx\nb")
    }
    func testMergeDiffReconstructsDuplicateLinesEmptyLinesAndTerminalNewlines() {
        let versions = ["", "\n", "a", "a\n", "a\na\nb", "\na\n\nb\n", "中文\r\n重复\r\n", "x\ny\nz\n"]
        for a in versions { for b in versions {
            let base = a.components(separatedBy: "\n"), next = b.components(separatedBy: "\n")
            var result = base
            for edit in QMDMerge.edits(from: base, to: next).reversed() { result.replaceSubrange(edit.range, with: edit.replacement) }
            XCTAssertEqual(result, next)
        } }
    }
    func testLargeExternalRewritesUseBoundedReviewAndStillMergeDistantSmallEdits() throws {
        let lines = (0..<13_000).map { "base-\($0)" }
        let rewritten = (0..<13_000).map { "rewritten-\($0)" }
        let edits = QMDMerge.edits(from: lines, to: rewritten)
        XCTAssertEqual(edits.count, 1)
        var reconstructed = lines
        for edit in edits.reversed() { reconstructed.replaceSubrange(edit.range, with: edit.replacement) }
        XCTAssertEqual(reconstructed, rewritten)
        var local = lines, remote = lines
        local[0] = "local first"; remote[remote.count - 1] = "external last"
        let merged = try XCTUnwrap(QMDMerge.merge(base: lines.joined(separator: "\n"), editor: local.joined(separator: "\n"), external: remote.joined(separator: "\n")))
        XCTAssertTrue(merged.hasPrefix("local first\n"))
        XCTAssertTrue(merged.hasSuffix("\nexternal last"))
        XCTAssertNil(QMDMerge.merge(base: lines.joined(separator: "\n"), editor: rewritten.joined(separator: "\n"), external: remote.joined(separator: "\n")))
    }
    func testCanonicallyEquivalentUnicodeEditsAreSavedAndRecoveredAsExactUTF8() async throws {
        let original = "# Caf\u{e9}\n", changed = "# Cafe\u{301}\n"
        XCTAssertEqual(original, changed, "Swift treats these different encodings as equivalent text")
        let (doc, url, recovery) = try document(original, delay: 10, maximum: 10)
        doc.model.source = changed
        XCTAssertTrue(doc.sourceIsModified)
        XCTAssertEqual(try recovery.drafts(includeLiveOwners: true).first.map { Data($0.source.utf8) }, Data(changed.utf8))
        await doc.synchronization.saveNow(manual: true)
        XCTAssertEqual(try Data(contentsOf: url), Data(changed.utf8))
        XCTAssertFalse(doc.isDocumentEdited)
    }
    func testUnicodeNormalizationExternalChangesAndIndependentMergesPreserveExactBytes() async throws {
        let original = "caf\u{e9}\nsecond\n", changed = "cafe\u{301}\nsecond\n"
        let (doc, url, _) = try document(original, delay: 10, maximum: 10)
        try Data(changed.utf8).write(to: url)
        doc.synchronization.checkExternalChanges()
        XCTAssertEqual(Data(doc.model.source.utf8), Data(changed.utf8))
        XCTAssertFalse(doc.isDocumentEdited)
        let merged = try XCTUnwrap(QMDMerge.merge(base: original, editor: changed, external: "caf\u{e9}\nSECOND\n"))
        XCTAssertEqual(Data(merged.utf8), Data("cafe\u{301}\nSECOND\n".utf8))
        let edits = QMDMerge.edits(from: ["caf\u{e9}"], to: ["cafe\u{301}"])
        XCTAssertEqual(edits.count, 1, "A byte change is a source change even when it looks identical")
    }
    func testConflictChoiceRechecksUnicodeBytesBeforeOverwritingExternalChanges() async throws {
        let (doc, url, _) = try document("original\n", delay: 10, maximum: 10)
        doc.model.source = "local\n"
        try Data("caf\u{e9}\n".utf8).write(to: url)
        doc.synchronization.checkExternalChanges()
        XCTAssertNotNil(doc.synchronization.conflict)
        let newer = Data("cafe\u{301}\n".utf8)
        try newer.write(to: url)
        await doc.synchronization.resolve(.editor)
        XCTAssertEqual(try Data(contentsOf: url), newer, "Unreviewed normalization-only changes must not be overwritten")
        XCTAssertNotNil(doc.synchronization.conflict)
        XCTAssertEqual(doc.synchronization.conflict?.external.map { Data($0.utf8) }, newer)
        await doc.synchronization.resolve(.editor)
        XCTAssertEqual(try Data(contentsOf: url), Data("local\n".utf8))
    }
    func testIdleAutosaveWritesOnlyLatestUTF8QMDAndClearsRecoveryWithoutR() async throws {
        let (doc, url, store) = try document()
        doc.model.source = "第一版"
        doc.model.source = "---\ntitle: 最终版本\n---\n\n![](ordinary/image.png)\n```{r}\nx <- '001'\n```\n"
        XCTAssertNotEqual(try String(contentsOf: url, encoding: .utf8), doc.model.source)
        XCTAssertFalse(try store.drafts(includeLiveOwners: true).isEmpty)
        try await wait { !doc.isDocumentEdited }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), doc.model.source)
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).isEmpty)
        XCTAssertEqual(doc.model.notebook.state, .notStarted); XCTAssertTrue(doc.model.outputStates.isEmpty)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)), ["文件.qmd", "recovery"])
    }
    func testMaximumDelayPersistsDuringContinuousTyping() async throws {
        let (doc, url, _) = try document("original", delay: 0.3, maximum: 0.14)
        for i in 0..<8 {
            doc.model.source = "typing \(i)"
            try await Task.sleep(for: .milliseconds(40))
            if i == 4 { XCTAssertNotEqual(try String(contentsOf: url, encoding: .utf8), "original") }
        }
        try await wait { !doc.isDocumentEdited }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "typing 7")
    }
    func testWatcherReloadsExternalAtomicReplacementsWithoutWritingBackOrRunningR() async throws {
        let (doc, url, _) = try document()
        for text in ["external one", "external two"] {
            try Data(text.utf8).write(to: url, options: .atomic)
            try await wait { doc.model.source == text }
            XCTAssertFalse(doc.isDocumentEdited)
        }
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertTrue(doc.model.outputStates.isEmpty)
    }
    func testIndependentExternalEditsMergeIntoEditorAndAreSafelyAutosaved() async throws {
        let (doc, url, _) = try document(delay: 10, maximum: 10)
        doc.model.source = "ONE\ntwo\nthree\n"
        try Data("one\ntwo\nTHREE\n".utf8).write(to: url)
        doc.synchronization.checkExternalChanges()
        XCTAssertEqual(doc.model.source, "ONE\ntwo\nTHREE\n")
        XCTAssertNil(doc.synchronization.conflict)
        await doc.synchronization.saveNow()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ONE\ntwo\nTHREE\n")
        XCTAssertFalse(doc.isDocumentEdited)
    }
    func testConflictPausesAutosaveAndEditorChoiceOverwritesOnlyReviewedExternalVersion() async throws {
        let (doc, url, _) = try document("original")
        doc.model.source = "editor"
        try Data("external".utf8).write(to: url)
        doc.synchronization.checkExternalChanges()
        XCTAssertNotNil(doc.synchronization.conflict); XCTAssertTrue(doc.synchronization.paused)
        await doc.synchronization.resolve(.later)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        XCTAssertEqual(doc.model.source, "editor")
        await doc.synchronization.resolve(.editor)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "editor")
        XCTAssertFalse(doc.synchronization.paused); XCTAssertFalse(doc.isDocumentEdited)
    }
    func testExternalChoiceUpdatesEditorAndResumesAutosave() async throws {
        let (doc, url, store) = try document("original")
        doc.model.source = "editor"
        try Data("external".utf8).write(to: url)
        doc.synchronization.checkExternalChanges()
        await doc.synchronization.resolve(.external)
        XCTAssertEqual(doc.model.source, "external"); XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).isEmpty)
        doc.model.source = "new editor text"
        try await wait { !doc.isDocumentEdited }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new editor text")
    }
    func testComparisonRefreshesIfDiskOrEditorChangesAgainBeforeChoice() async throws {
        let (doc, url, _) = try document("original", delay: 10, maximum: 10)
        doc.model.source = "editor one"; try Data("disk one".utf8).write(to: url)
        doc.synchronization.checkExternalChanges()
        try Data("disk two".utf8).write(to: url)
        await doc.synchronization.resolve(.editor)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "disk two")
        XCTAssertEqual(doc.synchronization.conflict?.external, "disk two")
        doc.model.source = "editor two"
        await doc.synchronization.resolve(.external)
        XCTAssertEqual(doc.model.source, "editor two")
        XCTAssertEqual(doc.synchronization.conflict?.editor, "editor two")
        await doc.synchronization.resolve(.external)
        XCTAssertEqual(doc.model.source, "disk two")
    }
    func testDeletedAndInvalidUTF8ExternalFilesNeverSilentlyOverwriteOrEraseLocalText() async throws {
        let (doc, url, _) = try document("original", delay: 10, maximum: 10)
        doc.model.source = "keep editor"
        try FileManager.default.removeItem(at: url)
        doc.synchronization.checkExternalChanges()
        XCTAssertNotNil(doc.synchronization.conflict); XCTAssertNil(doc.synchronization.conflict?.external)
        await doc.synchronization.resolve(.editor)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep editor")
        try Data([0xff, 0xfe, 0xab]).write(to: url)
        doc.synchronization.checkExternalChanges()
        XCTAssertTrue(doc.synchronization.paused); XCTAssertNotNil(doc.synchronization.failure)
        XCTAssertEqual(doc.model.source, "keep editor")
        XCTAssertEqual(try Data(contentsOf: url), Data([0xff, 0xfe, 0xab]))
    }
    func testAutoSaveWaitsForInputMethodCompositionToCommit() async throws {
        let (doc, url, _) = try document("original")
        let editor = CompositionTextView(); editor.composing = true; editor.string = "confirmed source"
        doc.model.activeEditor = editor; doc.model.source = "confirmed source"
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        editor.composing = false
        try await wait { !doc.isDocumentEdited }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "confirmed source")
    }
    func testSaveAsRebindsWatcherAndSubsequentAutosavesToNewLocation() async throws {
        let (doc, original, _) = try document()
        let copy = original.deletingLastPathComponent().appendingPathComponent("new.qmd")
        try await doc.save(to: copy, ofType: "org.quarto.qmd", for: .saveAsOperation)
        try Data("old path changed".utf8).write(to: original)
        try Data("new path changed".utf8).write(to: copy)
        try await wait { doc.model.source == "new path changed" }
        XCTAssertEqual(doc.fileURL, copy)
        doc.model.source = "latest"
        try await wait { !doc.isDocumentEdited }
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "latest")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "old path changed")
    }
    func testNativeNewEditsBeforeNamingThenAutosavesAtChosenLocation() async throws {
        let root = try folder(), url = root.appendingPathComponent("新建.qmd")
        let controller = NSDocumentController.shared
        let doc = try XCTUnwrap(try controller.openUntitledDocumentAndDisplay(false) as? QMDDocument)
        defer { doc.close() }
        XCTAssertTrue(controller.documents.contains { $0 === doc })
        XCTAssertNil(doc.fileURL); XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(doc.fileType, "org.quarto.qmd")
        doc.model.source = "先写的中文正文\n"
        await doc.synchronization.saveNow()
        XCTAssertNil(doc.fileURL)
        XCTAssertTrue(doc.isDocumentEdited); XCTAssertTrue(doc.recoveryAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await doc.save(to: url, ofType: "org.quarto.qmd", for: .saveOperation)
        XCTAssertFalse(doc.isDocumentEdited); XCTAssertFalse(doc.recoveryAvailable)
        doc.model.source += "命名后自动保存\n"
        await doc.synchronization.saveNow()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), doc.model.source)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertTrue(doc.model.outputStates.isEmpty)
    }
    func testNativeRenameFollowsNewPathAndPreservesAutosaveAndExternalReload() async throws {
        let (doc, original, _) = try document()
        let renamed = original.deletingLastPathComponent().appendingPathComponent("重命名.qmd")
        try await doc.move(to: renamed)
        XCTAssertEqual(doc.fileURL, renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        doc.model.source = "命名后的修改"
        await doc.synchronization.saveNow()
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "命名后的修改")
        try Data("外部修改新名称".utf8).write(to: renamed, options: .atomic)
        try await wait { doc.model.source == "外部修改新名称" }
        XCTAssertFalse(doc.synchronization.paused)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
    }
    func testNativeInPlaceAutosaveUsesSameBaselineAndClearsRecovery() async throws {
        let (doc, url, store) = try document(delay: 30, maximum: 60)
        doc.model.source = "原生自动保存"
        try await doc.autosave(withImplicitCancellability: false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), doc.model.source)
        XCTAssertFalse(doc.sourceIsModified)
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).isEmpty)
        try Data("已接受的外部版本".utf8).write(to: url, options: .atomic)
        doc.synchronization.checkExternalChanges()
        XCTAssertEqual(doc.model.source, "已接受的外部版本")
        doc.model.source = "在外部版本上继续写"
        try await doc.autosave(withImplicitCancellability: false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), doc.model.source)
        XCTAssertFalse(doc.synchronization.paused)
        XCTAssertTrue(try store.drafts(includeLiveOwners: true).isEmpty)
    }
    func testExternalReloadSynchronizesVisibleEditorWithoutROrAdditionalFiles() async throws {
        let (doc, url, _) = try document()
        doc.makeWindowControllers(); doc.windowControllers.first?.showWindow(nil)
        try await Task.sleep(for: .milliseconds(250))
        try Data("# 新的正文\n\n```{r}\nstop('do not run')\n```\n".utf8).write(to: url, options: .atomic)
        try await wait { doc.model.activeEditor?.string == doc.model.source && doc.model.source.contains("新的正文") }
        XCTAssertEqual(doc.model.notebook.state, .notStarted); XCTAssertTrue(doc.model.outputStates.isEmpty)
        XCTAssertFalse(doc.isDocumentEdited)
    }
}

@MainActor private final class CompositionTextView: NSTextView {
    var composing = false
    override func hasMarkedText() -> Bool { composing }
}
