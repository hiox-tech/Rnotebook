import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class DocumentTests: XCTestCase {
    func testQMDSourceRoundTripsExactlyAndCreatesNoProject() throws {
        let doc = QMDDocument()
        let text = "---\ntitle: 中文\n---\n\n```{r}\nx <- '001'\n```\n\n![图](images/a.png)\n"
        try doc.read(from: Data(text.utf8), ofType: "org.quarto.qmd")
        XCTAssertEqual(try doc.data(ofType: "org.quarto.qmd"), Data(text.utf8))
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertTrue(doc.model.outputStates.isEmpty)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        doc.close()
    }
    func testInvalidEncodingDoesNotReplaceDocument() throws {
        let doc = QMDDocument(); doc.model.source = "保留正文"
        XCTAssertThrowsError(try doc.read(from: Data([0xff, 0xfe]), ofType: "org.quarto.qmd"))
        XCTAssertEqual(doc.model.source, "保留正文")
        doc.updateChangeCount(.changeCleared); doc.close()
    }
    func testDocumentDirectoryFollowsFileURLAndSourceChangesMarkDirty() throws {
        let doc = QMDDocument(); let url = URL(fileURLWithPath: "/tmp/report.qmd")
        doc.fileURL = url
        XCTAssertEqual(doc.model.notebookDirectory, url.deletingLastPathComponent())
        doc.model.source = "new source"
        XCTAssertTrue(doc.isDocumentEdited)
        doc.updateChangeCount(.changeCleared); doc.close()
    }
    func testEditorAndSidebarMaterialInspectorHaveNoLeftPanelOrSidebarButton() throws {
        let doc = QMDDocument(); doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertEqual(split.splitViewItems.count, 2)
        XCTAssertEqual(split.splitViewItems[1].behavior, .inspector)
        let material = try XCTUnwrap(split.splitViewItems[1].viewController.view as? NSVisualEffectView)
        XCTAssertEqual(material.material, .sidebar)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        XCTAssertFalse(split.splitViewItems[1].canCollapse)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        let ids = try XCTUnwrap(window.toolbar?.items.map { $0.itemIdentifier.rawValue })
        XCTAssertFalse(ids.contains(NSToolbarItem.Identifier.toggleSidebar.rawValue))
        XCTAssertFalse(ids.contains(NSToolbarItem.Identifier.sidebarTrackingSeparator.rawValue))
        XCTAssertTrue(ids.contains("render"))
        XCTAssertFalse(ids.contains(where: { $0.contains("project") || $0.contains("data") }))
        if let outputPath = ProcessInfo.processInfo.environment["RNOTEBOOK_LAYOUT_EVIDENCE"] {
            let output = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            window.makeKeyAndOrderFront(nil)
            for (name, width, appearance) in [("light-960", 960.0, NSAppearance.Name.aqua),
                                              ("light-1160", 1160.0, .aqua),
                                              ("light-1440", 1440.0, .aqua),
                                              ("dark-1160", 1160.0, .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: width, height: 760))
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
                try capture.run(); capture.waitUntilExit()
                print("LAYOUT_CAPTURE", name, capture.terminationStatus)
            }
        }
        doc.close()
    }
    func testQuartoHTMLUsesExternalCSVWithoutCollectingResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-export-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("报告.qmd")
        let csv = root.appendingPathComponent("data.csv")
        try Data("x\n19\n23\n".utf8).write(to: csv)
        let source = "---\ntitle: Test\n---\n\n```{r}\nsum(read.csv('data.csv')$x)\n```\n"
        try Data(source.utf8).write(to: url)
        let tools = QuartoExportTools(quarto: try XCTUnwrap(QuartoExecutable.locate()), rscript: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 90)
        var options = QuartoExportOptions(); options.openAfterExport = false
        let output = root.appendingPathComponent("report.html")
        let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options,
            tools: tools, destination: try .init(output, overwrite: false), directory: root.appendingPathComponent("job"),
            process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
        XCTAssertEqual(result.status, .succeeded, result.diagnostic ?? "")
        if result.status == .succeeded { XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("42")) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), "x\n19\n23\n")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("rnotebook-render-") || $0.hasPrefix(".rnotebook-render-") })
    }
}
