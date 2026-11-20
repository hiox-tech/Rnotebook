import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class ToolbarWorkflowTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ToolbarTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(_ source: String) throws -> (RecordLayoutModel, RecordNativeEditorHost, URL) {
        let root = try folder(), suite = "ToolbarTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = RuntimeConfiguration(executable: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)),
            workerScript: try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap")),
            projectDirectory: root, startupTimeout: 10, taskTimeout: 15)
        let model = RecordLayoutModel(visualDefaults: defaults, notebookConfiguration: { config }, initialSource: source, usesProcessArguments: false)
        model.sourceOnly = true
        let host = RecordNativeEditorHost(model: model)
        addTeardownBlock { @MainActor in host.detach(); await model.notebook.shutdown(); defaults.removePersistentDomain(forName: suite) }
        return (model, host, root)
    }
    private func evaluate(_ runtime: RRuntime, _ code: String) async throws -> String {
        let result = try await runtime.evaluate(.init(cellID: "toolbar-check", source: code))
        XCTAssertEqual(result.events.last?.payload.status, "completed", result.events.compactMap(\.payload.text).joined())
        return result.events.compactMap(\.payload.text).joined()
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(240)) }
    private func sheetButton(_ title: String, in window: NSWindow) throws -> NSButton {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let content = try XCTUnwrap(window.attachedSheet?.contentView)
        return try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    func testRelativeRunsExcludeCurrentAndKeepDocumentOrderAcrossNonRBlocks() async throws {
        let source = "中文正文\n\n```{r}\n#| label: above\norder_seen <- c('above')\n```\n\n```{python}\nraise Exception('must not run')\n```\n\n```{r}\n#| label: current\norder_seen <- c(order_seen, 'current')\n```\n\n普通段落\n\n```{r}\n#| label: below\norder_seen <- c(order_seen, 'below')\n```\n"
        let (model, host, _) = try model(source)
        let current = try XCTUnwrap(model.visualBlocks.blocks(in: source).first { $0.id == "current" })
        host.editor.setSelectedRange(.init(location: current.contentRange.location + 1, length: 0))
        model.runNotebookCellsAbove(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.completedCount, 1)
        XCTAssertEqual(Set(model.outputStates.keys), ["above"])
        model.runCurrentNotebookCell(); await model.notebook.waitUntilIdle()
        model.runNotebookCellsBelow(); await model.notebook.waitUntilIdle()
        let output = try await evaluate(model.notebook.runtime, "stopifnot(identical(order_seen,c('above','current','below')));cat('ORDER_OK')")
        XCTAssertTrue(output.contains("ORDER_OK"))
        XCTAssertEqual(model.source, source)
        host.editor.setSelectedRange(.init(location: 0, length: 0))
        model.runNotebookCellsAbove()
        XCTAssertFalse(model.notebook.isBusy); XCTAssertTrue(model.notice?.contains("以上没有") == true)
        host.editor.setSelectedRange(.init(location: source.utf16.count, length: 0))
        model.runNotebookCellsBelow()
        XCTAssertFalse(model.notebook.isBusy); XCTAssertTrue(model.notice?.contains("以下没有") == true)
    }

    func testRelativeRunFromProseStopsAtFailureAndNeverRunsBelowCursor() async throws {
        let source = "```{r}\n#| label: fail\nstop('expected')\n```\n\n```{r}\n#| label: skipped\nwrong <- 1\n```\n\n正文边界\n\n```{r}\n#| label: last\nlast <- 1\n```\n"
        let (model, host, _) = try model(source)
        host.editor.setSelectedRange(.init(location: (source as NSString).range(of: "正文边界").location, length: 0))
        model.runNotebookCellsAbove(); await model.notebook.waitUntilIdle()
        XCTAssertTrue(model.outputStates["fail"]?.failed == true)
        XCTAssertNil(model.outputStates["skipped"]); XCTAssertNil(model.outputStates["last"])
        model.runNotebookCellsBelow(); await model.notebook.waitUntilIdle()
        XCTAssertTrue(model.outputStates["last"]?.failed == false)
        XCTAssertNil(model.outputStates["skipped"])
    }

    func testNativeToolbarOrderUndoRedoAndSaveTargetTheirOwnDocument() async throws {
        let root = try folder(), url = root.appendingPathComponent("工具栏.qmd")
        let source = "原始正文\n"
        try Data(source.utf8).write(to: url)
        let doc = QMDDocument(); try doc.read(from: url, ofType: "org.quarto.qmd"); doc.fileURL = url
        doc.makeWindowControllers()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        window.makeKeyAndOrderFront(nil); try await settle()
        let toolbar = try XCTUnwrap(window.toolbar), items = toolbar.items
        XCTAssertEqual(items.filter { $0.itemIdentifier != .flexibleSpace }.map { $0.itemIdentifier.rawValue },
            ["find", "mode", "history", "run", "render", NSToolbarItem.Identifier.inspectorTrackingSeparator.rawValue, "r-session", "save-r"])
        let rGroup = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "r-session" } as? NSToolbarItemGroup)
        XCTAssertNil(rGroup.view, "AppKit provides the toolbar group's default control")
        XCTAssertTrue(rGroup.isBordered, "The native group supplies its own internal separator and spacing")
        XCTAssertEqual(rGroup.subitems.map(\.label), ["启动 R", "重启 R"])
        XCTAssertFalse(window.titlebarAppearsTransparent)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertEqual(split.splitViewItems[1].behavior, .inspector)
        let material = try XCTUnwrap(split.splitViewItems[1].viewController.view as? NSVisualEffectView)
        XCTAssertEqual(material.material, .sidebar)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 0)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.representedURL, url)
        let run = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "run" } as? NSMenuToolbarItem)
        XCTAssertTrue(run.showsIndicator)
        XCTAssertTrue(run.isBordered)
        XCTAssertEqual(run.menu.items.map(\.title), ["运行当前块", "运行选中代码", "运行以上", "运行以下"])
        XCTAssertFalse(try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "save-r" }).isEnabled)
        let group = try XCTUnwrap(items.first { $0.itemIdentifier.rawValue == "history" } as? NSToolbarItemGroup)
        XCTAssertTrue(group.isBordered)
        let undo = try XCTUnwrap(group.subitems.first), redo = try XCTUnwrap(group.subitems.last)
        let editor = try XCTUnwrap(doc.model.activeEditor)
        editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0)); editor.insertText("新增", replacementRange: editor.selectedRange())
        try await settle()
        XCTAssertTrue(undo.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(undo.action), to: undo.target, from: undo))
        try await settle(); XCTAssertEqual(doc.model.source, source)
        XCTAssertTrue(redo.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(redo.action), to: redo.target, from: redo))
        try await settle(); XCTAssertEqual(doc.model.source, source + "新增")
        XCTAssertTrue(NSApp.sendAction(#selector(NSDocument.save(_:)), to: doc, from: nil))
        try await settle()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source + "新增")
        XCTAssertFalse(doc.isDocumentEdited)
    }

    func testWorkspaceSaveRoundTripIncludesHiddenObjectsFunctionsAndKeepsSessionAndQMD() async throws {
        let source = "```{r}\n#| label: data\nx <- data.frame(a=1:3)\n.hidden <- '中文'\nhelper <- function(a) a + 7\nrun_count <- 1L\n```\n"
        let (model, _, root) = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let session = try XCTUnwrap(model.notebook.sessionID), task = model.outputStates["data"]?.taskID
        let url = root.appendingPathComponent("工作区 ' 引号.RData")
        model.notebook.saveWorkspace(to: try .init(url, overwrite: false), expectedSession: session)
        await model.notebook.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), model.notebook.inspectorMessage ?? "")
        XCTAssertEqual(model.notebook.sessionID, session); XCTAssertEqual(model.notebook.state, .ready)
        XCTAssertEqual(model.source, source); XCTAssertEqual(model.outputStates["data"]?.taskID, task)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = String(data: try encoder.encode(url.path), encoding: .utf8)!
        let output = try await evaluate(model.notebook.runtime,
            "local({ e <- new.env(); names <- load(\(encoded), envir=e); stopifnot(identical(sort(names),sort(c('x','.hidden','helper','run_count'))), e$.hidden=='中文',e$helper(2)==9,identical(e$x$a,1:3),run_count==1L);cat('RDATA_OK') })")
        XCTAssertTrue(output.contains("RDATA_OK"))
    }

    func testGroupedStartStopAndRestartControlsReflectReusableSession() async throws {
        let root = try folder(), url = root.appendingPathComponent("R会话按钮.qmd")
        let source = "```{r}\nstop('must not execute when starting R')\n```\n"
        try Data(source.utf8).write(to: url)
        let doc = QMDDocument(); try doc.read(from: url, ofType: "org.quarto.qmd"); doc.fileURL = url
        doc.makeWindowControllers(); doc.showWindows()
        let model = doc.model
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        let split = try XCTUnwrap(window.contentViewController as? NotebookSplitController)
        try await settle(); split.refreshToolbar()
        let group = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "r-session" } as? NSToolbarItemGroup)
        let power = try XCTUnwrap(group.subitems.first), restart = try XCTUnwrap(group.subitems.last)
        let save = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "save-r" })
        XCTAssertNil(group.view); XCTAssertNil(power.view); XCTAssertNil(restart.view)
        XCTAssertEqual(power.toolTip, "启动 R"); XCTAssertEqual(restart.toolTip, "重启 R")
        XCTAssertTrue(power.isEnabled); XCTAssertFalse(restart.isEnabled); XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(power.action), to: power.target, from: power))
        await model.notebook.waitUntilIdle(); split.refreshToolbar()
        XCTAssertEqual(model.notebook.state, .ready); XCTAssertTrue(model.outputStates.isEmpty)
        XCTAssertEqual(power.label, "停止 R")
        XCTAssertEqual(power.toolTip, "停止 R")
        XCTAssertTrue(restart.isEnabled); XCTAssertTrue(save.isEnabled)
        let session = model.notebook.sessionID
        _ = try await evaluate(model.notebook.runtime, "confirmation_value <- 123L")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(power.action), to: power.target, from: power))
        try await settle()
        let review = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(model.notebook.state, .ready)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(power.action), to: power.target, from: power))
        XCTAssertTrue(window.attachedSheet === review)
        try sheetButton("取消", in: window).performClick(nil); try await settle()
        XCTAssertEqual(model.notebook.state, .ready); XCTAssertEqual(model.notebook.sessionID, session)
        let retained = try await evaluate(model.notebook.runtime, "stopifnot(confirmation_value==123L);cat('CANCEL_KEEP_OK')")
        XCTAssertTrue(retained.contains("CANCEL_KEEP_OK"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(power.action), to: power.target, from: power))
        try await settle(); try sheetButton("停止", in: window).performClick(nil); try await settle()
        await model.notebook.waitUntilIdle(); split.refreshToolbar()
        XCTAssertEqual(power.label, "启动 R")
        XCTAssertEqual(power.toolTip, "启动 R")
        XCTAssertTrue(power.isEnabled); XCTAssertFalse(restart.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(power.action), to: power.target, from: power))
        await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .ready); XCTAssertEqual(model.source, source)
    }

    func testStopConfirmationWhileRunningCanCancelThenEndOnlyCurrentSession() async throws {
        let root = try folder(), url = root.appendingPathComponent("运行中确认.qmd")
        let source = "```{r}\n#| label: slow\nSys.sleep(20)\n```\n\n```{r}\n#| label: skipped\nwrong <- TRUE\n```\n"
        try Data(source.utf8).write(to: url)
        let doc = QMDDocument(); try doc.read(from: url, ofType: "org.quarto.qmd"); doc.fileURL = url
        doc.makeWindowControllers(); doc.showWindows()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let window = try XCTUnwrap(doc.windowControllers.first?.window), model = doc.model
        model.runAllNotebookCells()
        let deadline = Date(timeIntervalSinceNow: 8)
        while Date() < deadline {
            if case .busy = model.notebook.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.notebook.isBusy); XCTAssertTrue(model.notebook.canStop)
        let session = model.notebook.sessionID
        model.toggleRSession(); try await settle()
        try sheetButton("取消", in: window).performClick(nil); try await settle()
        XCTAssertTrue(model.notebook.isBusy); XCTAssertEqual(model.notebook.sessionID, session)
        XCTAssertTrue(model.notebook.outputState("slow")?.running == true)
        model.toggleRSession(); try await settle()
        try sheetButton("停止", in: window).performClick(nil); try await settle()
        await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .notStarted)
        XCTAssertTrue(model.outputStates["slow"]?.stopped == true)
        XCTAssertNil(model.outputStates["skipped"]); XCTAssertEqual(model.source, source)
    }

    func testWorkspaceSaveRejectsChangedTargetAndStaleSessionWithoutLosingExistingFile() async throws {
        let (model, _, root) = try model("```{r}\nx <- 42L\n```\n")
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let session = try XCTUnwrap(model.notebook.sessionID), url = root.appendingPathComponent("existing.RData")
        try Data("previous".utf8).write(to: url)
        let destination = try NotebookWorkspaceDestination(url, overwrite: true)
        try Data("external edit".utf8).write(to: url)
        model.notebook.saveWorkspace(to: destination, expectedSession: session); await model.notebook.waitUntilIdle()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external edit")
        XCTAssertTrue(model.notebook.inspectorMessage?.contains("外部修改") == true)
        let rejected = root.appendingPathComponent("stale.RData")
        model.notebook.saveWorkspace(to: try .init(rejected, overwrite: false), expectedSession: UUID())
        XCTAssertFalse(model.notebook.isBusy); XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertThrowsError(try NotebookWorkspaceDestination(root.appendingPathComponent("document.qmd"), overwrite: true))
        let missingParent = root.appendingPathComponent("missing/workspace.RData")
        model.notebook.saveWorkspace(to: try .init(missingParent, overwrite: false), expectedSession: session)
        await model.notebook.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path)); XCTAssertEqual(model.notebook.state, .ready)
        let output = try await evaluate(model.notebook.runtime, "cat(x)")
        XCTAssertTrue(output.contains("42"))
    }
}
