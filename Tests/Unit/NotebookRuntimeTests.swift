import AppKit
import Darwin
import XCTest
@testable import Rnotebook

@MainActor final class NotebookRuntimeTests: XCTestCase {
    func testManagedSessionCacheUsesDocumentWorkingDirectoryAndSurvivesManualSweepUntilStop() async throws {
        let config = try configuration(), runtime = RRuntime()
        _ = try await runtime.start(config)
        addTeardownBlock { try? await runtime.stop() }
        let resourceDirectory = await runtime.resourceDirectory
        let resources = try XCTUnwrap(resourceDirectory)
        let session = resources.deletingLastPathComponent()
        let store = NotebookCacheStore()
        XCTAssertEqual(session.deletingLastPathComponent(), store.root.appendingPathComponent("Sessions"))
        let temporary = try await runtime.evaluate(.init(cellID: "cache-r-tempdir", source: "cat(normalizePath(tempdir()))"))
        XCTAssertTrue(temporary.events.contains { $0.payload.text?.contains(session.appendingPathComponent("tmp").path) == true })
        _ = try store.sweep(maximumBytes: 0, removeAllFinished: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
        let result = try await runtime.evaluate(.init(cellID: "cache-working-directory", source: "cat(normalizePath(getwd()))"))
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains(config.projectDirectory.resolvingSymlinksInPath().path) == true })
        try await runtime.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.projectDirectory.path))
    }
    private func configuration() throws -> RuntimeConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookRuntimeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = try XCTUnwrap(NotebookRExecutable.locate(selected: nil), "Rscript is required for real Notebook acceptance")
        let worker = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap"))
        return RuntimeConfiguration(executable: executable, workerScript: worker, projectDirectory: root, startupTimeout: 10, taskTimeout: 12)
    }
    private func session() async throws -> RRuntime {
        let runtime = RRuntime()
        _ = try await runtime.start(configuration())
        addTeardownBlock { try await runtime.stop() }
        return runtime
    }
    private func model(_ source: String) throws -> RecordLayoutModel {
        let config = try configuration()
        let name = "NotebookTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = RecordLayoutModel(visualDefaults: defaults, notebookConfiguration: { config })
        model.source = source
        addTeardownBlock { @MainActor in await model.notebook.shutdown(); defaults.removePersistentDomain(forName: name) }
        return model
    }
    private func execute(_ runtime: RRuntime, _ source: String) async throws -> RuntimeTranscript {
        try await runtime.evaluate(EvaluationRequest(cellID: "test", source: source))
    }
    private func text(_ events: [RecordOutputEvent]) -> String {
        events.map { switch $0 { case .text(let t), .message(let t), .warning(let t), .error(let t): t; default: "" } }.joined()
    }
    func testDefaultValuesConditionsAndPlotsAreOrderedAndPrintedOnce() async throws {
        let runtime = try await session()
        let result = try await execute(runtime, "execution_count <- 1L\nprint_count <- 0L\nprint.once <- function(x, ...) { print_count <<- print_count + 1L; cat('default-once\\n'); invisible(x) }\nstructure(list(), class='once')\nmessage('native-message')\nwarning('native-warning')\nplot(1:3)\nggplot2::ggplot(data.frame(x=1:3, y=3:1), ggplot2::aes(x,y)) + ggplot2::geom_point()\ncat('after-plot\\n')\n")
        XCTAssertEqual(result.events.map(\.sequence), Array(1...result.events.count))
        XCTAssertEqual(result.events.last?.payload.status, "completed")
        XCTAssertEqual(result.events.filter { $0.payload.text == "default-once\n" }.count, 1)
        XCTAssertTrue(result.events.contains { $0.kind == "message" && $0.payload.text?.contains("native-message") == true })
        XCTAssertTrue(result.events.contains { $0.kind == "warning" && $0.payload.text?.contains("native-warning") == true })
        XCTAssertTrue(result.events.allSatisfy { !["adapter_started", "gui_result", "adapter_error"].contains($0.kind) })
        let resourceURL = await runtime.resourceDirectory
        let directory = try XCTUnwrap(resourceURL)
        let resolver = try ResourceService(rootURL: directory)
        XCTAssertGreaterThanOrEqual(result.events.filter { $0.kind == "display_image" }.count, 2, "Both base and ggplot default displays must be captured")
        let image = try XCTUnwrap(result.events.first { $0.kind == "display_image" })
        let graphic = try resolver.resolve(image)
        XCTAssertNotNil(NSImage(data: graphic.data))
        XCTAssertTrue(graphic.data.starts(with: [137,80,78,71]))
        let values = try await execute(runtime, "c(execution_count, print_count)\n")
        XCTAssertTrue(values.events.contains { $0.payload.text?.contains("1 1") == true })
    }
    func testPlotPhysicalSizeDPIAndOriginalPNGCopyKeepOneEvaluation() async throws {
        let runtime = try await session()
        let request = EvaluationRequest(cellID: "plot-size",
            source: "plot_count <- 1L\ncat('device-inches:', dev.size('in'), 'font-points:', par('ps'), '\\n')\nplot(1:3)\nggplot2::ggplot(iris, ggplot2::aes(Sepal.Length, Sepal.Width)) + ggplot2::geom_point()\n",
            plot: NotebookPlotOptions(width: 432, pointSize: 18))
        let result = try await runtime.evaluate(request)
        XCTAssertEqual(result.events.last?.payload.status, "completed")
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains("device-inches: 6 4 font-points: 18") == true })
        let resourceDirectory = await runtime.resourceDirectory
        let directory = try XCTUnwrap(resourceDirectory)
        let resolver = try ResourceService(rootURL: directory)
        let images = result.events.filter { $0.kind == "display_image" }
        XCTAssertGreaterThanOrEqual(images.count, 2)
        for event in images {
            let graphic = try resolver.resolve(event)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: graphic.data))
            XCTAssertEqual(bitmap.pixelsWide, 864); XCTAssertEqual(bitmap.pixelsHigh, 576)
            XCTAssertEqual(bitmap.size.width, 432, accuracy: 0.1)
            XCTAssertEqual(Double(bitmap.pixelsWide) * 72 / bitmap.size.width, 144, accuracy: 0.1)
            let decoded = try XCTUnwrap(NSImage(data: graphic.data))
            let image = decoded
            let view = RecordResultImageView(frame: NSRect(x: 0, y: 0, width: 432, height: 288))
            view.image = image; view.originalPNG = graphic.data
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            XCTAssertTrue(view.copyImage(to: board))
            XCTAssertEqual(board.data(forType: .png), graphic.data, "Copy must preserve source pixels and DPI, not the screen rendering")
            let tiff = try XCTUnwrap(board.data(forType: .tiff))
            let copied = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            XCTAssertEqual(copied.pixelsWide, 864); XCTAssertEqual(copied.pixelsHigh, 576)
            XCTAssertEqual(copied.size.width, 432, accuracy: 0.1)
        }
        let largeText = try await runtime.evaluate(EvaluationRequest(cellID: "large-plot-font", source: "plot(1:3)\n",
            plot: NotebookPlotOptions(width: 408, pointSize: 28)))
        XCTAssertEqual(largeText.events.last?.payload.status, "completed", "A large page font must still fit the recording device")
        let count = try await execute(runtime, "plot_count\nlength(dev.list())\n")
        XCTAssertTrue(count.events.contains { $0.payload.text?.contains("[1] 1") == true })
        XCTAssertFalse(count.events.contains { $0.payload.text?.contains("[1] 2") == true })
    }

    func testNativeKableFlextableAndGgplotRichDisplaysUseOneEvaluationAndCopyAsTables() async throws {
        let source = "```{r}\n#| label: native-rich\nexecution_count <- 1L\nx <- head(iris, 3)\nknitr::kable(x)\nflextable::bold(flextable::flextable(x), part='header')\nggplot2::ggplot(x, ggplot2::aes(Sepal.Length, Sepal.Width)) + ggplot2::geom_point()\ncat('after-rich\\n')\n```\n"
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let result = try XCTUnwrap(model.outputStates["native-rich"])
        XCTAssertFalse(result.failed, text(result.events))
        let rich = result.events.compactMap { if case .rich(let output) = $0 { return output }; return nil }
        XCTAssertEqual(rich.map(\.title), ["kable", "flextable"])
        XCTAssertTrue(result.events.contains { if case .image = $0 { return true }; return false })
        for output in rich {
            XCTAssertTrue(output.representations.contains { $0.mime == "text/html" && String(decoding: $0.data, as: UTF8.self).contains("<table") })
            let view = RecordRichOutputView(output: output, font: .systemFont(ofSize: 13))
            view.textView.selectAll(nil)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            XCTAssertTrue(view.textView.copySelection(to: board))
            let copied = try XCTUnwrap(board.string(forType: .string))
            XCTAssertTrue(copied.contains("Sepal.Length") && copied.contains("setosa"), copied)
            XCTAssertTrue(copied.contains("\t"), "Native table copy must preserve columns")
        }
        let count = try await execute(model.notebook.runtime, "execution_count\n")
        XCTAssertTrue(count.events.contains { $0.payload.text?.contains("[1] 1") == true })
        XCTAssertEqual(model.source, source)
    }

    func testRunAllUsesOneSessionAndReplacesOnlyExecutedBlockResults() async throws {
        let source = "```{r}\n#| label: first\ncounter <- if (exists('counter')) counter + 1L else 1L\ncounter\n```\n\n```{r}\n#| label: second\ncounter + 10L\n```\n"
        let model = try model(source)
        XCTAssertTrue(model.outputStates.isEmpty)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let session = model.notebook.sessionID
        XCTAssertNotNil(session); XCTAssertEqual(model.notebook.completedCount, 2)
        XCTAssertEqual(model.notebook.state, .ready)
        XCTAssertTrue(text(try XCTUnwrap(model.outputStates["second"]).events).contains("11"))
        let firstTask = model.outputStates["first"]?.taskID
        model.sourceOnly = true
        let editor = NSTextView(); editor.string = source
        editor.setSelectedRange(NSRange(location: (source as NSString).range(of: "counter + 10L").location, length: 0))
        model.activeEditor = editor
        model.runCurrentNotebookCell(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.sessionID, session)
        XCTAssertEqual(model.notebook.completedCount, 1)
        XCTAssertEqual(model.outputStates["first"]?.taskID, firstTask)
        XCTAssertTrue(text(try XCTUnwrap(model.outputStates["second"]).events).contains("11"))
        model.sourceOnly = false
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.sessionID, session)
        let actual = text(try XCTUnwrap(model.outputStates["second"]).events)
        XCTAssertTrue(actual.contains("12"), "Actual output: \(actual); phase: \(String(describing: model.outputStates["second"]?.phase)); completed: \(model.notebook.completedCount); notice: \(model.notice ?? "none"); diagnostic: \(model.notebook.diagnostic ?? "none")")
        XCTAssertEqual(model.source, source)
    }
    func testRunAllStopsOnErrorKeepsPartialOutputAndNeverRunsLaterCell() async throws {
        let source = "```{r}\n#| label: first\ncat('before-error\\n')\nstop('failure')\n```\n\n```{r}\n#| label: second\nshould_not_run <- TRUE\n```\n"
        let model = try model(source)
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let record = try XCTUnwrap(model.outputStates["first"])
        XCTAssertTrue(record.failed)
        XCTAssertTrue(text(record.events).contains("before-error"))
        XCTAssertTrue(record.events.contains { if case .error(let value) = $0 { return value.contains("failure") }; return false })
        XCTAssertNil(model.outputStates["second"])
        XCTAssertEqual(model.notebook.state, .ready)
        let result = try await execute(model.notebook.runtime, "exists('should_not_run', inherits=FALSE)\n")
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains("FALSE") == true })
        XCTAssertEqual(model.source, source)
    }
    func testSelectionExecutesOnlySelectedRAndCompositionCannotStartWorker() async throws {
        let source = "Body\n\n```{r}\n#| label: selected\nnot_selected <- 1L\ncat('selection-only\\n')\n```\n"
        let model = try model(source)
        let editor = NSTextView(); editor.string = source; model.activeEditor = editor
        editor.setSelectedRange((source as NSString).range(of: "cat('selection-only\\n')"))
        model.runNotebookSelection(); await model.notebook.waitUntilIdle()
        XCTAssertTrue(text(try XCTUnwrap(model.outputStates["selected"]).events).contains("selection-only"))
        let result = try await execute(model.notebook.runtime, "exists('not_selected', inherits=FALSE)\n")
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains("FALSE") == true })
        let protected = try self.model(source)
        let composing = NSTextView(); composing.string = source; protected.activeEditor = composing
        composing.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 0))
        protected.runAllNotebookCells()
        XCTAssertFalse(protected.notebook.isBusy)
        XCTAssertEqual(protected.notebook.state, .notStarted)
        XCTAssertEqual(protected.source, source)
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        model.runNotebookSelection()
        XCTAssertFalse(model.notebook.isBusy)
    }
    func testSyntaxErrorReturnsDefaultErrorAndSessionRemainsUsable() async throws {
        let runtime = try await session()
        let broken = try await execute(runtime, "x <-\n")
        XCTAssertEqual(broken.events.last?.payload.status, "failed")
        XCTAssertTrue(broken.events.contains { $0.kind == "error" })
        let state = await runtime.state
        XCTAssertEqual(state, .ready)
        let next = try await execute(runtime, "2 + 3\n")
        XCTAssertTrue(next.events.contains { $0.payload.text == "[1] 5\n" })
    }
    func testInterruptRejectsFurtherRunsUntilExplicitRestartAndClearsVariables() async throws {
        let model = try model("```{r}\n#| label: slow\nold_value <- 123\ncat('running-now\\n')\nSys.sleep(20)\n```\n")
        model.runAllNotebookCells()
        let deadline = Date(timeIntervalSinceNow: 8)
        while Date() < deadline && !text(model.notebook.outputState("slow")?.events ?? []).contains("running-now") {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.notebook.isBusy)
        let oldSession = model.notebook.sessionID
        model.notebook.interrupt(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .uncertain)
        XCTAssertTrue(model.outputStates["slow"]?.stopped == true)
        model.runAllNotebookCells()
        XCTAssertFalse(model.notebook.isBusy)
        model.notebook.restart(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .ready)
        XCTAssertNotEqual(model.notebook.sessionID, oldSession)
        let result = try await execute(model.notebook.runtime, "exists('old_value', inherits=FALSE)\n")
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains("FALSE") == true })
    }
    func testWorkerCrashRetainsEarlierOutputAndDoesNotRetry() async throws {
        let model = try model("```{r}\n#| label: crash\ncat('before-exit\\n')\nq(save='no', status=23)\n```\n")
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        XCTAssertEqual(model.notebook.state, .crashed)
        let record = try XCTUnwrap(model.outputStates["crash"])
        XCTAssertTrue(text(record.events).contains("before-exit"))
        XCTAssertTrue(record.failed)
        let task = record.taskID
        model.runAllNotebookCells()
        XCTAssertFalse(model.notebook.isBusy)
        XCTAssertEqual(model.outputStates["crash"]?.taskID, task)
    }
    func testNativeFDAndLargeUnicodeOutputDoNotCorruptProtocol() async throws {
        let runtime = try await session()
        let result = try await execute(runtime, "cat(paste(rep('中文🧪', 10000), collapse=''))\nsystem(\"printf 'native-fd-output\\\\n'\")\n77\n")
        XCTAssertEqual(result.events.last?.payload.status, "completed")
        let text = result.events.compactMap(\.payload.text).joined()
        XCTAssertTrue(text.contains("中文🧪")); XCTAssertTrue(text.contains("77"))
        XCTAssertTrue(text.contains("native-fd-output") || String(decoding: result.stdout, as: UTF8.self).contains("native-fd-output"))
    }
    func testHandshakeResourcesAndShutdownLeaveNoWorkerOrFIFO() async throws {
        let runtime = RRuntime()
        _ = try await runtime.start(configuration())
        let processID = await runtime.processID
        let pid = try XCTUnwrap(processID)
        let resourceURL = await runtime.resourceDirectory
        let directory = try XCTUnwrap(resourceURL)
        let root = directory.deletingLastPathComponent()
        var info = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("response.fifo").path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        try await runtime.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(kill(pid, 0), -1)
    }
    func testRepeatedShutdownWhileRunningWaitsForWorkerCleanup() async throws {
        let model = try model("```{r}\n#| label: close\ncat('close-ready\\n')\nSys.sleep(20)\n```\n")
        model.runAllNotebookCells()
        let deadline = Date(timeIntervalSinceNow: 8)
        while Date() < deadline && !text(model.notebook.outputState("close")?.events ?? []).contains("close-ready") {
            try await Task.sleep(for: .milliseconds(20))
        }
        let processID = await model.notebook.runtime.processID
        let pid = try XCTUnwrap(processID)
        async let one: Void = model.notebook.shutdown()
        async let two: Void = model.notebook.shutdown()
        _ = await (one, two)
        XCTAssertEqual(model.notebook.state, .notStarted)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(model.notebook.isBusy)
    }

    func testExplicitStartStopCanStartAgainWithoutExecutingDocument() async throws {
        let source = "```{r}\nstop('starting R must not run this document')\n```\n"
        let model = try model(source), notebook = model.notebook
        notebook.start(); await notebook.waitUntilIdle()
        XCTAssertEqual(notebook.state, .ready)
        XCTAssertTrue(model.outputStates.isEmpty)
        let session = try XCTUnwrap(notebook.sessionID)
        let processID = await notebook.runtime.processID
        let pid = try XCTUnwrap(processID)
        _ = try await execute(notebook.runtime, "session_value <- 123L")
        notebook.stop(); notebook.stop(); await notebook.waitUntilIdle()
        XCTAssertEqual(notebook.state, .notStarted)
        XCTAssertNil(notebook.sessionID); XCTAssertNil(notebook.inspectorSnapshot)
        XCTAssertFalse(notebook.isBusy); XCTAssertEqual(kill(pid, 0), -1)
        notebook.start(); await notebook.waitUntilIdle()
        XCTAssertEqual(notebook.state, .ready); XCTAssertNotEqual(notebook.sessionID, session)
        let result = try await execute(notebook.runtime, "stopifnot(!exists('session_value', inherits=FALSE));cat('FRESH_OK')")
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains("FRESH_OK") == true })
        XCTAssertEqual(model.source, source); XCTAssertTrue(model.outputStates.isEmpty)
    }

    func testStopWhileRunningRetainsOutputSkipsRemainingBlocksAndOtherSessionSurvives() async throws {
        let source = "```{r}\n#| label: slow\ncat('stop-ready\\n')\nSys.sleep(20)\n```\n\n```{r}\n#| label: skipped\nwrong <- TRUE\n```\n"
        let first = try model(source), second = try model("```{r}\nprivate_value <- 7L\n```\n")
        second.runAllNotebookCells(); await second.notebook.waitUntilIdle()
        let otherSession = second.notebook.sessionID
        first.runAllNotebookCells()
        let deadline = Date(timeIntervalSinceNow: 8)
        while Date() < deadline && !text(first.notebook.outputState("slow")?.events ?? []).contains("stop-ready") {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(first.notebook.canStop)
        let processID = await first.notebook.runtime.processID
        let pid = try XCTUnwrap(processID)
        first.notebook.stop()
        XCTAssertTrue(first.notebook.isStopping); XCTAssertTrue(first.notebook.isBusy)
        XCTAssertFalse(first.notebook.canStart); XCTAssertFalse(first.notebook.canStop)
        first.notebook.start(); first.notebook.restart(); first.notebook.stop()
        await first.notebook.waitUntilIdle()
        XCTAssertEqual(first.notebook.state, .notStarted); XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertTrue(first.outputStates["slow"]?.stopped == true)
        XCTAssertTrue(text(first.notebook.outputState("slow")?.events ?? []).contains("stop-ready"))
        XCTAssertNil(first.outputStates["skipped"]); XCTAssertEqual(first.source, source)
        XCTAssertEqual(second.notebook.sessionID, otherSession)
        let result = try await execute(second.notebook.runtime, "stopifnot(private_value==7L);cat('OTHER_OK')")
        XCTAssertTrue(result.events.contains { $0.payload.text?.contains("OTHER_OK") == true })
        first.notebook.start(); await first.notebook.waitUntilIdle()
        XCTAssertEqual(first.notebook.state, .ready)
    }

    func testClosingDuringReusableStopPreventsLaterRestart() async throws {
        let model = try model(""), notebook = model.notebook
        notebook.start(); await notebook.waitUntilIdle()
        let processID = await notebook.runtime.processID
        let pid = try XCTUnwrap(processID)
        notebook.stop()
        async let first: Void = notebook.shutdown()
        async let second: Void = notebook.shutdown()
        _ = await (first, second)
        notebook.start(); await notebook.waitUntilIdle()
        XCTAssertEqual(notebook.state, .notStarted); XCTAssertNil(notebook.sessionID)
        XCTAssertFalse(notebook.isBusy); XCTAssertEqual(kill(pid, 0), -1)
    }

    func testNativeKeyboardRunDoesNotInsertTextOrChangeTheExecutionSource() async throws {
        let source = "```{r}\n#| label: keyboard\n3 + 6\n```\n"
        let model = try model(source)
        model.sourceOnly = true
        let defaults = model.visualDefaults
        let host = RecordNativeEditorHost(model: model, sourceSettings: SourceEditorSettings(defaults: defaults),
                                          appearanceSettings: AppearanceSettings(defaults: defaults))
        defer { host.detach() }
        host.editor.setSelectedRange(NSRange(location: (source as NSString).range(of: "3 + 6").location, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(host.handleNotebookShortcut(event))
        await model.notebook.waitUntilIdle()
        XCTAssertTrue(text(try XCTUnwrap(model.outputStates["keyboard"]).events).contains("[1] 9"))
        XCTAssertEqual(model.source, source)
        XCTAssertEqual(host.editor.string, source)
    }

    func testMissingRSelectionDoesNotSilentlyUseAnotherExecutable() {
        XCTAssertNil(NotebookRExecutable.locate(selected: "/does/not/exist/Rscript"))
    }
    func testRichProtocolRejectsUnsupportedMimeOversizedStylesAndOldVersion() throws {
        let command = RuntimeCommand(sessionID: UUID(), requestID: UUID(), taskID: UUID(), kind: "evaluate", cellID: "rich", sourceHash: "hash")
        func event(_ kind: String, _ sequence: Int, _ payload: RuntimePayload, version: String = "1.4") -> RuntimeEnvelope {
            RuntimeEnvelope(protocolVersion: version, sessionID: command.sessionID, requestID: command.requestID,
                taskID: command.taskID, sequence: sequence, cellID: command.cellID, sourceHash: command.sourceHash, kind: kind, payload: payload)
        }
        var old = ResponseValidator(command: command)
        XCTAssertThrowsError(try old.accept(event("started", 1, RuntimePayload(), version: "1.0")))
        for payload in [RuntimePayload(representations: [.init(mime: "application/javascript", text: "alert(1)")]),
                        RuntimePayload(representations: [.init(mime: "text/html", text: "<table/>")], styles: [String(repeating: "a", count: 1_048_577)])] {
            var validator = ResponseValidator(command: command)
            try validator.accept(event("started", 1, RuntimePayload()))
            XCTAssertThrowsError(try validator.accept(event("display_rich", 2, payload)))
        }
    }

    func testProtocolRejectsCustomGUIEventsAndDecodesPartialUnicodeFrames() throws {
        let request = EvaluationRequest(cellID: "test", source: "1")
        let command = RuntimeCommand(sessionID: UUID(), requestID: UUID(), taskID: request.taskID, kind: "evaluate", cellID: request.cellID, sourceHash: request.sourceHash)
        func event(_ sequence: Int, _ kind: String) -> RuntimeEnvelope {
            RuntimeEnvelope(protocolVersion: command.protocolVersion, sessionID: command.sessionID, requestID: command.requestID, taskID: command.taskID,
                sequence: sequence, cellID: command.cellID, sourceHash: command.sourceHash, kind: kind, payload: RuntimePayload(text: "中文🧪"))
        }
        var validator = ResponseValidator(command: command)
        try validator.accept(event(1, "started"))
        XCTAssertThrowsError(try validator.accept(event(2, "gui_result")))
        let encoded = try JSONEncoder().encode(event(2, "stdout"))
        var bytes = Data([UInt8((encoded.count >> 24) & 255), UInt8((encoded.count >> 16) & 255), UInt8((encoded.count >> 8) & 255), UInt8(encoded.count & 255)])
        bytes.append(encoded)
        var decoder = ResponseFrameDecoder()
        XCTAssertTrue(try decoder.feed(bytes.prefix(3)).isEmpty)
        let result = try decoder.feed(bytes.dropFirst(3))
        XCTAssertEqual(result.first?.payload.text, "中文🧪")
    }
}
