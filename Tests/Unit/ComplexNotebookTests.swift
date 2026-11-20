import AppKit
import CryptoKit
import XCTest
@testable import Rnotebook

@MainActor final class ComplexNotebookTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var example: URL { root.appendingPathComponent("Examples/ComplexNotebook/复杂验证.qmd") }
    private lazy var evidence = root.appendingPathComponent(".local/validation/complex-notebook-runs/" + UUID().uuidString)
    private func save(_ name: String, _ report: Any) throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(name), options: .atomic)
    }
    private func text(_ events: [RecordOutputEvent]) -> String {
        events.map { switch $0 { case .text(let s), .message(let s), .warning(let s), .error(let s): s; default: "" } }.joined(separator: "\n")
    }
    func testComplexNotebookRealExecutionVisualRoundTripAndSave() async throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let source = try String(contentsOf: example, encoding: .utf8)
        let doc = QMDDocument(); doc.fileURL = example
        try doc.read(from: Data(source.utf8), ofType: "org.quarto.qmd")
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        window.orderFront(nil)
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let model = doc.model
        let blocks = model.visualBlocks.blocks(in: source).filter { $0.language == "r" }
        XCTAssertEqual(blocks.count, 12)
        XCTAssertTrue(FenceScanner().scan(source).issues.isEmpty)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        var report: [[String: Any]] = []; var imageCount = 0; var richCount = 0
        for block in blocks {
            let output = try XCTUnwrap(model.outputStates[block.id], "Missing block \(block.id), \(model.notebook.diagnostic ?? "")")
            var images = 0; var rich = 0
            for event in output.events {
                if case .image(let image, let rawPNG) = event {
                    let png = try XCTUnwrap(rawPNG)
                    images += 1
                    XCTAssertNotNil(NSBitmapImageRep(data: png))
                    if imageCount == 0 { try png.write(to: evidence.appendingPathComponent("first-runtime-plot.png")) }
                    let view = RecordResultImageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                    view.image = image; view.originalPNG = png
                    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                    XCTAssertTrue(view.copyImage(to: board)); XCTAssertEqual(board.data(forType: .png), png)
                }
                if case .rich = event { rich += 1 }
            }
            imageCount += images; richCount += rich
            report.append(["block":block.id,"failed":output.failed,"stopped":output.stopped,"text":text(output.events),"images":images,"richTables":rich])
        }
        try save("model-execution.json", ["completed":model.notebook.completedCount,"blocks":report,"images":imageCount,"richTables":richCount])
        XCTAssertEqual(model.notebook.completedCount, 12, String(describing: report))
        XCTAssertTrue(report.allSatisfy { $0["failed"] as? Bool == false })
        XCTAssertGreaterThanOrEqual(imageCount, 4); XCTAssertGreaterThanOrEqual(richCount, 5)
        XCTAssertTrue(report.contains { ($0["text"] as? String ?? "").contains("COMPLEX_VALIDATION_OK") })
        let session = model.notebook.sessionID
        for _ in 0..<3 {
            model.sourceOnly = true; try await Task.sleep(for: .milliseconds(70))
            model.sourceOnly = false; try await Task.sleep(for: .milliseconds(70))
        }
        XCTAssertEqual(model.source, source); XCTAssertEqual(model.notebook.sessionID, session)
        let readback = try await model.notebook.runtime.evaluate(.init(cellID: "validation-counts", source: "stopifnot(.validation_run_count == 1L, .bootstrap_runs == 1L); cat('SINGLE_EXECUTION_OK\\n')"))
        XCTAssertTrue(readback.events.contains { $0.payload.text?.contains("SINGLE_EXECUTION_OK") == true })
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 12, "Explicit rerun must succeed")
        XCTAssertTrue(model.outputStates.values.allSatisfy { !$0.failed && !$0.stopped })
        let second = try await model.notebook.runtime.evaluate(.init(cellID: "validation-explicit-rerun", source: "stopifnot(.validation_run_count == 2L, .bootstrap_runs == 1L); cat('EXPLICIT_RERUN_OK\\n')"))
        XCTAssertTrue(second.events.contains { $0.payload.text?.contains("EXPLICIT_RERUN_OK") == true })
        let saved = try doc.data(ofType: "org.quarto.qmd")
        XCTAssertEqual(saved, Data(source.utf8))
        let reopened = QMDDocument(); try reopened.read(from: saved, ofType: "org.quarto.qmd")
        XCTAssertTrue(reopened.model.outputStates.isEmpty); XCTAssertEqual(reopened.model.notebook.state, .notStarted)
        reopened.close()
    }
    func testComplexNotebookHTMLWordAndTypstRenderFromExternalCSV() async throws {
        let source = try String(contentsOf: example, encoding: .utf8)
        let original = try Data(contentsOf: example)
        let csv = try Data(contentsOf: example.deletingLastPathComponent().appendingPathComponent("measurements.csv"))
        let tools = QuartoExportTools(quarto: try XCTUnwrap(QuartoExecutable.locate()), rscript: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 120)
        let folder = evidence.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for format in [QuartoExportFormat.html, .docx, .typst] {
            var options = QuartoExportOptions(); options.format = format; options.openAfterExport = false
            let output = folder.appendingPathComponent("复杂验证-\(format.rawValue).\(format.fileExtension)")
            let job = evidence.appendingPathComponent("render-\(format.rawValue)-\(UUID().uuidString)")
            let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: example), options: options, tools: tools,
                destination: try .init(output, overwrite: true), directory: job, process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
            var report: [String: Any] = ["format":format.rawValue,"status":result.status.rawValue,"diagnostic":result.diagnostic ?? "","job":job.path,"output":output.path]
            if result.status == .succeeded {
                let bytes = try Data(contentsOf: output); report["bytes"] = bytes.count
                XCTAssertGreaterThan(bytes.count, 1000)
                switch format {
                case .html:
                    let html = try String(contentsOf: output, encoding: .utf8)
                    XCTAssertTrue(html.contains("COMPLEX_VALIDATION_OK")); XCTAssertTrue(html.contains("233")); XCTAssertTrue(html.contains("data:image"))
                case .docx: XCTAssertTrue(bytes.starts(with: [0x50,0x4b]))
                case .typst: XCTAssertTrue(bytes.starts(with: Data("%PDF-".utf8)))
                default: break
                }
            }
            reports.append(report); try save("exports.json", reports)
            XCTAssertEqual(result.status, .succeeded, "\(format.rawValue): \(result.diagnostic ?? "") log=\(job.path)")
        }
        XCTAssertEqual(try Data(contentsOf: example), original)
        XCTAssertEqual(try Data(contentsOf: example.deletingLastPathComponent().appendingPathComponent("measurements.csv")), csv)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: example.deletingLastPathComponent().path).contains { $0.hasPrefix("rnotebook-render-") || $0.hasPrefix(".rnotebook-render-") })
    }
}
