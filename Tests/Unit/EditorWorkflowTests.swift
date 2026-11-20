import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class EditorWorkflowTests: XCTestCase {
    func testBlankLinesCanStartEveryHeadingLevelAndUndoWithoutChangingNeighbors() throws {
        let fixtures: [(String, Int, String, String)] = [
            ("", 0, "", ""), ("\n", 0, "", "\n"),
            ("前文🙂\n\n后文\n", 5, "前文🙂\n", "\n后文\n"),
            ("前文\n", 3, "前文\n", ""),
            ("前文\n \t \n后文\n", 4, "前文\n", "\n后文\n"),
            // The native editor normalizes CRLF on load; locations use its text.
            ("前文\r\n\r\n后文\r\n", 3, "前文\n", "\n后文\n")
        ]
        for (source, location, before, after) in fixtures {
            for level in 1...6 {
                let model = RecordLayoutModel(initialSource: source, usesProcessArguments: false)
                let host = RecordNativeEditorHost(model: model)
                defer { host.detach() }
                let loaded = host.editor.rawSource
                host.editor.setSelectedRange(NSRange(location: location, length: 0)); model.refreshVisualContext()
                XCTAssertTrue(model.canFormat(.heading(level)))
                model.format(.heading(level)); host.publishCommittedText()
                let prefix = String(repeating: "#", count: level) + " "
                XCTAssertEqual(model.source, before + prefix + after)
                XCTAssertEqual(host.editor.selectedRange(), NSRange(location: before.utf16.count + prefix.utf16.count, length: 0))
                XCTAssertEqual(model.visualContext.heading, level)
                host.undoSource(nil); XCTAssertEqual(model.source, loaded)
                host.redoSource(nil); XCTAssertEqual(model.source, before + prefix + after)
                host.undoSource(nil)
                host.editor.setSelectedRange(NSRange(location: location, length: 0))
                model.format(.heading(level))
                host.editor.insertText("新标题", replacementRange: host.editor.selectedRange()); host.publishCommittedText()
                XCTAssertEqual(model.source, before + prefix + "新标题" + after)
            }
        }
    }
    func testEmptyHeadingStepCommandsAndBlankLinesInsideSyntax() throws {
        let model = RecordLayoutModel(initialSource: "\n", usesProcessArguments: false)
        let host = RecordNativeEditorHost(model: model)
        defer { host.detach() }
        host.editor.setSelectedRange(NSRange(location: 0, length: 0))
        model.format(.headingIncrease); XCTAssertEqual(model.source, "# \n")
        model.format(.headingIncrease); XCTAssertEqual(model.source, "## \n")
        model.format(.headingDecrease); XCTAssertEqual(model.source, "# \n")
        model.format(.heading(0)); XCTAssertEqual(model.source, "\n")
        model.format(.headingDecrease); XCTAssertEqual(model.source, "\n")
        for source in ["---\ntitle: x\n\n---\n", "```{r}\n\n```\n", "$$\n\n$$\n", "```{r}\n"] {
            let protected = RecordLayoutModel(initialSource: source, usesProcessArguments: false)
            let protectedHost = RecordNativeEditorHost(model: protected)
            defer { protectedHost.detach() }
            let blank = (source as NSString).range(of: "\n\n")
            let location = blank.location == NSNotFound ? source.utf16.count : blank.location + 1
            protectedHost.editor.setSelectedRange(NSRange(location: location, length: 0)); protected.refreshVisualContext()
            XCTAssertTrue(protected.canFormat(.heading(2)))
            protected.format(.heading(2))
            XCTAssertEqual(protected.source, (source as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "## "))
        }
    }
    func testAllToolbarCommandsStayAvailableInsideSyntaxAndWithFeaturesDisabled() throws {
        let commands = RecordVisualToolbarEntry.ordered.flatMap(\.reachableCommands) + [.headingIncrease, .headingDecrease]
        for source in ["", "---\ntitle: target\n---\n", "```{r}\ntarget\n```\n", "$$\ntarget\n$$\n",
                       "| target |\n| --- |\n| value |\n", "<!-- target -->\n", "    target\n"] {
            let model = RecordLayoutModel(initialSource: source, usesProcessArguments: false)
            let host = RecordNativeEditorHost(model: model)
            defer { host.detach() }
            host.editor.markdownFeatures = []
            let target = (host.editor.rawSource as NSString).range(of: "target")
            host.editor.setSelectedRange(target.location == NSNotFound ? NSRange(location: 0, length: 0) : target)
            model.refreshVisualContext()
            for command in commands { XCTAssertTrue(model.canFormat(command), "\(command): \(source)") }
            if target.location != NSNotFound {
                model.format(.highlight)
                XCTAssertTrue(model.source.contains("==target=="), "Disabled rendering features must not block inserting their markup")
            }
        }
        let model = RecordLayoutModel(initialSource: "one\ntwo\n", usesProcessArguments: false)
        let host = RecordNativeEditorHost(model: model)
        defer { host.detach() }
        host.editor.setSelectedRange(NSRange(location: 0, length: 7))
        model.format(.bold)
        XCTAssertEqual(model.source, "**one\ntwo**\n")
        host.undoSource(nil); XCTAssertEqual(model.source, "one\ntwo\n")
    }
    func testImageInsertionInsideCodeWorksAndStaleInsertionCannotOverwriteNewText() throws {
        let source = "```{r}\ntarget\n```\n"
        let model = RecordLayoutModel(initialSource: source, usesProcessArguments: false)
        let host = RecordNativeEditorHost(model: model)
        defer { host.detach() }
        let target = (source as NSString).range(of: "target")
        host.editor.setSelectedRange(target)
        let anchor = try XCTUnwrap(model.captureVisualInsertion(for: .imageReference))
        XCTAssertTrue(model.insertVisualLinkedImage(url: "https://example.invalid/image.png", description: "图", anchor: anchor))
        XCTAssertTrue(model.source.contains("![图](<https://example.invalid/image.png>)"))
        let edited = model.source
        XCTAssertFalse(model.insertVisualLinkedImage(url: "https://example.invalid/other.png", description: "", anchor: anchor))
        XCTAssertEqual(model.source, edited)
    }
    func testUndoRedoAcrossModesUpdatesSourceDirtyStateAndKeepsRStopped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorHistory-" + UUID().uuidString)
        let doc = QMDDocument(recoveryStore: .init(directory: root))
        let source = "# 正文\n\n原始文本。\n\n```{r}\n42\n```\n"
        try doc.read(from: Data(source.utf8), ofType: "org.quarto.qmd")
        let host = RecordNativeEditorHost(model: doc.model)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600); host.layoutSubtreeIfNeeded()
        defer { host.detach(); doc.close(); try? FileManager.default.removeItem(at: root) }
        for code in [true, false] {
            doc.model.sourceOnly = code; host.update()
            host.editor.setSelectedRange(NSRange(location: host.editor.string.utf16.count, length: 0))
            host.editor.insertText("\n新增中文🙂\n", replacementRange: host.editor.selectedRange())
            host.publishCommittedText()
            let edited = doc.model.source
            XCTAssertNotEqual(edited, source); XCTAssertTrue(doc.isDocumentEdited)
            XCTAssertTrue(host.editor.canUndoSource)
            doc.model.sourceOnly.toggle(); host.update()
            host.undoSource(nil)
            XCTAssertEqual(doc.model.source, source)
            XCTAssertFalse(doc.isDocumentEdited)
            XCTAssertTrue(host.editor.canRedoSource)
            host.redoSource(nil); XCTAssertEqual(doc.model.source, edited)
            host.undoSource(nil); XCTAssertEqual(doc.model.source, source)
        }
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertTrue(doc.model.outputStates.isEmpty)
    }
    func testVisualFormattingAndImageReferencesParticipateInSourceUndo() throws {
        let model = RecordLayoutModel(initialSource: "段落正文\n", usesProcessArguments: false)
        let host = RecordNativeEditorHost(model: model)
        defer { host.detach() }
        host.editor.setSelectedRange(NSRange(location: 0, length: 2))
        model.format(.bold); host.publishCommittedText()
        XCTAssertTrue(model.source.contains("**段落**"))
        host.undoSource(nil); XCTAssertEqual(model.source, "段落正文\n")
        for value in ["images/图 1.png", "../external.png", "file:///tmp/image.png", "https://example.invalid/a.png"] {
            XCTAssertNotNil(RecordLayoutModel.visualImageURL(value))
        }
        for value in ["", "javascript:alert(1)", "data:image/png,abc", "x\ny"] {
            XCTAssertNil(RecordLayoutModel.visualImageURL(value))
        }
    }
    func testPrivatePackageLibraryIsFirstAndExistingLibrariesRemainReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryAcceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("独立包目录")
        let runtime = RRuntime()
        let executable = try XCTUnwrap(NotebookRExecutable.locate(selected: nil))
        let worker = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap"))
        let handshake = try await runtime.start(.init(executable: executable, workerScript: worker, projectDirectory: root, packageLibrary: library))
        addTeardownBlock { try await runtime.stop() }
        let first = try XCTUnwrap(handshake.libraryPaths?.first)
        XCTAssertEqual(URL(fileURLWithPath: first).resolvingSymlinksInPath(), library.resolvingSymlinksInPath())
        let result = try await runtime.inspect(.init(operation: .snapshot))
        let snapshot = try XCTUnwrap(result.events.first { $0.kind == "inspector_result" }?.payload.inspector)
        XCTAssertEqual(URL(fileURLWithPath: snapshot.installLibrary).resolvingSymlinksInPath(), library.resolvingSymlinksInPath())
        XCTAssertTrue(snapshot.packages.contains { $0.name == "evaluate" })
        XCTAssertTrue(snapshot.packages.contains { $0.name == "stats" })
        XCTAssertEqual(snapshot.libraryPaths?.first, first)
        try await runtime.stop()
    }
}
