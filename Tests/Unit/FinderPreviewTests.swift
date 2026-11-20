import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class FinderPreviewTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testBothFormatsOfferHighlightedReadOnlySourceAndVisualWithoutExecutingOrWriting() async throws {
        let root = try directory()
        let marker = root.appendingPathComponent("must-not-execute")
        let source = "# Preview 中文🙂\n\n**bold**\n\n```{r}\n# no execution\nx <- 23\nmean(x)\nwriteLines('ran', '\(marker.path)')\n```\n"
        for ext in ["qmd", "Rmd"] {
            let url = root.appendingPathComponent("report." + ext)
            let bytes = Data(source.utf8)
            try bytes.write(to: url)
            let controller = NotebookPreviewViewController()
            XCTAssertTrue(controller.responds(to: NSSelectorFromString("preparePreviewOfFileAtURL:completionHandler:")))
            try await controller.preparePreviewOfFile(at: url)
            XCTAssertEqual(controller.modeControl.segmentCount, 2)
            XCTAssertEqual(controller.modeControl.selectedSegment, 1)
            let location = (source as NSString).range(of: "mean").location
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                controller.view.appearance = NSAppearance(named: appearance)
                var colors: [NSColor] = []
                for segment in [0, 1, 0, 1] {
                    controller.modeControl.selectedSegment = segment
                    controller.changeMode(nil)
                    let editor = try XCTUnwrap(controller.editor)
                    XCTAssertFalse(editor.isEditable)
                    XCTAssertEqual(editor.rawSource, source)
                    XCTAssertFalse(editor.canUndoSource)
                    let attrs = try XCTUnwrap(editor.textStorage?.attributes(at: location, effectiveRange: nil))
                    XCTAssertEqual(attrs[RecordRSyntaxAdapter.scopeKey] as? String, "function")
                    colors.append(try XCTUnwrap(attrs[.foregroundColor] as? NSColor))
                    let heading = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
                    if segment == 0 { XCTAssertEqual(heading.pointSize, 13) }
                    else { XCTAssertGreaterThan(heading.pointSize, 13) }
                }
                XCTAssertTrue(colors.allSatisfy { $0 == colors[0] })
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["report.Rmd", "report.qmd"])
    }

    func testPreviewReadsEmptyUnicodeCRLFAndRejectsInvalidEncodingUnsupportedFilesAndOversize() throws {
        let root = try directory()
        for (index, text) in ["", "---\r\ntitle: 中文🙂\r\n---\r\n```{r}\r\nx <- 1\r\n```\r\n"].enumerated() {
            let url = root.appendingPathComponent("\(index).qmd")
            try Data(text.utf8).write(to: url)
            XCTAssertEqual(try NotebookPreviewContent.load(from: url).source, text)
        }
        let invalid = root.appendingPathComponent("bad.rmd")
        try Data([0xff]).write(to: invalid)
        XCTAssertThrowsError(try NotebookPreviewContent.load(from: invalid))
        let oversized = root.appendingPathComponent("large.qmd")
        try Data(repeating: 32, count: NotebookPreviewContent.maximumBytes + 1).write(to: oversized)
        XCTAssertThrowsError(try NotebookPreviewContent.load(from: oversized))
        XCTAssertThrowsError(try NotebookPreviewContent.load(from: root.appendingPathComponent("other.txt")))
    }

    func testPreviewPageRoundsTopCornersWhileTheHostOwnsBottomCorners() throws {
        let controller = NotebookPreviewViewController()
        let view = controller.view
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(view.layer?.cornerRadius ?? 0, 12)
        XCTAssertEqual(view.layer?.cornerCurve, .continuous)
        XCTAssertEqual(view.layer?.masksToBounds, true)
        XCTAssertTrue(view.layer?.maskedCorners.contains(.layerMinXMaxYCorner) ?? false)
        XCTAssertTrue(view.layer?.maskedCorners.contains(.layerMaxXMaxYCorner) ?? false)
        XCTAssertFalse(view.layer?.maskedCorners.contains(.layerMinXMinYCorner) ?? true)
        XCTAssertFalse(view.layer?.maskedCorners.contains(.layerMaxXMinYCorner) ?? true)
    }

    func testReusedPreviewReplacesThePreviousDocumentAndRemainsReadOnly() async throws {
        let root = try directory(), controller = NotebookPreviewViewController()
        for (name, source) in [("first.qmd", "# First\n```{r}\nmean(1)\n```\n"), ("second.rmd", "# Second\n```{r}\nsum(2)\n```\n")] {
            let url = root.appendingPathComponent(name)
            try Data(source.utf8).write(to: url)
            try await controller.preparePreviewOfFile(at: url)
            XCTAssertEqual(controller.editor.rawSource, source)
            XCTAssertFalse(controller.editor.isEditable)
        }
        XCTAssertFalse(controller.editor.rawSource.contains("mean"))
    }

    func testRMDUsesNativeDocumentAssociationAndAutosavesWithoutChangingExtensionOrContent() async throws {
        let root = try directory(), url = root.appendingPathComponent("报告.Rmd")
        let source = "---\ntitle: Rmd\n---\n\n```{r}\nx <- '001'\n```\n"
        try Data(source.utf8).write(to: url)
        let controller = QMDDocumentController()
        XCTAssertEqual(try controller.typeForContents(of: url), NotebookDocumentType.rMarkdown)
        XCTAssertEqual(try controller.typeForContents(of: root.appendingPathComponent("report.QMD")), NotebookDocumentType.quarto)
        let doc = try XCTUnwrap(try controller.makeDocument(withContentsOf: url, ofType: NotebookDocumentType.rMarkdown) as? QMDDocument)
        defer { doc.close() }
        XCTAssertEqual(doc.fileType, NotebookDocumentType.rMarkdown)
        XCTAssertEqual(doc.model.source, source)
        doc.model.source += "\n# Changed 中文🙂\n"
        await doc.synchronization.saveNow(manual: true)
        XCTAssertEqual(doc.fileURL, url)
        XCTAssertEqual(doc.fileType, NotebookDocumentType.rMarkdown)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), doc.model.source)
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertTrue(doc.model.outputStates.isEmpty)
        // NSDocument removes its transient safe-save backup after version preservation settles.
        for _ in 0..<100 {
            if try FileManager.default.contentsOfDirectory(atPath: root.path) == ["报告.Rmd"] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["报告.Rmd"])
    }

    func testRecoveredRMDDraftRetainsItsSaveTypeAndDoesNotOverwriteOriginal() throws {
        let root = try directory(), url = root.appendingPathComponent("original.rmd")
        try Data("original".utf8).write(to: url)
        let store = DocumentRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let id = UUID()
        try store.write(id: id, source: "draft", originalURL: url)
        let doc = QMDDocument(recoveryStore: store)
        defer { doc.close() }
        doc.restore(try XCTUnwrap(store.drafts(includeLiveOwners: true).first))
        XCTAssertEqual(doc.fileType, NotebookDocumentType.rMarkdown)
        XCTAssertNil(doc.fileURL)
        XCTAssertEqual(doc.model.source, "draft")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testLongPreviewCanScrollToLastLineAndBackInBothModesAfterResize() async throws {
        let root = try directory(), url = root.appendingPathComponent("long.qmd")
        let source = (1...180).map { "## Section \($0)\n\nParagraph \($0) 中文🙂 with enough text to wrap across a narrower preview window.\n\n```{r}\nmean(c(1, 2, \($0)))\n```\n" }.joined(separator: "\n") + "\nPREVIEW_END_MARKER\n"
        try Data(source.utf8).write(to: url)
        let controller = NotebookPreviewViewController()
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 800, height: 600))
        try await controller.preparePreviewOfFile(at: url)
        for width in [800.0, 420.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            for segment in [1, 0, 1] {
                controller.modeControl.selectedSegment = segment; controller.changeMode(nil)
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
                let editor = try XCTUnwrap(controller.editor), scroll = try XCTUnwrap(editor.enclosingScrollView)
                XCTAssertGreaterThan(editor.frame.height, scroll.contentSize.height * 2)
                editor.scrollToEndOfDocument(nil)
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100)
                let end = (editor.string as NSString).range(of: "PREVIEW_END_MARKER")
                editor.scrollRangeToVisible(end)
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, editor.frame.height * 0.8)
                editor.scrollToBeginningOfDocument(nil)
                let first = (editor.string as NSString).range(of: "Section 1")
                let screen = editor.firstRect(forCharacterRange: first, actualRange: nil)
                let line = editor.convert(window.convertFromScreen(screen), from: nil)
                XCTAssertLessThanOrEqual(editor.visibleRect.minY, line.minY + 1)
                XCTAssertGreaterThanOrEqual(editor.visibleRect.maxY, line.maxY - 1)
                print("PREVIEW_SCROLL", width, segment, editor.frame.height, scroll.contentSize.height, scroll.contentView.bounds.minY, line.minY)
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
}
