import AppKit
import EdmundCore
import UniformTypeIdentifiers
import XCTest
@testable import Rnotebook

@MainActor final class EditorFeedbackTests: XCTestCase {
    private func fixture(_ source: String, code: Bool) throws -> (RecordLayoutModel, RecordNativeEditorHost, NSWindow) {
        let suite = "EditorFeedback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = RecordLayoutModel(visualDefaults: defaults, initialSource: source, usesProcessArguments: false)
        model.sourceOnly = code
        let host = RecordNativeEditorHost(model: model, sourceSettings: .init(defaults: defaults), appearanceSettings: .init(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1080, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(host.editor); host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            host.detach(); window.close(); await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
        return (model, host, window)
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
    private var longSource: String {
        (1...60).map { "## Section \($0)\n\nParagraph \($0). needle and reading text.\n\n" }.joined()
            + "```{r}\nx<-c(1,2)\nmean(x)\n```\n\n```mermaid\nflowchart TD\n A[Start] --> B[End]\n```\n\nTail\n\n```{r}\n\n```\n"
    }
    func testBottomFoldsKeepHeaderAtSameScreenPositionAcrossNativeLayout() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let input = root.appendingPathComponent("Tests/Fixtures/QMD/valid-bottom-fold.qmd")
        let source = try String(contentsOf: input, encoding: .utf8)
        let (model, host, _) = try fixture(source, code: false)
        try await settle()
        model.sourceOnly = true; host.update()
        try await settle()
        let editor = host.editor
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let regions = Array(host.folding.structure.regions.filter { $0.kind == .fence }.suffix(2))
        for region in regions {
            for _ in 0..<2 {
                editor.textLayoutManager?.ensureLayout(for: editor.textLayoutManager!.documentRange)
                editor.sizeToFit()
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.bounds.height - scroll.contentSize.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
                try await settle()
                let before = editor.firstRect(forCharacterRange: NSRange(location: region.header.location, length: 1), actualRange: nil)
                host.foldGutter.refresh()
                let button = try XCTUnwrap(host.foldGutter.subviews.compactMap { $0 as? NSButton }.first { $0.tag == region.key && !$0.isHidden })
                button.performClick(nil)
                for _ in 0..<6 {
                    try await Task.sleep(for: .milliseconds(25))
                    let after = editor.firstRect(forCharacterRange: NSRange(location: region.header.location, length: 1), actualRange: nil)
                    XCTAssertGreaterThan(after.height, 0)
                    XCTAssertEqual(after.minY, before.minY, accuracy: 1, "Touching bottom: \(region.title)")
                }
            }
        }
        XCTAssertEqual(model.source, source); XCTAssertEqual(editor.string, source)
    }
    func testSearchNavigationCentersAndTypingDoesNotReturnToOldMatch() async throws {
        for code in [true, false] {
            let (_, host, window) = try fixture(longSource, code: code)
            let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
            try await settle()
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).range(of: "Paragraph 25.").location, length: 0))
            host.documentFinder.perform(.showFindInterface)
            let bar = host.documentFinder.bar
            bar.query.stringValue = "needle"; bar.queryChanged?("needle"); try await settle()
            for forward in [true, true, false] {
                bar.navigate?(forward); try await settle()
                let range = try XCTUnwrap(host.documentFinder.currentMatch)
                let rect = window.convertFromScreen(editor.firstRect(forCharacterRange: range, actualRange: nil))
                let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
                let center = (visible.minY + scroll.contentInsets.bottom + visible.maxY - scroll.contentInsets.top) / 2
                XCTAssertEqual(rect.midY, center, accuracy: 1, "Find should center its line in mode \(code)")
            }
            bar.query.stringValue = "Paragraph 2."; bar.queryChanged?("Paragraph 2."); try await settle()
            let target = (editor.string as NSString).range(of: "Paragraph 42.")
            editor.scrollCharacterToTop(target.location)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 180))
            editor.setSelectedRange(NSRange(location: target.upperBound, length: 0)); window.makeFirstResponder(editor)
            try await settle()
            for _ in 0..<3 {
                let before = editor.firstRect(forCharacterRange: target, actualRange: nil)
                editor.insertText("x", replacementRange: editor.selectedRange()); host.publishCommittedText(); try await settle()
                XCTAssertEqual(editor.firstRect(forCharacterRange: target, actualRange: nil).minY, before.minY, accuracy: 1, "Typing with Find open must keep reading line")
            }
        }
    }
    func testTypingInsideCodeBlockWithFindOpenKeepsReadingLine() async throws {
        let source = "# Heading\n\n```{r}\nneedle <- 1\nx <- 2\nx <- 3\n```\n\nAfter needle.\n"
        for code in [true, false] {
            let (_, host, window) = try fixture(source, code: code)
            let editor = host.editor
            try await settle()
            host.documentFinder.perform(.showFindInterface)
            let bar = host.documentFinder.bar
            bar.query.stringValue = "needle"; bar.queryChanged?("needle")
            try await settle()
            let line = (source as NSString).range(of: "x <- 3")
            editor.setSelectedRange(NSRange(location: line.upperBound, length: 0))
            window.makeFirstResponder(editor)
            editor.scrollRangeToVisible(NSRange(location: line.location, length: 1))
            try await settle()
            let before = editor.firstRect(forCharacterRange: NSRange(location: line.location, length: 1), actualRange: nil)
            for _ in 0..<3 {
                editor.insertText("x", replacementRange: editor.selectedRange())
                host.publishCommittedText()
                try await settle()
                editor.displayIfNeeded()
                let after = editor.firstRect(forCharacterRange: NSRange(location: line.location, length: 1), actualRange: nil)
                XCTAssertEqual(after.minY, before.minY, accuracy: 1,
                    "Typing in a fenced block with Find open must keep the reading line (code: \(code))")
            }
        }
    }

    func testFindHighlightDrawingUsesOnlyLaidOutFragments() async throws {
        let source = "# Heading\n\n```{r}\nneedle <- 1\nx <- 2\nx <- 3\n```\n\nAfter needle.\n"
        for code in [true, false] {
            let (_, host, _) = try fixture(source, code: code)
            let editor = host.editor
            try await settle()
            host.documentFinder.perform(.showFindInterface)
            host.documentFinder.bar.query.stringValue = "needle"
            host.documentFinder.bar.queryChanged?("needle")
            try await settle()
            XCTAssertFalse(host.documentFinder.matches.isEmpty)
            let tlm = try XCTUnwrap(editor.textLayoutManager)
            let docStart = tlm.documentRange.location
            let target = (source as NSString).range(of: "x <- 2")
            let start = try XCTUnwrap(tlm.location(docStart, offsetBy: target.location))
            let end = try XCTUnwrap(tlm.location(start, offsetBy: target.length))
            let targetRange = try XCTUnwrap(NSTextRange(location: start, end: end))
            tlm.ensureLayout(for: tlm.documentRange)
            tlm.invalidateLayout(for: targetRange)
            let fragment = try XCTUnwrap(tlm.textLayoutFragment(for: start))
            XCTAssertNotEqual(fragment.state, .layoutAvailable)
            let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: image))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            editor.drawBackground(in: editor.visibleRect)
            NSGraphicsContext.restoreGraphicsState()
            XCTAssertNotEqual(fragment.state, .layoutAvailable,
                "Find drawing must not force layout of an invalidated code block (code: \(code))")
        }
    }

    func testFindHighlightColorFollowsThemeAccent() throws {
        let suite = "EditorFeedback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordLayoutModel(visualDefaults: defaults, initialSource: "needle\n", usesProcessArguments: false)
        let appearance = AppearanceSettings(defaults: defaults)
        appearance.accent = .purple
        let host = RecordNativeEditorHost(model: model, sourceSettings: .init(defaults: defaults), appearanceSettings: appearance)
        defer { host.detach() }
        host.update()
        let expected = AppAccent.purple.color.usingColorSpace(.sRGB)
        let actual = host.editor.findHighlightColor.usingColorSpace(.sRGB)
        XCTAssertEqual(actual?.redComponent ?? -1, expected?.redComponent ?? -2, accuracy: 0.001)
        XCTAssertEqual(actual?.greenComponent ?? -1, expected?.greenComponent ?? -2, accuracy: 0.001)
        XCTAssertEqual(actual?.blueComponent ?? -1, expected?.blueComponent ?? -2, accuracy: 0.001)
    }

    func testBodyTypingRetainsOutlineNodeAndSelection() async throws {
        let (_, host, _) = try fixture(longSource, code: false)
        try await settle()
        let target = (host.editor.string as NSString).range(of: "Paragraph 25.")
        host.editor.scrollCharacterToTop(target.location); host.editor.setSelectedRange(NSRange(location: target.upperBound, length: 0)); try await settle()
        let tree = host.outline.tree, row = tree.selectedRow
        let node = try XCTUnwrap(tree.item(atRow: row) as? OutlineNode)
        for _ in 0..<4 {
            host.editor.insertText("x", replacementRange: host.editor.selectedRange()); host.publishCommittedText(); try await settle()
            XCTAssertTrue(tree.item(atRow: row) as? OutlineNode === node, "Body edits should update ranges without replacing outline nodes")
            XCTAssertEqual(tree.selectedRow, row)
        }
    }
    func testVisualInteriorBlankLineCaretMatchesBodyBeforeAndAfterTyping() async throws {
        let cases = [
            ("# Heading\n\nBody before.\n\n\nBody after.\n", "Body before."),
            ("# Heading\n\n```{r}\nx <- 1\n\nx <- 2\n```\n", "x <- 1"),
            ("# Heading\n\n```{r}\n\n```\n", "```{r}")
        ]
        for (source, marker) in cases {
            let (_, host, _) = try fixture(source, code: false)
            try await settle()
            let editor = host.editor
            let body = (source as NSString).range(of: marker)
            let blank = NSRange(location: body.upperBound + 1, length: 0)
            editor.setSelectedRange(blank); try await settle()
            let before = editor.firstRect(forCharacterRange: blank, actualRange: nil)
            editor.insertText("x", replacementRange: blank); try await settle()
            let after = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            XCTAssertEqual(before.height, after.height, accuracy: 1, marker)
            editor.deleteBackward(nil); try await settle()
            XCTAssertEqual(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil).height, after.height, accuracy: 1, marker)
        }
    }
    func testVisualBlockFormattingPreservesReadingSelectionAndUndo() async throws {
        let source = "# Heading\n\nRead here.\n\n```{r}\nx<-c(1,2)\n```\n\nAfter.\n"
        let (model, host, _) = try fixture(source, code: false)
        try await settle()
        let selection = NSRange(location: (source as NSString).range(of: "Read here").location, length: 0)
        host.editor.setSelectedRange(selection); try await settle()
        let block = try XCTUnwrap(model.visualBlocks.blocks(in: source).first)
        model.formatRBlock(block.id)
        for _ in 0..<100 { if model.source != source { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.source.contains("x <- c(1, 2)"))
        XCTAssertEqual(host.editor.selectedRange(), selection, "Block action must not activate R editing")
        host.undoSource(nil); XCTAssertEqual(model.source, source)
    }

    func testCustomAirPreferencesChangeActualFormattingAndLeaveDocumentConfigUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = Data("[format]\nline-width = 40\nindent-width = 2\npersistent-line-breaks = true\n".utf8)
        let configURL = directory.appendingPathComponent("air.toml")
        try config.write(to: configURL)
        let source = "```{r}\n#| echo: false\nf<-function(x){\nlist(\nalpha=x,\nbeta=2\n)\n}\n```\n"
        let selection = NSRange(location: (source as NSString).range(of: "f<-").location, length: 0)
        let document = directory.appendingPathComponent("sample.qmd")
        let standard = try await RAirFormatter.format(source: source, selection: selection, documentURL: document)
        var custom = RFormatPreferences(); custom.custom = true; custom.indentWidth = 4; custom.lineWidth = 120; custom.persistentBreaks = false
        let compact = try await RAirFormatter.format(source: source, selection: selection, documentURL: document, preferences: custom)
        XCTAssertTrue(standard.replacement.contains("list(\n"))
        XCTAssertTrue(compact.replacement.contains("    list(alpha = x, beta = 2)"))
        XCTAssertTrue(compact.replacement.hasPrefix("#| echo: false\n"))
        XCTAssertEqual(try Data(contentsOf: configURL), config)
        custom.lineWidth = 20
        let narrow = try await RAirFormatter.format(source: source, selection: selection, documentURL: document, preferences: custom)
        XCTAssertNotEqual(narrow.replacement, compact.replacement)
        let suite = "FormatPreferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SourceEditorSettings(defaults: defaults)
        settings.formatMode = "custom"; settings.formatLineWidth = 120; settings.formatIndentWidth = 4; settings.formatPersistentBreaks = false
        XCTAssertEqual(RFormatPreferences(defaults: defaults).lineWidth, 120)
        XCTAssertEqual(RFormatPreferences(defaults: defaults).indentWidth, 4)
        XCTAssertFalse(RFormatPreferences(defaults: defaults).persistentBreaks)
        XCTAssertTrue(RFormatPreferences(defaults: defaults).custom)
    }

    func testWorkspaceNamesHaveSingleSuffixAndSaveFormatsUseRequestedDisplayNames() {
        for path in ["报告.qmd", "报告.Rmd", "报告.qmd.qmd", "报告.Rmd.RData"] {
            XCTAssertEqual(RecordLayoutModel.workspaceSaveName(documentURL: URL(fileURLWithPath: "/tmp/" + path)), "报告.RData")
        }
        XCTAssertEqual(RecordLayoutModel.workspaceSaveName(documentURL: nil), "Workspace.RData")
        XCTAssertEqual(RecordLayoutModel.workspaceSaveName(documentURL: URL(fileURLWithPath: "/tmp/报告.v2.qmd")), "报告.v2.RData")
        let controller = QMDDocumentController()
        XCTAssertEqual(controller.displayName(forType: NotebookDocumentType.quarto), "Quarto(.qmd)")
        XCTAssertEqual(controller.displayName(forType: NotebookDocumentType.rMarkdown), "R Markdown(.Rmd)")
        XCTAssertEqual(controller.displayName(forType: NotebookDocumentType.rMarkdown.lowercased()), "R Markdown(.Rmd)")
        if #available(macOS 15.0, *) {
            let original = SavePanelDelegateProbe()
            let delegate = NotebookSavePanelTypeDelegate(original: original)
            XCTAssertEqual(delegate.panel(NSSavePanel(), displayNameFor: UTType(importedAs: NotebookDocumentType.rMarkdown)), "R Markdown(.Rmd)")
            XCTAssertEqual(delegate.panel(NSSavePanel(), displayNameFor: UTType(importedAs: NotebookDocumentType.quarto)), "Quarto(.qmd)")
            XCTAssertNil(delegate.panel(NSSavePanel(), displayNameFor: .pdf))
            let selector = #selector(NSOpenSavePanelDelegate.panel(_:shouldEnable:))
            XCTAssertTrue(delegate.responds(to: selector))
            XCTAssertTrue(delegate.forwardingTarget(for: selector) as? SavePanelDelegateProbe === original)
        }
    }
}

@MainActor private final class SavePanelDelegateProbe: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { false }
}
