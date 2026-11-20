import AppKit
import CryptoKit
import XCTest
@testable import Rnotebook

/// End-to-end use of the public example documents. Every writable document is
/// a fresh evidence copy; user examples and sessions are never test subjects.
@MainActor final class ComprehensiveWorkflowTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private lazy var evidence = root.appendingPathComponent(".local/validation/full-audit-2026-11-14/rich-runs/" + UUID().uuidString)

    private func workspace() throws -> URL {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let copy = evidence.appendingPathComponent("documents")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Examples/FeatureValidation"), to: copy)
        return copy
    }
    private func document(_ url: URL, show: Bool = false) throws -> QMDDocument {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Rnotebook-RichWorkflow-" + UUID().uuidString))
        let behavior = DocumentBehaviorSettings(defaults: defaults)
        behavior.rememberWindows = false
        let doc = QMDDocument(recoveryStore: DocumentRecoveryStore(directory: evidence.appendingPathComponent("Recovery")),
                              autosaveDelay: 10, maximumAutosaveDelay: 10, behavior: behavior)
        doc.fileURL = url
        try doc.read(from: url, ofType: NotebookDocumentType.identifier(for: url))
        if show { doc.makeWindowControllers(); doc.windowControllers.first?.window?.makeKeyAndOrderFront(nil) }
        addTeardownBlock { @MainActor in
            doc.close(); await doc.model.notebook.shutdown(); await doc.model.exporter.shutdown()
        }
        return doc
    }
    private func settle(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let end = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition())
    }
    private func output(_ model: RecordLayoutModel) -> String {
        model.outputStates.values.flatMap(\.events).map {
            switch $0 { case .text(let s), .message(let s), .warning(let s), .error(let s): s; default: "" }
        }.joined(separator: "\n")
    }
    private func report(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(name))
    }

    func testRichNotebookExecutionNativeModeFormatUndoSaveAndReopen() async throws {
        let folder = try workspace(), url = folder.appendingPathComponent("01-全功能体验.qmd")
        let bytes = try Data(contentsOf: url), doc = try document(url, show: true), model = doc.model
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        let host = try XCTUnwrap(model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        let jobs = model.notebookJobs(all: true)
        XCTAssertEqual(jobs.count, 14, model.notice ?? "")
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 13, output(model))
        XCTAssertEqual(model.notebook.skippedCount, 1)
        XCTAssertEqual(model.notebook.failedCount, 0, model.notebook.diagnostic ?? output(model))
        XCTAssertTrue(output(model).contains("FEATURE_VALIDATION_OK"))
        let images = model.outputStates.values.flatMap(\.events).filter { if case .image = $0 { true } else { false } }.count
        let tables = model.outputStates.values.flatMap(\.events).filter { if case .rich = $0 { true } else { false } }.count
        XCTAssertGreaterThanOrEqual(images, 3)
        XCTAssertGreaterThanOrEqual(tables, 4)
        let session = model.notebook.sessionID
        for code in [true, false, true, false] {
            model.sourceOnly = code; host.update()
            try await Task.sleep(for: .milliseconds(70))
            XCTAssertEqual(Data(host.editor.rawSource.utf8), bytes)
            XCTAssertEqual(Data(model.source.utf8), bytes)
        }
        XCTAssertEqual(model.notebook.sessionID, session)
        window.makeFirstResponder(host.editor)
        model.formatRBlock("feature-format")
        try await settle { Data(model.source.utf8) != bytes }
        host.undoSource(nil)
        XCTAssertEqual(Data(model.source.utf8), bytes, "Formatting is exactly one source undo")
        let count = try await model.notebook.runtime.evaluate(.init(cellID: "rich-no-repeat", source: "stopifnot(feature_runs == 1L, bootstrap_runs == 1L); cat('NO_DUPLICATE_EXECUTION_OK')"))
        XCTAssertTrue(count.events.contains { $0.payload.text?.contains("NO_DUPLICATE_EXECUTION_OK") == true })
        host.editor.insertText("\n真实编辑与保存 😀\n", replacementRange: NSRange(location: host.editor.string.utf16.count, length: 0))
        host.publishCommittedText()
        XCTAssertTrue(doc.isDocumentEdited)
        await doc.synchronization.saveNow(manual: true)
        XCTAssertEqual(try Data(contentsOf: url), Data(model.source.utf8))
        XCTAssertFalse(doc.isDocumentEdited)
        host.undoSource(nil)
        await doc.synchronization.saveNow(manual: true)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        await model.notebook.shutdown(); doc.close()
        let reopened = try document(url)
        XCTAssertEqual(Data(reopened.model.source.utf8), bytes)
        XCTAssertEqual(reopened.model.notebook.state, .notStarted)
        XCTAssertTrue(reopened.model.outputStates.isEmpty)
        try report("execution.json", ["planned": jobs.count, "passed": 13, "skipped": 1, "images": images, "richTables": tables,
                                      "singleEvaluation": true, "formatSingleUndo": true, "saveReopenExact": true])
    }

    func testPublicPolicyLiteralAndRMDFixturesUseOnlyIntendedCode() async throws {
        let folder = try workspace()
        for (file, passed, skipped, failed, pending, marker) in [
            ("02-执行与错误边界.qmd", 3, 1, 2, 1, "POLICY_CONTINUED_OK"),
            ("03-语法与容器.qmd", 3, 0, 0, 0, "CONTAINER_VALIDATION_OK"),
            ("05-RMD兼容.Rmd", 2, 1, 0, 0, "RMD_COMPATIBILITY_OK")
        ] {
            let url = folder.appendingPathComponent(file), bytes = try Data(contentsOf: url), doc = try document(url), model = doc.model
            model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
            XCTAssertEqual(model.notebook.completedCount, passed, file + " " + output(model))
            XCTAssertEqual(model.notebook.skippedCount, skipped, file)
            XCTAssertEqual(model.notebook.failedCount, failed, file)
            XCTAssertEqual(model.notebook.pendingCount, pending, file)
            XCTAssertTrue(output(model).contains(marker), file + " " + (model.notice ?? ""))
            XCTAssertFalse(output(model).contains("POLICY_THIS_MUST_NOT_RUN_IN_BATCH"))
            XCTAssertFalse(output(model).contains("LITERAL_FENCE_MUST_NOT_RUN"))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            if file.hasSuffix("Rmd") { XCTAssertEqual(doc.fileType, NotebookDocumentType.rMarkdown) }
            await model.notebook.shutdown(); doc.close()
        }
        let rejected = try document(folder.appendingPathComponent("06-结构拒绝边界.qmd"))
        XCTAssertTrue(rejected.model.notebookJobs(all: true).isEmpty)
        XCTAssertNotNil(rejected.model.notice)
        rejected.model.runNotebookBlock("structural-safe")
        await rejected.model.notebook.waitUntilIdle()
        XCTAssertTrue(output(rejected.model).contains("STRUCTURE_MANUAL_SAFE_OK"))
    }

    func testLongPublicNotebookSkipsWithoutRAndPreservesNavigationSearchAndSource() async throws {
        let folder = try workspace(), url = folder.appendingPathComponent("04-长文档与查找.qmd")
        let bytes = try Data(contentsOf: url), start = Date(), doc = try document(url, show: true), model = doc.model
        let host = try XCTUnwrap(model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        model.sourceOnly = true; host.update()
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.skippedCount, 120)
        XCTAssertEqual(model.notebook.state, .notStarted)
        XCTAssertNil(model.notebook.sessionID)
        host.folding.setAll(collapsed: true, kind: .heading)
        let end = (host.editor.string as NSString).range(of: "LONG_DOCUMENT_END")
        host.editor.setSelectedRange(end)
        host.editor.scrollRangeToVisible(end)
        model.findInDocument(action: .showFindInterface)
        host.documentFinder.bar.query.stringValue = "needle"
        host.documentFinder.bar.queryChanged?("needle")
        try await settle { host.documentFinder.matches.count == 360 }
        host.documentFinder.bar.wholeWord = true
        host.documentFinder.bar.optionsChanged?()
        try await settle { host.documentFinder.matches.count == 240 }
        model.findInDocument(action: .hideFindInterface)
        for code in [false, true] { model.sourceOnly = code; host.update() }
        XCTAssertEqual(Data(model.source.utf8), bytes)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try report("long-document.json", ["bytes": bytes.count, "blocks": 120, "literalMatches": 360,
                                          "wholeWordMatches": 240, "elapsedSeconds": Date().timeIntervalSince(start), "RStarted": false])
    }

    func testRichPublicNotebookExportsHTMLWordTypstAndLaTeXWithSourcePreserved() async throws {
        let folder = try workspace(), url = folder.appendingPathComponent("01-全功能体验.qmd"), source = try String(contentsOf: url, encoding: .utf8)
        let original = Data(source.utf8), csv = try Data(contentsOf: folder.appendingPathComponent("measurements.csv"))
        let tools = QuartoExportTools(quarto: try XCTUnwrap(QuartoExecutable.locate()), rscript: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 120)
        var results: [[String: Any]] = []
        for format in QuartoExportFormat.allCases {
            var options = QuartoExportOptions(); options.format = format; options.openAfterExport = false
            let output = evidence.appendingPathComponent("rich-\(format.rawValue).\(format.fileExtension)"), job = evidence.appendingPathComponent("render-" + format.rawValue)
            let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options, tools: tools,
                destination: try .init(output, overwrite: false), directory: job, process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
            let logs = (try? String(contentsOf: job.appendingPathComponent("stderr.log"), encoding: .utf8)) ?? ""
            let missingTeX = format == .pdf && result.status == .failed && logs.contains("xeCJK.sty") && logs.contains("not found")
            results.append(["format": format.rawValue, "status": result.status.rawValue, "diagnostic": result.diagnostic ?? "", "output": output.path,
                            "environmentBlocked": missingTeX, "missingDependency": missingTeX ? "xeCJK.sty" : ""])
            try report("exports.json", results)
            if missingTeX {
                XCTAssertTrue(logs.contains("automatic installed disabled"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            } else {
                XCTAssertEqual(result.status, .succeeded, format.rawValue + " " + (result.diagnostic ?? "") + " logs=" + job.path)
            }
            if result.status == .succeeded {
                let data = try Data(contentsOf: output)
                if format == .html {
                    let html = String(decoding: data, as: UTF8.self)
                    XCTAssertTrue(html.contains("FEATURE_VALIDATION_OK"))
                    XCTAssertTrue(html.contains("data:image"))
                } else if format == .docx { XCTAssertTrue(data.starts(with: [0x50, 0x4b])) }
                else { XCTAssertTrue(data.starts(with: Data("%PDF-".utf8))) }
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("measurements.csv")), csv)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("rnotebook-render-") })
    }
}
