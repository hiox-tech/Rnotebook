import AppKit
import Combine
import Foundation

/// One Notebook owns one lazy R session. No GUI module registry or adapters.
@MainActor final class NotebookExecution: NSObject, ObservableObject {
    struct Job {
        let blockID: String
        let blockHash: String
        let request: EvaluationRequest
        let documentHash: String
        let selectionOnly: Bool
        var skipped = false
        var manualNote: String?
    }
    private enum ExecutionOutcome { case completed, failed, abort }
    private enum Output {
        case text(String, String)
        case image(String, NSImage, Data)
        case rich(RecordRichOutput)
    }
    @MainActor private final class Delivery {
        var outputs: [Output] = []
        var processed = 0
        var graphicBytes = 0
        var finished = false
        var displayFailed = false
    }
    private weak var model: RecordLayoutModel?
    let runtime = RRuntime()
    private let configuration: (() throws -> RuntimeConfiguration)?
    private var operation: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var resources: ResourceService?
    private var closed = false
    private var stopRequested = false
    private var resultPublication: Task<Void, Never>?
    private var coalescesResults = false
    private var batchOutputs: [String: RecordOutputLayout.State]?
    func outputState(_ id: String) -> RecordOutputLayout.State? {
        batchOutputs?[id] ?? model?.outputStates[id]
    }
    private func storeOutput(_ state: RecordOutputLayout.State, for id: String) {
        if batchOutputs != nil { batchOutputs![id] = state }
        else { model?.outputStates[id] = state }
    }
    private(set) var runTotalCount = 0
    private(set) var isRunningCells = false
    var executionProgress: Double? {
        guard isRunningCells, runTotalCount > 0 else { return nil }
        return Double(runTotalCount - pendingCount) / Double(runTotalCount)
    }
    private(set) var state: SessionState = .notStarted
    private(set) var sessionID: UUID?
    private(set) var handshake: RuntimePayload?
    private(set) var activeBlockID: String?
    private var busy = false
    private(set) var isBusy: Bool {
        get { busy || closing != nil }
        set { busy = newValue }
    }
    var isStopping: Bool { closing != nil }
    var canStart: Bool { !closed && !isBusy && state == .notStarted }
    var canStop: Bool { !closed && !isStopping && state != .notStarted && state != .starting }
    private(set) var completedCount = 0
    private(set) var failedCount = 0
    private(set) var skippedCount = 0
    private(set) var pendingCount = 0
    private(set) var stoppedCount = 0
    private(set) var lastRunSummary: String?
    private(set) var diagnostic: String?
    private(set) var inspectorSnapshot: NotebookInspectorSnapshot?
    private(set) var inspectorVariables: [NotebookVariable] = []
    private(set) var inspectorVariablePage: NotebookVariablePage?
    private(set) var variableQuery = ""
    private var variableFilterTask: Task<Void, Never>?
    private var variableFilterGeneration = 0
    var variablesMatchQuery: Bool {
        inspectorVariablePage.map {
            Data($0.query.utf8) == Data(variableQuery.utf8) && $0.snapshotID == inspectorSnapshot?.variablePage?.snapshotID
        } ?? false
    }
    var canLoadMoreVariables: Bool {
        variablesMatchQuery && inspectorVariables.count < (inspectorVariablePage?.total ?? 0)
    }
    private(set) var inspectorActivity: String?
    private(set) var inspectorMessage: String?
    private(set) var inspectorLog = ""
    private(set) var objectPreview: NotebookObjectPreview?
    private(set) var previewError: String?
    private(set) var inspectorRevision = 0
    private var inspectorLogID = UUID()
    private var startedRSelection = ""
    private var executionSelection: String {
        (model?.visualDefaults.string(forKey: "notebook.rscript") ?? "") + "\n" +
        (model?.visualDefaults.string(forKey: "notebook.packageLibrary") ?? "")
    }
    var openHelpURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var openDirectoryURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var workingDirectoryURL: URL? {
        if state != .notStarted, let path = inspectorSnapshot?.workingDirectory ?? handshake?.workingDirectory { return URL(fileURLWithPath: path, isDirectory: true) }
        return model?.notebookDirectory
    }
    func revealWorkingDirectory() {
        guard let url = workingDirectoryURL else { return }
        if !openDirectoryURL(url) { model?.notice = L10n.string("无法在访达中打开工作目录。") }
    }
    weak var window: NSWindow?
    var needsRestart: Bool { state == .uncertain || state == .crashed }
    var hasPendingRSelection: Bool {
        sessionID != nil && startedRSelection != executionSelection
    }
    var status: String {
        if isStopping { return L10n.string("正在停止 R…") }
        return switch state {
        case .notStarted: L10n.string("R 未启动")
        case .starting: L10n.string("正在启动 R…")
        case .ready: L10n.string("R \(String(handshake?.rVersion ?? "")) · 就绪")
        case .busy: L10n.string("R 正在运行…")
        case .interrupting: L10n.string("正在停止 R…")
        case .uncertain: L10n.string("R 已停止，请重启会话")
        case .crashed: L10n.string("R 会话不可用，请重启")
        }
    }
    init(model: RecordLayoutModel, configuration: (() throws -> RuntimeConfiguration)? = nil) {
        self.model = model; self.configuration = configuration
        super.init()
        NotebookSessions.register(self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
    }
    private func publish() {
        objectWillChange.send(); model?.objectWillChange.send()
    }
    private func changedResults() {
        guard coalescesResults else { publishResults(); return }
        guard resultPublication == nil else { return }
        resultPublication = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            // Cancellation can arrive after sleep resumes but before this
            // continuation obtains the main actor. The completed batch has
            // already published; that queued continuation must stay silent.
            guard !Task.isCancelled, let self, !closed else { return }
            resultPublication = nil
            publishResults()
        }
    }
    private func publishResults() {
        if batchOutputs != nil { publish() }
        else { model?.outputRevision &+= 1; objectWillChange.send() }
    }
    private func finishResultPublication() {
        resultPublication?.cancel(); resultPublication = nil
        if let outputs = batchOutputs {
            for (id, state) in outputs { model?.outputStates[id] = state }
            batchOutputs = nil
        }
        coalescesResults = false; publishResults()
    }
    @objc private func windowClosed(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        Task { await shutdown() }
    }
    func configurationForSession() throws -> RuntimeConfiguration {
        if let configuration { return try configuration() }
        guard let model, let executable = NotebookRExecutable.locate(selected: model.visualDefaults.string(forKey: "notebook.rscript")),
              let worker = Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap") else {
            throw RuntimeError.unavailable
        }
        guard let directory = model.notebookDirectory else { throw QuartoExportError.detail(L10n.string("请先保存 QMD 文档，再启动 R。")) }
        return RuntimeConfiguration(executable: executable, workerScript: worker, projectDirectory: directory,
                                    packageLibrary: NotebookLibrary.selected(defaults: model.visualDefaults))
    }
    func run(_ jobs: [Job], batch: Bool = false) {
        guard !closed, !isBusy, !jobs.isEmpty else { return }
        // All-skipped plans need neither an R process nor a save location.
        if jobs.allSatisfy(\.skipped) {
            batchOutputs = [:]
            runTotalCount = jobs.count; coalescesResults = true
            completedCount = 0; failedCount = 0; skippedCount = 0; stoppedCount = 0; pendingCount = jobs.count
            for job in jobs { markSkipped(job); skippedCount += 1; pendingCount -= 1 }
            finishSummary(jobs, batch: batch); finishResultPublication(); return
        }
        if let document = model?.document, document.fileURL == nil {
            document.ensureSaved { [weak self] in
                guard let self, let model else { return }
                // Saving can change source. A changed snapshot must not start
                // a process or run the stale plan.
                guard DocumentRevision(text: model.source).rawValue == jobs.first?.documentHash else {
                    model.notice = L10n.string("正文已修改，请重新运行。"); return
                }
                self.run(jobs, batch: batch)
            }; return
        }
        guard !hasPendingRSelection else { model?.notice = L10n.string("设置中的 R 已更换，请先重启 R 会话。"); return }
        guard !needsRestart else { model?.notice = L10n.string("R 会话需要重启后才能继续运行。"); return }
        batchOutputs = batch ? [:] : nil
        isRunningCells = true; runTotalCount = jobs.count; coalescesResults = jobs.count > 1
        isBusy = true; stopRequested = false; completedCount = 0; failedCount = 0; skippedCount = 0; stoppedCount = 0; pendingCount = jobs.count
        diagnostic = nil; lastRunSummary = nil
        publish()
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                finishSummary(jobs, batch: batch)
                isBusy = false; isRunningCells = false; activeBlockID = nil; operation = nil
                finishResultPublication()
            }
            do {
                if state == .notStarted { try await startSession() }
                execution: for job in jobs {
                    guard !closed, !stopRequested, state == .ready else { break }
                    guard let model, DocumentRevision(text: model.source).rawValue == job.documentHash,
                          model.visualBlocks.blocks(in: model.source).contains(where: { $0.id == job.blockID && $0.sourceHash == job.blockHash && $0.canRun }) else {
                        diagnostic = L10n.string("正文已修改，尚未开始的代码块没有执行。"); model?.notice = diagnostic; break
                    }
                    if job.skipped { markSkipped(job); skippedCount += 1; pendingCount -= 1; continue }
                    let outcome = await execute(job)
                    pendingCount -= 1
                    switch outcome {
                    case .completed: completedCount += 1
                    case .failed: failedCount += 1
                    case .abort:
                        if outputState(job.blockID)?.stopped == true { stoppedCount += 1 }
                        else { failedCount += 1 }
                        break execution
                    }
                    changedResults()
                    if outcome == .failed && !job.request.continueOnError { break }
                }
            } catch {
                if !closed { state = await runtime.state; diagnostic = error.localizedDescription; model?.notice = diagnostic }
            }
            // Inspect once after the submitted range, including early failures.
            // Rebuilding all variables and packages for every cell is quadratic.
            await updateInspectorSnapshot()
            inspectorRevision &+= 1; objectPreview = nil
            if let resources, let sessionID {
                let outputs = (model?.outputStates ?? [:]).merging(batchOutputs ?? [:], uniquingKeysWith: { _, new in new })
                let tasks = Set(outputs.values.filter { $0.sessionID == sessionID }.compactMap(\.taskID))
                resources.removeResources(except: tasks)
            }
        }
    }
    private func markSkipped(_ job: Job) {
        guard model != nil else { return }
        var record = outputState(job.blockID) ?? RecordOutputLayout.State(hash: job.blockHash)
        record.skipped = true; record.running = false
        if record.isSample { record.events = []; record.isSample = false; record.sessionID = sessionID }
        record.phase = L10n.string("本次已跳过 · eval 禁用"); record.runSummary = nil
        storeOutput(record, for: job.blockID)
        changedResults()
    }
    private func finishSummary(_ jobs: [Job], batch: Bool) {
        guard batch, !closed else { return }
        let summary = L10n.string("成功") + " \(completedCount) · " + L10n.string("跳过") + " \(skippedCount) · " + L10n.string("失败") + " \(failedCount) · " + L10n.string("未运行") + " \(pendingCount)" + (stoppedCount == 0 ? "" : " · " + L10n.string("已停止") + " \(stoppedCount)")
        lastRunSummary = summary
    }
    func waitUntilIdle() async {
        repeat {
            if let pending = operation { await pending.value }
            await closing?.value
            if let filtering = variableFilterTask { await filtering.value }
        } while operation != nil || closing != nil || variableFilterTask != nil
    }
    func start() {
        guard canStart else { return }
        manage(.init(operation: .snapshot))
    }
    private func startSession() async throws {
        state = .starting; publish()
        do {
            let selection = executionSelection
            let result = try await runtime.start(configurationForSession())
            guard !closed else { throw RuntimeError.stopped }
            handshake = result; sessionID = await runtime.sessionID
            startedRSelection = selection
            guard let directory = await runtime.resourceDirectory else { throw RuntimeError.unavailable }
            resources = try ResourceService(rootURL: directory)
            state = .ready; publish(); startMonitor()
            await updateInspectorSnapshot(refreshPackages: true)
        } catch { try? await runtime.stop(); throw error }
    }
    private func applyInspectorSnapshot(_ transcript: RuntimeTranscript) {
        if let snapshot = transcript.events.last(where: { $0.kind == "inspector_result" })?.payload.inspector {
            if let page = snapshot.variablePage, Data(page.query.utf8) == Data(variableQuery.utf8) {
                if page.offset == 0 {
                    inspectorVariables = snapshot.variables
                    inspectorVariablePage = page
                } else if inspectorVariablePage?.snapshotID == page.snapshotID,
                          variablesMatchQuery, page.offset == inspectorVariables.count {
                    let names = Set(inspectorVariables.map(\.id))
                    guard snapshot.variables.allSatisfy({ !names.contains($0.id) }) else { return }
                    inspectorVariables += snapshot.variables
                    inspectorVariablePage = page
                }
            }
            inspectorSnapshot = snapshot; publish()
        }
    }
    func filterVariables(_ query: String) {
        guard !closed, Data(query.utf8) != Data(variableQuery.utf8),
              NotebookVariablePageRequest(query: query).isValid else { return }
        variableQuery = query
        variableFilterGeneration &+= 1
        let generation = variableFilterGeneration
        variableFilterTask?.cancel()
        publish()
        variableFilterTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == variableFilterGeneration { variableFilterTask = nil } }
            do {
                try await Task.sleep(for: .milliseconds(200))
                // Do not start R or compete with an evaluation. A completed run
                // may already have refreshed this query, avoiding another read.
                while isBusy { try await Task.sleep(for: .milliseconds(50)) }
                guard !Task.isCancelled, !closed, generation == variableFilterGeneration,
                      state == .ready, !needsRestart, !hasPendingRSelection, !variablesMatchQuery else { return }
                manage(.init(operation: .snapshot, refreshPackages: false,
                             variablePage: .init(query: query, snapshotID: inspectorSnapshot?.variablePage?.snapshotID)), expectedSession: sessionID)
            } catch { }
        }
    }
    func loadMoreVariables() {
        guard !closed, !isBusy, state == .ready, canLoadMoreVariables,
              let page = inspectorVariablePage else { return }
        manage(.init(operation: .snapshot, refreshPackages: false,
                     variablePage: .init(query: variableQuery, offset: inspectorVariables.count, snapshotID: page.snapshotID)), expectedSession: sessionID)
    }
    private func updateInspectorSnapshot(refreshPackages: Bool = false) async {
        guard !closed, state == .ready else { return }
        do {
            let transcript = try await runtime.inspect(.init(operation: .snapshot, refreshPackages: refreshPackages,
                                                           variablePage: .init(query: variableQuery)))
            applyInspectorSnapshot(transcript)
            state = await runtime.state
            if transcript.events.last?.payload.status != "completed" {
                inspectorMessage = transcript.events.first(where: { $0.kind == "error" })?.payload.text ?? L10n.string("无法刷新变量与包")
            }
        } catch {
            state = await runtime.state; inspectorMessage = L10n.string("无法刷新面板：") + error.localizedDescription
        }
        publish()
    }
    func manage(_ incoming: NotebookInspectorRequest, expectedSession: UUID? = nil) {
        var request = incoming
        if request.variablePage == nil, ![.completion, .help, .previewObject].contains(request.operation) {
            request.variablePage = .init(query: variableQuery)
        }
        if request.operation == .help {
            guard !closed, let url = NotebookOfficialHelp.searchURL(request.name ?? "") else { return }
            inspectorMessage = openHelpURL(url) ? nil : L10n.string("未能打开浏览器帮助。")
            if inspectorMessage != nil { model?.notice = inspectorMessage }
            publish(); return
        }
        if request.operation == .clearObjects || request.operation == .previewObject {
            guard state == .ready, let expectedSession, expectedSession == sessionID else {
                previewError = L10n.string("R 会话已变化或正在运行，请重新选择变量。"); publish(); return
            }
        }
        if let document = model?.document, document.fileURL == nil {
            document.ensureSaved { [weak self] in self?.manage(request, expectedSession: expectedSession) }; return
        }
        guard !closed, !isBusy else { return }
        guard request.isValid else { inspectorMessage = L10n.string("请输入有效的包名或帮助主题。"); publish(); return }
        guard !needsRestart, !hasPendingRSelection else { model?.notice = L10n.string("请先重启 R，再操作面板。"); return }
        guard expectedSession == nil || expectedSession == sessionID else { model?.notice = L10n.string("R 会话已变化，请重新选择变量。"); return }
        if request.operation == .previewObject { objectPreview = nil; previewError = nil }
        isBusy = true; stopRequested = false; inspectorMessage = nil
        inspectorActivity = L10n.string("正在") + request.title + (request.name.map { " " + $0 } ?? "") + "…"
        inspectorLog = ""; inspectorLogID = UUID()
        let logID = inspectorLogID
        publish()
        let requestSession = sessionID
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                isBusy = false; operation = nil; inspectorActivity = nil
                publish()
            }
            do {
                let wasNotStarted = state == .notStarted
                if wasNotStarted { try await startSession() }
                guard !closed, !stopRequested, state == .ready else { return }
                if wasNotStarted && request.operation == .snapshot { return }
                state = .busy(taskID: UUID()); publish()
                let transcript = try await runtime.inspect(request, event: { [weak self] event in
                    if ["stdout", "message", "warning", "error"].contains(event.kind), let text = event.payload.text {
                        Task { @MainActor in self?.appendInspectorLog(text + "\n", id: logID) }
                    }
                }, console: { [weak self] _, bytes in
                    Task { @MainActor in self?.appendInspectorLog(String(decoding: bytes, as: UTF8.self), id: logID) }
                })
                guard !closed else { return }
                state = await runtime.state
                applyInspectorSnapshot(transcript)
                if request.operation == .previewObject, requestSession == sessionID {
                    objectPreview = transcript.events.first(where: { $0.kind == "inspector_result" })?.payload.objectPreview
                    previewError = objectPreview == nil ? (transcript.events.first(where: { $0.kind == "error" })?.payload.text ?? L10n.string("无法读取变量预览")) : nil
                }
                if transcript.events.last?.payload.status == "completed" {
                    
                    inspectorMessage = [.snapshot, .previewObject].contains(request.operation) ? nil : request.title + L10n.string("完成") + (request.name.map { "：" + $0 } ?? "")
                    if [.clearObjects, .removeObject, .loadPackage, .unloadPackage, .installPackage].contains(request.operation) {
                        inspectorRevision &+= 1; objectPreview = nil
                        let warnings = transcript.events.filter { $0.kind == "warning" }.compactMap(\.payload.text)
                        if !warnings.isEmpty {
                            inspectorMessage = warnings.joined(separator: "；")
                            if request.operation != .installPackage { model?.notice = inspectorMessage }
                        }
                        changedResults()
                    }
                } else {
                    inspectorMessage = transcript.events.first(where: { $0.kind == "error" })?.payload.text ?? L10n.string("操作已停止，请重启 R 后继续。")
                    if ![.installPackage, .previewObject].contains(request.operation), !stopRequested { model?.notice = inspectorMessage }
                    // A failed attach/install may have partly changed the environment.
                    // Refresh from R rather than leaving an optimistic checkbox state.
                    if state == .ready, request.operation != .previewObject { await updateInspectorSnapshot(refreshPackages: true) }
                }
            } catch {
                if !closed {
                    state = await runtime.state; inspectorMessage = error.localizedDescription
                    if request.operation == .previewObject { previewError = error.localizedDescription }
                    else if request.operation != .installPackage && !stopRequested { model?.notice = inspectorMessage }
                }
            }
        }
    }
    private func appendInspectorLog(_ text: String, id: UUID) {
        guard id == inspectorLogID, !closed else { return }
        inspectorLog = String((inspectorLog + text).suffix(32768)); publish()
    }
    private func execute(_ job: Job) async -> ExecutionOutcome {
        guard model != nil else { return .abort }
        activeBlockID = job.blockID; state = .busy(taskID: job.request.taskID)
        var result = RecordOutputLayout.State(hash: job.blockHash)
        result.isSample = false; result.running = true; result.sessionID = sessionID; result.taskID = job.request.taskID
        result.manualNote = job.manualNote
        result.phase = job.manualNote ?? (job.selectionOnly ? L10n.string("正在运行选中代码") : L10n.string("运行中"))
        storeOutput(result, for: job.blockID)
        changedResults()
        let pending = PendingNotebookEvents()
        let delivery = Delivery()
        let flush: @MainActor @Sendable () -> Void = { [self] in
            guard !closed, !delivery.finished else { return }
            let received = pending.snapshot()
            for event in received.events where event.sequence > delivery.processed {
                delivery.processed = event.sequence
                switch event.kind {
                case "stdout", "display_text", "message", "warning", "error":
                    let kind = event.kind == "display_text" ? "stdout" : event.kind
                    let text = event.payload.text ?? ""
                    if case .text(let priorKind, let priorText) = delivery.outputs.last, priorKind == kind {
                        delivery.outputs[delivery.outputs.count - 1] = .text(kind, priorText + text)
                    } else { delivery.outputs.append(.text(kind, text)) }
                case "display_rich":
                    let rich = RecordRichOutput(title: event.payload.title ?? L10n.string("富文本"),
                        representations: (event.payload.representations ?? []).map { .init(mime: $0.mime, text: $0.text) },
                        styles: event.payload.styles ?? [])
                    delivery.outputs.append(.rich(rich))
                case "display_image":
                    do {
                        guard let resources else { throw RuntimeError.resource(L10n.string("会话资源已失效")) }
                        let graphic = try resources.resolve(event)
                        guard delivery.graphicBytes + graphic.data.count <= 33_554_432, let image = NSImage(data: graphic.data) else {
                            throw RuntimeError.resource(L10n.string("图形缓存超限或无法解码"))
                        }
                        delivery.graphicBytes += graphic.data.count
                        delivery.outputs.append(.image(graphic.id, image, graphic.data))
                    } catch { delivery.displayFailed = true; delivery.outputs.append(.text("error", error.localizedDescription)) }
                case "plots_finalized":
                    let keep = Set(event.payload.resourceIDs ?? [])
                    delivery.outputs.removeAll { if case .image(let id, _, _) = $0 { return !keep.contains(id) }; return false }
                default: break
                }
            }
            guard var state = outputState(job.blockID), state.sessionID == sessionID else { return }
            state.events = delivery.outputs.map { output in
                switch output {
                case .image(_, let image, let data): return .image(image, pngData: data)
                case .rich(let rich): return .rich(rich)
                case .text(let kind, let text):
                    switch kind { case "message": return .message(text); case "warning": return .warning(text); case "error": return .error(text); default: return .text(text) }
                }
            }
            if !received.stdout.isEmpty { state.events.append(.text(L10n.string("外部控制台 stdout\n") + String(decoding: received.stdout, as: UTF8.self))) }
            if !received.stderr.isEmpty { state.events.append(.text(L10n.string("外部控制台 stderr\n") + String(decoding: received.stderr, as: UTF8.self))) }
            storeOutput(state, for: job.blockID); changedResults()
        }
        // A coalesced flush runs only on the main actor. Final/catch paths drain
        // the same validated buffer, preserving output even if the worker exits.
        let deliver: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                await Task.yield()
                guard self != nil else { return }
                flush()
            }
        }
        var succeeded = false
        var recoverableFailure = false
        do {
            let transcript = try await runtime.evaluate(job.request, event: { event in
                if pending.append(event) { deliver() }
            }, console: { stream, data in
                if pending.appendConsole(stream, data) { deliver() }
            })
            pending.merge(transcript.events); flush()
            guard !closed else { return .abort }
            state = await runtime.state
            recoverableFailure = transcript.events.last?.payload.status == "failed" && transcript.events.last?.payload.uncertain == false && state == .ready && !delivery.displayFailed && !stopRequested
            succeeded = transcript.events.last?.payload.status == "completed" && state == .ready && !delivery.displayFailed
            if var record = outputState(job.blockID) {
                record.running = false; record.stopped = stopRequested || transcript.events.last?.payload.status == "interrupted"
                record.failed = !succeeded && !record.stopped
                record.phase = record.stopped ? L10n.string("已停止") : record.failed ? L10n.string("执行失败") : job.selectionOnly ? L10n.string("选中代码已完成") : L10n.string("已完成")
                if let note = job.manualNote { record.phase += " · " + note }
                storeOutput(record, for: job.blockID)
            }
        } catch {
            flush()
            if !closed {
                state = await runtime.state; diagnostic = error.localizedDescription
                if var record = outputState(job.blockID) {
                    record.running = false; record.stopped = stopRequested || state == .interrupting; record.failed = !record.stopped
                    record.phase = record.stopped ? L10n.string("已停止") : L10n.string("执行失败")
                    record.events.append(.error(error.localizedDescription)); storeOutput(record, for: job.blockID)
                }
            }
        }
        delivery.finished = true
        changedResults()
        return succeeded ? .completed : recoverableFailure ? .failed : .abort
    }
    func interrupt() {
        guard isBusy, !isStopping else { return }
        stopRequested = true; state = .interrupting; publish()
        Task { await runtime.interrupt() }
    }
    var canSaveWorkspace: Bool { !closed && !isBusy && state == .ready && !hasPendingRSelection }
    func saveWorkspace(to destination: NotebookWorkspaceDestination, expectedSession: UUID) {
        guard canSaveWorkspace, sessionID == expectedSession else {
            model?.notice = L10n.string("R 会话已变化或正在运行，请在会话就绪后重新保存。"); return
        }
        isBusy = true; stopRequested = false; state = .busy(taskID: UUID())
        inspectorActivity = L10n.string("正在保存 R 工作区…"); inspectorMessage = nil; publish()
        operation = Task { [weak self] in
            guard let self else { return }
            let directory = resources?.rootURL.appendingPathComponent("workspace-" + UUID().uuidString)
            defer {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                isBusy = false; operation = nil; inspectorActivity = nil; publish()
            }
            do {
                guard let directory, sessionID == expectedSession, !stopRequested else { throw RuntimeError.stopped }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                let artifact = directory.appendingPathComponent("workspace.RData")
                let transcript = try await runtime.inspect(.init(operation: .saveWorkspace, name: artifact.path,
                                                               variablePage: .init(query: variableQuery)))
                guard !closed else { return }
                state = await runtime.state
                applyInspectorSnapshot(transcript)
                guard !stopRequested, sessionID == expectedSession,
                      transcript.events.last?.payload.status == "completed", state == .ready else {
                    throw NotebookWorkspaceDestination.error(transcript.events.first(where: { $0.kind == "error" })?.payload.text ?? L10n.string("R 工作区保存已停止，未覆盖目标文件。"))
                }
                try destination.publish(artifact)
                inspectorMessage = L10n.string("R 工作区已保存：") + destination.url.lastPathComponent
            } catch {
                guard !closed else { return }
                state = await runtime.state
                inspectorMessage = error.localizedDescription; model?.notice = error.localizedDescription
            }
        }
    }
    var restartWarning: String { L10n.string("重启 R 会清除当前会话中的所有变量；已有输出仅保留在当前文档窗口。") }
    func restart(runAllAfter: Bool = false) {
        guard !closed, !isBusy else { return }
        if let document = model?.document, document.fileURL == nil {
            document.ensureSaved { [weak self] in self?.restart(runAllAfter: runAllAfter) }; return
        }
        if runAllAfter {
            guard let model else { return }
            let jobs = model.notebookJobs(all: true)
            guard !jobs.isEmpty else { return }
            if jobs.allSatisfy(\.skipped) { run(jobs, batch: true); return }
        }
        isBusy = true; stopRequested = false; state = .starting; publish()
        operation = Task { [weak self] in
            guard let self else { return }
            var shouldRun = false
            defer {
                isBusy = false; operation = nil; changedResults()
                if shouldRun, !closed, !stopRequested, state == .ready { model?.runAllNotebookCells() }
            }
            do {
                monitor?.cancel(); monitor = nil
                try await runtime.stop(); sessionID = nil; handshake = nil; resources = nil
                inspectorSnapshot = nil; inspectorVariables = []; inspectorVariablePage = nil
                objectPreview = nil; previewError = nil; inspectorRevision &+= 1; inspectorMessage = nil; inspectorLog = ""
                state = .notStarted; diagnostic = nil
                guard !closed, !stopRequested else { return }
                try await startSession(); changedResults(); shouldRun = runAllAfter
            } catch { state = .crashed; diagnostic = error.localizedDescription; model?.notice = diagnostic }
        }
    }
    func stop() {
        guard canStop else { return }
        stopSession()
    }
    private func stopSession() {
        variableFilterTask?.cancel(); variableFilterTask = nil; variableFilterGeneration &+= 1
        let pending = operation
        stopRequested = true; monitor?.cancel(); monitor = nil
        isBusy = true; state = .interrupting
        let task = Task { [self] in
            defer {
                isBusy = false; closing = nil; activeBlockID = nil
                changedResults()
            }
            do {
                try await runtime.stop(); await pending?.value
                resources = nil; sessionID = nil; handshake = nil; state = .notStarted
                inspectorSnapshot = nil; inspectorVariables = []; inspectorVariablePage = nil
                objectPreview = nil; previewError = nil; inspectorRevision &+= 1; inspectorActivity = nil; inspectorMessage = nil
                inspectorLog = ""; inspectorLogID = UUID(); diagnostic = nil
            } catch {
                await pending?.value
                state = .crashed; diagnostic = error.localizedDescription
                if !closed { model?.notice = diagnostic }
            }
        }
        closing = task
        publish()
    }
    func shutdown() async {
        if let closing { closed = true; await closing.value; return }
        guard !closed else { return }
        closed = true
        stopSession()
        await closing?.value
    }
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, !closed else { return }
                if state == .ready, await runtime.health() == .crashed {
                    state = .crashed; diagnostic = RuntimeError.disconnected.localizedDescription; publish(); return
                }
            }
        }
    }
}

private final class PendingNotebookEvents: @unchecked Sendable {
    struct Snapshot { let events: [RuntimeEnvelope]; let stdout: Data; let stderr: Data }
    private let lock = NSLock()
    private var events: [RuntimeEnvelope] = []
    private var stdout = Data(), stderr = Data()
    private var scheduled = false
    func append(_ event: RuntimeEnvelope) -> Bool {
        lock.withLock { events.append(event); let needs = !scheduled; scheduled = true; return needs }
    }
    func appendConsole(_ stream: String, _ bytes: Data) -> Bool {
        lock.withLock {
            if stream == "stdout" { stdout.append(bytes.prefix(max(0, 65536 - stdout.count))) }
            else { stderr.append(bytes.prefix(max(0, 65536 - stderr.count))) }
            let needs = !scheduled; scheduled = true; return needs
        }
    }
    func merge(_ all: [RuntimeEnvelope]) { lock.withLock { events = all } }
    func snapshot() -> Snapshot {
        lock.withLock { scheduled = false; return Snapshot(events: events, stdout: stdout, stderr: stderr) }
    }
}

@MainActor enum NotebookSessions {
    private final class Weak { weak var value: NotebookExecution?; init(_ value: NotebookExecution) { self.value = value } }
    private static var sessions: [Weak] = []
    static func register(_ session: NotebookExecution) { sessions.removeAll { $0.value == nil }; sessions.append(Weak(session)) }
    static func shutdownAll() async { for session in sessions.compactMap(\.value) { await session.shutdown() } }
    static var hasStarted: Bool { sessions.contains { $0.value?.state != nil && $0.value?.state != .notStarted } }
}

enum NotebookRExecutable {
    static func locate(selected: String?) -> URL? {
        if let selected, !selected.isEmpty { return FileManager.default.isExecutableFile(atPath: selected) ? URL(fileURLWithPath: selected) : nil }
        if let bundled = NotebookBundledRuntime.rscript { return bundled }
        let environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/Rscript" }
        for path in paths + ["/Library/Frameworks/R.framework/Resources/bin/Rscript", "/opt/homebrew/bin/Rscript", "/usr/local/bin/Rscript"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
