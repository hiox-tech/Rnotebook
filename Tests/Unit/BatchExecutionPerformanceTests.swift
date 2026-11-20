import AppKit
import SwiftUI
import EdmundCore
import XCTest
@testable import Rnotebook

@MainActor final class BatchExecutionPerformanceTests: XCTestCase {
    private static let evidenceRoot: URL = {
        if let path = ProcessInfo.processInfo.environment["RNOTEBOOK_BATCH_EVIDENCE"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".local/validation/batch-execution-diagnostics/run-" + UUID().uuidString)
    }()
    private func isolatedModel(_ source: String) throws -> RecordLayoutModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchExecution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try XCTUnwrap(NotebookRExecutable.locate(selected: nil))
        let worker = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap"))
        let config = RuntimeConfiguration(executable: executable, workerScript: worker, projectDirectory: root)
        let suite = "BatchExecution." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = RecordLayoutModel(visualDefaults: defaults, notebookConfiguration: { config }, initialSource: source, usesProcessArguments: false)
        addTeardownBlock { @MainActor in
            await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return model
    }
    func testRunAllPublishesThisRoundOnlyOnceAfterCompletionAndManualCellStreams() async throws {
        let source = "```{r first}\ncat('new-first\\n')\n```\n"
            + "```{r last}\ncat('new-last\\n'); Sys.sleep(0.4)\n```\n"
        let model = try isolatedModel(source)
        let job = try XCTUnwrap(model.notebookJobs(all: true).first)
        var old = RecordOutputLayout.State(hash: job.blockHash, events: [.text("previous-round")])
        old.isSample = false; model.outputStates["first"] = old
        let revision = model.outputRevision
        model.runAllNotebookCells()
        for _ in 0..<300 {
            if model.notebook.completedCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.notebook.isBusy)
        XCTAssertEqual(model.outputRevision, revision)
        XCTAssertTrue(model.outputStates["first"]?.events.contains { if case .text(let value) = $0 { return value == "previous-round" }; return false } == true)
        XCTAssertNil(model.outputStates["last"])
        await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.outputRevision, revision + 1, "One display commit for the whole round")
        XCTAssertEqual(model.notebook.completedCount, 2)
        XCTAssertTrue(model.outputStates["first"]?.events.contains { if case .text(let value) = $0 { return value.contains("new-first") }; return false } == true)
        XCTAssertFalse(model.outputStates["last"]?.events.isEmpty ?? true)
        let beforeManual = model.outputRevision
        model.runNotebookBlock("last")
        for _ in 0..<100 {
            if model.outputStates["last"]?.running == true && model.outputRevision > beforeManual { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.notebook.isBusy)
        XCTAssertTrue(model.outputStates["last"]?.running == true)
        XCTAssertGreaterThan(model.outputRevision, beforeManual)
        await model.notebook.waitUntilIdle()
    }
    func testProgressCountsSkippedAndFailedCellsAndResetsAfterCompletion() async throws {
        let source = "```{r skipped, eval=FALSE}\nstop('never')\n```\n"
            + "```{r first}\ncat('first\\n'); Sys.sleep(0.2)\n```\n"
            + "```{r failure, error=TRUE}\nstop('expected')\n```\n"
            + "```{r last}\nSys.sleep(0.2); cat('last\\n')\n```\n"
        let model = try isolatedModel(source)
        model.runAllNotebookCells()
        XCTAssertEqual(model.notebook.executionProgress, 0)
        var progress: [Double] = []
        while model.notebook.isBusy {
            if let value = model.notebook.executionProgress { progress.append(value) }
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.notebook.waitUntilIdle()
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertTrue(progress.contains(0.25)); XCTAssertTrue(progress.contains(0.75))
        XCTAssertEqual(model.notebook.completedCount, 2); XCTAssertEqual(model.notebook.failedCount, 1)
        XCTAssertEqual(model.notebook.skippedCount, 1); XCTAssertEqual(model.notebook.pendingCount, 0)
        XCTAssertNil(model.notebook.executionProgress)
        XCTAssertEqual(model.outputStates.count, 4)
        XCTAssertNotNil(model.notebook.inspectorSnapshot)
        let root = Self.evidenceRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: HStack(spacing: 24) {
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    VStack(spacing: 5) {
                        NotebookRunProgress(progress: fraction)
                        Text("\(Int(fraction * 100))%").font(.system(size: 10))
                    }
                }
            }.padding(12).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            view.frame = NSRect(x: 0, y: 0, width: 250, height: 60)
            view.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("progress-\(appearance.rawValue).png"))
            window.close()
        }
    }
    func testByteDistinctEditDuringBatchStopsRemainingCellsAndKeepsCompletedOutput() async throws {
        let source = "# caf\u{e9}\n```{r first}\ncat('running\\n'); Sys.sleep(0.3)\n```\n"
            + "```{r second}\nshould_not_run <- TRUE\n```\n"
        let model = try isolatedModel(source)
        model.runAllNotebookCells()
        for _ in 0..<300 {
            if model.notebook.outputState("first")?.events.contains(where: { if case .text(let text) = $0 { return text.contains("running") }; return false }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let edited = source.replacingOccurrences(of: "\u{e9}", with: "e\u{301}")
        model.source = edited
        await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 1); XCTAssertEqual(model.notebook.pendingCount, 1)
        XCTAssertNil(model.outputStates["second"])
        XCTAssertFalse(model.outputStates["first"]?.events.isEmpty ?? true)
        XCTAssertEqual(Data(model.source.utf8), Data(edited.utf8))
        XCTAssertNil(model.notebook.executionProgress)
        let check = try await model.notebook.runtime.evaluate(.init(cellID: "check", source: "stopifnot(!exists('should_not_run'))"))
        XCTAssertEqual(check.events.last?.payload.status, "completed")
    }
    func testLongRunRetainsOutputsAndSwitchesWithNativeResults() async throws {
        try await checkLongDocument(runR: true)
    }
    func testNativeResultNavigationWithoutRuntime() async throws {
        try await checkLongDocument(runR: false)
    }
    private func regressionWindow() throws -> (QMDDocument, NSWindow, RecordNativeEditorHost, String) {
        let source = "# Long notebook\n\n" + (0..<700).map {
            "## Section \($0)\n\n" + String(repeating: "Long paragraph with Unicode 中文. ", count: 8)
                + "\n\n```{r}\n#| label: block-\($0)\nx_\($0) <- seq_len(100)\nmean(x_\($0))\n```\n\n"
        }.joined()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ViewportFeedback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("700.qmd"); try Data(source.utf8).write(to: url)
        let suite = "ViewportFeedback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let doc = QMDDocument()
        doc.sourceSettings = SourceEditorSettings(defaults: defaults); doc.sourceSettings.completionEnabled = false
        doc.visual = VisualEditorSettings(defaults: defaults); doc.appearance = AppearanceSettings(defaults: defaults)
        doc.fileURL = url; try doc.read(from: Data(source.utf8), ofType: NotebookDocumentType.quarto)
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        window.setContentSize(NSSize(width: 1100, height: 760)); window.makeKeyAndOrderFront(nil)
        let host = try XCTUnwrap(doc.model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        addTeardownBlock { @MainActor in
            await doc.model.notebook.shutdown(); doc.updateChangeCount(.changeCleared); doc.close()
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        return (doc, window, host, source)
    }
    func testOpeningAtTopThenCodeCanScrollImmediatelyAndLaterWithoutOutputs() async throws {
        let (doc, window, host, source) = try regressionWindow()
        try await Task.sleep(for: .milliseconds(700))
        let scroll = try XCTUnwrap(host.editor.enclosingScrollView)
        XCTAssertTrue(doc.model.outputStates.isEmpty)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, -scroll.contentInsets.top + 1)
        let start = ProcessInfo.processInfo.systemUptime
        doc.model.sourceOnly = true; host.update(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let load = ProcessInfo.processInfo.systemUptime - start
        print("TOP CODE", load, "extent", host.editor.frame.height, "viewport", scroll.contentSize.height)
        #if !DEBUG
        XCTAssertLessThan(load, 1, "Opening Code at the document top must paint within one second")
        #endif
        let first = host.editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertGreaterThan(first.height, 0)
        XCTAssertLessThanOrEqual(first.maxY, window.convertToScreen(window.contentLayoutRect).maxY + 1)
        for step in 0..<8 {
            let before = scroll.contentView.bounds.minY
            let startOffset = host.editor.textLayoutManager?.textViewportLayoutController.viewportRange.map { vp in host.editor.textLayoutManager!.offset(from: host.editor.textLayoutManager!.documentRange.location, to: vp.location) } ?? -1
            host.editor.scrollPageDown(nil)
            window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(step == 0 ? 100 : 450))
            let endOffset = host.editor.textLayoutManager?.textViewportLayoutController.viewportRange.map { vp in host.editor.textLayoutManager!.offset(from: host.editor.textLayoutManager!.documentRange.location, to: vp.location) } ?? -1
            print("CODE PAGE", step, before, scroll.contentView.bounds.minY, "offset", startOffset, endOffset)
            XCTAssertGreaterThan(endOffset, startOffset, "Code source viewport must advance")
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, before + 100, "Code must keep accepting page scrolls after opening at top, step \(step)")
        }
        for _ in 0..<8 { host.editor.scrollPageUp(nil); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        let wheelStart = scroll.contentView.bounds.minY
        for _ in 0..<8 {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0))
            host.editor.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
            window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, wheelStart + 400, "Native wheel scrolling must also advance from the top")
        XCTAssertGreaterThan(host.editor.frame.height, scroll.contentSize.height * 20)
        XCTAssertEqual(Data(host.editor.string.utf8), Data(source.utf8))
    }
    func testSingleCellResultsKeepReadingLineAndOutlineDuringAndAfterExecution() async throws {
        let (doc, window, host, source) = try regressionWindow()
        doc.model.notebook.start(); await doc.model.notebook.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(700))
        for index in [7, 128, 7, 688] {
            let range = (source as NSString).range(of: "mean(x_\(index))")
            host.navigateSource(NSRange(location: range.location, length: 0))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let baseline = host.editor.firstRect(forCharacterRange: range, actualRange: nil)
            XCTAssertGreaterThan(baseline.height, 0)
            doc.model.runNotebookBlock("block-\(index)")
            var idleSamples = 0
            for step in 0..<160 {
                host.update(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let rect = host.editor.firstRect(forCharacterRange: range, actualRange: nil)
                XCTAssertGreaterThan(rect.height, 0, "Block \(index), sample \(step)")
                XCTAssertEqual(rect.minY, baseline.minY, accuracy: 2, "Single-cell output must not move the reading line: block \(index), sample \(step)")
                if let manager = host.editor.textLayoutManager, let vp = manager.textViewportLayoutController.viewportRange {
                    let scroll = host.editor.enclosingScrollView!
                    let band = max(0, scroll.contentSize.height - scroll.contentInsets.top - scroll.contentInsets.bottom) / 3
                    let top = host.editor.visibleRect.minY + scroll.contentInsets.top + band - host.editor.textContainerOrigin.y
                    var offset: Int?
                    manager.enumerateTextLayoutFragments(from: vp.location, options: []) { fragment in
                        guard fragment.state == .layoutAvailable else { return true }
                        guard fragment.layoutFragmentFrame.minY <= top else { return false }
                        offset = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location); return true
                    }
                    if let offset {
                        let expected = host.folding.structure.headings.lastIndex { $0.range.location <= offset } ?? 0
                        let tree = host.outline.tree
                        XCTAssertEqual((tree.item(atRow: tree.selectedRow) as? OutlineNode)?.index, expected,
                                       "Outline must track the final laid-out reading band")
                        XCTAssertTrue(NSLocationInRange(tree.selectedRow, tree.rows(in: tree.visibleRect)),
                                      "The current outline heading must also be visible, including middle/end blocks")
                    }
                }
                idleSamples = doc.model.notebook.isBusy ? 0 : idleSamples + 1
                if idleSamples >= 18 { break }
            }
            await doc.model.notebook.waitUntilIdle()
            XCTAssertFalse(doc.model.outputStates["block-\(index)"]?.events.isEmpty ?? true)
        }
    }
    private func checkLongDocument(runR: Bool) async throws {
        let count = 700
        let root = Self.evidenceRoot
        print("BATCH_EVIDENCE", root.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = "# Batch execution\n\n" + (0..<count).map {
            "## Section \($0)\n\n" + String(repeating: "Long paragraph with Unicode 中文. ", count: 8)
            + "\n\n```{r}\n#| label: block-\($0)\nx_\($0) <- seq_len(100)\ncat('block-\($0)\\n')\nmean(x_\($0))\n```\n\n"
        }.joined()
        let file = root.appendingPathComponent("long-\(count).qmd")
        try Data(source.utf8).write(to: file)
        let suite = "BatchPerformance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let document = QMDDocument()
        document.sourceSettings = SourceEditorSettings(defaults: defaults)
        document.sourceSettings.completionEnabled = false
        document.visual = VisualEditorSettings(defaults: defaults)
        document.appearance = AppearanceSettings(defaults: defaults)
        document.fileURL = file
        try document.read(from: Data(source.utf8), ofType: NotebookDocumentType.quarto)
        document.makeWindowControllers()
        let model = document.model
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.setContentSize(NSSize(width: 1100, height: 760)); window.makeKeyAndOrderFront(nil)
        let host = try XCTUnwrap(model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        addTeardownBlock { @MainActor in
            await model.notebook.shutdown(); document.updateChangeCount(.changeCleared); document.close()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(500))
        var applies: [Double] = []
        host.outputs.onApplyTiming = { applies.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        if runR {
            model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        } else {
            for job in model.notebookJobs(all: true) {
                var state = RecordOutputLayout.State(hash: job.blockHash, events: [.text("\(job.blockID): [1] 50.5\n")])
                state.isSample = false
                model.outputStates[job.blockID] = state
            }
            model.outputRevision &+= 1
        }
        host.update(); window.displayIfNeeded()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if runR { XCTAssertEqual(model.notebook.completedCount, count, model.notebook.diagnostic ?? "") }
        XCTAssertEqual(model.notebook.failedCount, 0)
        XCTAssertEqual(model.outputStates.count, count, "Every block must retain its current-session output")
        for index in 0..<count {
            let output = model.outputStates["block-\(index)"]
            XCTAssertTrue(output?.events.contains { if case .text(let text) = $0 { return text.contains("50.5") }; return false } == true, "Missing output \(index)")
            XCTAssertTrue(output?.events.contains { if case .text(let text) = $0 { return text.contains("block-\(index)") }; return false } == true, "Output must belong to its own block \(index)")
        }
        XCTAssertLessThan(elapsed, 60, "700-block Run All target includes R startup, final inspector and visible results")
        let presentationDeadline = Date(timeIntervalSinceNow: 8)
        while host.editor.hasDeferredPresentation, Date() < presentationDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        window.makeFirstResponder(host.editor)
        let location = (source as NSString).range(of: "mean(x_300)").location
        host.navigateSource(NSRange(location: location, length: 0))
        let scroll = try XCTUnwrap(host.editor.enclosingScrollView)
        try await Task.sleep(for: .milliseconds(200))
        var stable = 0
        for _ in 0..<20 {
            let caret = host.editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
            let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            let target = viewport.maxY - scroll.contentInsets.top - 180
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - (caret.minY - target)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(50))
            let settled = host.editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
            stable = settled.height > 0 && abs(settled.minY - target) < 0.5 ? stable + 1 : 0
            if stable >= 3 { break }
        }
        let baseline = host.editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        XCTAssertGreaterThan(baseline.height, 0, "The measured source character must be visible before switching")
        var switches: [[String: Any]] = []
        var stages: [[String: Any]] = []
        host.onUpdateTiming = { stage, seconds in stages.append(["stage": stage, "seconds": seconds, "code": model.sourceOnly]) }
        for round in 0..<3 {
            for code in [true, false] {
                let t = ProcessInfo.processInfo.systemUptime
                model.sourceOnly = code; host.update(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let duration = ProcessInfo.processInfo.systemUptime - t
                #if DEBUG
                XCTAssertLessThan(duration, 3, "Debug instrumentation has a separate budget; shipping Release is checked below one second")
                #else
                XCTAssertLessThan(duration, 1, "Shipping results must switch in under one second")
                #endif
                XCTAssertEqual(Data(host.editor.string.utf8), Data(source.utf8))
                try await Task.sleep(for: .milliseconds(250))
                let caret = host.editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
                switches.append(["round": round, "code": code, "seconds": duration, "caretY": caret.minY,
                                 "height": caret.height, "baselineY": baseline.minY])
                XCTAssertGreaterThan(caret.height, 0)
                XCTAssertEqual(caret.minY, baseline.minY, accuracy: 2, "Results must not accumulate reading-position drift")
                XCTAssertEqual(host.editor.selectedRange(), NSRange(location: location, length: 0))
                if !code {
                    let shelf = try XCTUnwrap(host.outputs.shelves["block-300"])
                    XCTAssertFalse(shelf.isHidden)
                    XCTAssertGreaterThan(shelf.frame.height, 34)
                    func renderedText(_ view: NSView) -> String {
                        ((view as? NSTextView)?.string ?? "") + view.subviews.map(renderedText).joined()
                    }
                    for index in [0, 300, 699] {
                        XCTAssertTrue(renderedText(try XCTUnwrap(host.outputs.shelves["block-\(index)"])).contains("block-\(index)"))
                        XCTAssertTrue(renderedText(try XCTUnwrap(host.outputs.shelves["block-\(index)"])).contains("50.5"),
                                      "Native result body must render first, middle and last outputs")
                    }
                }
            }
        }
        var navigation: [[String: Any]] = []
        for index in [0, 300, 699] {
            let offset = (source as NSString).range(of: "mean(x_\(index))").location
            host.navigateSource(NSRange(location: offset, length: 0))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            window.displayIfNeeded()
            // A background/occluded XCTest window can defer its glyph-layer
            // paint. Force the native host paint before judging display state.
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let shelf = try XCTUnwrap(host.outputs.shelves["block-\(index)"])
            let manager = try XCTUnwrap(host.editor.textLayoutManager)
            var fragments: [[String: Any]] = []
            if let vp = manager.textViewportLayoutController.viewportRange {
                let end = manager.offset(from: manager.documentRange.location, to: vp.endLocation)
                manager.enumerateTextLayoutFragments(from: vp.location, options: []) { f in
                    let start = manager.offset(from: manager.documentRange.location, to: f.rangeInElement.location)
                    guard start <= end else { return false }
                    fragments.append(["offset": start, "frame": NSStringFromRect(f.layoutFragmentFrame)])
                    return true
                }
            }
            navigation.append(["id": index, "shelf": NSStringFromRect(shelf.frame), "hidden": shelf.isHidden,
                "visible": NSStringFromRect(host.editor.visibleRect), "fragments": fragments])
            XCTAssertFalse(shelf.isHidden)
            XCTAssertTrue(shelf.frame.intersects(host.editor.visibleRect), "Result \(index) must be scrollable into view")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: root.appendingPathComponent("\(runR ? "native" : "ui")-results-\(index).png"))
        }
        var scrolling: [[String: Any]] = []
        for code in [true, false] {
            model.sourceOnly = code; host.update()
            host.navigateSource(NSRange(location: location, length: 0))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let initialApplies = host.outputs.applyCount
            let initialWidth = scroll.contentSize.width
            var widths: [CGFloat] = []
            var frameTimes: [Double] = [], checked = 0, maxAlignmentError: CGFloat = 0
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            let scrollStart = scroll.contentView.bounds.minY
            for step in 0..<96 {
                let t = ProcessInfo.processInfo.systemUptime
                let dy: CGFloat = step < 48 ? 12 : -12
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + dy))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                window.displayIfNeeded()
                let mounted = host.outputs.shelves.values.filter { $0.superview === host.editor }.count
                XCTAssertLessThan(mounted, 8, "Only viewport results belong in the native display tree")
                if code { XCTAssertEqual(mounted, 0) }
                if step == 47 {
                    XCTAssertGreaterThan(scroll.contentView.bounds.minY, scrollStart + 500,
                                         "The performance sample must actually scroll, not fight a retained navigation anchor")
                }
                widths.append(scroll.contentSize.width)
                frameTimes.append(ProcessInfo.processInfo.systemUptime - t)
                if !code, let manager = host.editor.textLayoutManager,
                   let vp = manager.textViewportLayoutController.viewportRange {
                    var rects: [Int: NSRect] = [:]
                    let end = manager.offset(from: manager.documentRange.location, to: vp.endLocation)
                    manager.enumerateTextLayoutFragments(from: vp.location, options: []) { f in
                        let start = manager.offset(from: manager.documentRange.location, to: f.rangeInElement.location)
                        guard start <= end else { return false }
                        let lines = f.textLineFragments.filter { $0.characterRange.length > 0 }
                        if let first = lines.first {
                            rects[start] = NSRect(x: 0, y: f.layoutFragmentFrame.minY + first.typographicBounds.minY,
                                width: 1, height: (lines.map(\.typographicBounds.maxY).max() ?? 0) - first.typographicBounds.minY)
                        }
                        return true
                    }
                    for block in model.visualBlocks.blocks(in: source) {
                        guard let shelf = host.outputs.shelves[block.id], !shelf.isHidden,
                              shelf.frame.intersects(host.editor.visibleRect) else { continue }
                        let closing = (source as NSString).paragraphRange(for: NSRange(location: block.range.upperBound - 1, length: 0))
                        if let rect = rects[closing.location] {
                            checked += 1
                            maxAlignmentError = max(maxAlignmentError, abs(shelf.frame.minY - rect.maxY - host.editor.textContainerOrigin.y))
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(16))
            }
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            XCTAssertEqual(host.outputs.applyCount, initialApplies, "Scrolling must not reapply the whole result document; width \(initialWidth) -> \(scroll.contentSize.width)")
            if !code {
                XCTAssertGreaterThan(checked, 40, "Check native text/result alignment throughout both scroll directions")
                XCTAssertLessThanOrEqual(maxAlignmentError, 1, "Result views must follow the same layout frame as native text")
            }
            let ordered = frameTimes.sorted()
            #if !DEBUG
            XCTAssertLessThan(ordered[Int(Double(ordered.count) * 0.95)], 1.0 / 60.0,
                              "95% of native scroll/layout/paint work should fit a 60Hz frame")
            #endif
            scrolling.append(["code": code, "frames": frameTimes.count, "p95": ordered[Int(Double(ordered.count) * 0.95)],
                              "max": ordered.last ?? 0, "alignedSamples": checked, "maxAlignmentError": maxAlignmentError,
                              "resultReapplies": host.outputs.applyCount - initialApplies, "initialWidth": initialWidth, "widths": widths])
        }
        try JSONSerialization.data(withJSONObject: ["blocks": count, "seconds": elapsed,
            "retained": model.outputStates.count, "applies": applies, "switches": switches, "stages": stages, "navigation": navigation, "scrolling": scrolling], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("\(runR ? "native" : "ui")-\(count)-\(Int(Date().timeIntervalSince1970)).json"))
    }
}
