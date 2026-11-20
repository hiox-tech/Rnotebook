import Foundation

actor RRuntime: LanguageRuntime {
    private(set) var state: SessionState = .notStarted
    private(set) var sessionID: UUID?
    private(set) var resourceDirectory: URL?
    private(set) var processID: Int32?
    private var channel: RProcessChannel?
    private var inFlight: Task<RuntimeTranscript, Error>?
    private var taskTimeout: TimeInterval = 3600
    private var isStopping = false
    private var completionFlight: Task<RuntimeTranscript, Error>?

    func health() -> SessionState {
        if state == .ready, let channel, !channel.isRunning { state = .crashed }
        return state
    }

    func start(_ configuration: RuntimeConfiguration) async throws -> RuntimePayload {
        guard channel == nil, inFlight == nil, !isStopping else { throw RuntimeError.busy }
        state = .starting
        var starting: RProcessChannel?
        do {
            let created = try RProcessChannel(executable: configuration.executable, worker: configuration.workerScript,
                                             project: configuration.projectDirectory, library: configuration.packageLibrary)
            starting = created
            channel = created; sessionID = created.sessionID; resourceDirectory = created.resourceURL; processID = created.pid
            taskTimeout = configuration.taskTimeout
            let hello = RuntimeCommand(sessionID: created.sessionID, requestID: UUID(), taskID: UUID(), kind: "hello")
            let transcript = try await exchange(hello, channel: created, timeout: configuration.startupTimeout, event: { _ in }, console: { _, _ in })
            guard channel === created else { throw RuntimeError.stopped }
            state = .ready
            return transcript.events[0].payload
        } catch {
            let detail = starting?.startupLog().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let starting, channel === starting {
                try? await Task.detached { try starting.close() }.value
                channel = nil; state = .crashed
            } else if starting == nil { state = .crashed }
            if !detail.isEmpty { throw RuntimeError.protocolViolation(L10n.string("R启动失败：") + detail) }
            throw error
        }
    }

    func evaluate(_ request: EvaluationRequest, event: @escaping @Sendable (RuntimeEnvelope) -> Void = { _ in },
                  console: @escaping @Sendable (String, Data) -> Void = { _, _ in }) async throws -> RuntimeTranscript {
        if let completionFlight { _ = try? await completionFlight.value }
        guard state == .ready, let channel else {
            if state == .uncertain || state == .interrupting { throw RuntimeError.uncertain }
            if inFlight != nil { throw RuntimeError.busy }
            throw RuntimeError.stopped
        }
        guard DocumentRevision(text: request.source).rawValue == request.sourceHash else { throw RuntimeError.staleSource }
        let command = RuntimeCommand(sessionID: channel.sessionID, requestID: UUID(), taskID: request.taskID, kind: "evaluate",
            cellID: request.cellID, sourceHash: request.sourceHash, source: request.source, mode: request.mode.rawValue, plot: request.plot,
            continueOnError: request.continueOnError)
        guard try JSONEncoder().encode(command).count + 1 <= ResponseFrameDecoder.maximumFrameBytes else {
            throw RuntimeError.invalidFrame(L10n.string("代码块超过 1 MiB 命令上限，未提交执行"))
        }
        return try await perform(command, channel: channel, event: event, console: console)
    }

    func inspect(_ request: NotebookInspectorRequest, event: @escaping @Sendable (RuntimeEnvelope) -> Void = { _ in },
                 console: @escaping @Sendable (String, Data) -> Void = { _, _ in }) async throws -> RuntimeTranscript {
        guard request.isValid else { throw RuntimeError.invalidFrame(L10n.string("面板请求无效")) }
        if request.operation != .completion, let completionFlight { _ = try? await completionFlight.value }
        guard state == .ready, let channel else {
            if state == .uncertain || state == .interrupting { throw RuntimeError.uncertain }
            if inFlight != nil { throw RuntimeError.busy }
            throw RuntimeError.stopped
        }
        let command = RuntimeCommand(sessionID: channel.sessionID, requestID: UUID(), taskID: UUID(), kind: "inspector", inspector: request)
        return try await perform(command, channel: channel, event: event, console: console)
    }



    /// Bounded metadata uses the existing channel. Execution drains an accepted
    /// metadata exchange first; UI cancellation never interrupts this Worker.
    func completionItems(_ context: String) async -> [RCompletionCandidate] {
        guard state == .ready, inFlight == nil, completionFlight == nil,
              context.utf8.count <= 512 else { return [] }
        let task = Task { try await self.inspect(.init(operation: .completion, name: context)) }
        completionFlight = task
        defer { completionFlight = nil }
        guard let transcript = try? await task.value else { return [] }
        return transcript.events.first(where: { $0.kind == "inspector_result" })?.payload.completions ?? []
    }

    private func perform(_ command: RuntimeCommand, channel: RProcessChannel,
                         event: @escaping @Sendable (RuntimeEnvelope) -> Void,
                         console: @escaping @Sendable (String, Data) -> Void) async throws -> RuntimeTranscript {
        state = .busy(taskID: command.taskID)
        do {
            let transcript = try await exchange(command, channel: channel, timeout: taskTimeout, event: event, console: console)
            guard self.channel === channel else { throw RuntimeError.stopped }
            if state == .interrupting || transcript.events.last?.payload.uncertain == true {
                state = .uncertain
                channel.killWorker()
            }
            else { state = .ready }
            return transcript
        } catch {
            if self.channel === channel {
                state = state == .interrupting || state == .uncertain ? .uncertain : .crashed
                channel.killWorker()
            }
            throw error
        }
    }

    func interrupt() async {
        guard inFlight != nil, let channel, state != .starting else { return }
        state = .interrupting
        channel.signalInterrupt()
        let session = channel.sessionID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.finishUnresponsiveInterrupt(session)
        }
    }
    private func finishUnresponsiveInterrupt(_ session: UUID) {
        guard channel?.sessionID == session, state == .interrupting else { return }
        state = .uncertain
        channel?.killWorker()
    }

    func stop() async throws {
        guard !isStopping else { return }
        guard let closing = channel else {
            state = .notStarted; sessionID = nil; resourceDirectory = nil; processID = nil
            return
        }
        isStopping = true
        defer { isStopping = false }
        let graceful = state == .ready && inFlight == nil
        channel = nil
        if graceful {
            let shutdown = RuntimeCommand(sessionID: closing.sessionID, requestID: UUID(), taskID: UUID(), kind: "shutdown")
            _ = try? await exchange(shutdown, channel: closing, timeout: 2, event: { _ in }, console: { _, _ in })
        } else {
            closing.killWorker()
            if let inFlight { _ = try? await inFlight.value }
        }
        do { try await Task.detached { try closing.close() }.value }
        catch { channel = closing; state = .crashed; throw error }
        state = .notStarted
        sessionID = nil; resourceDirectory = nil; processID = nil
    }

    private func exchange(_ command: RuntimeCommand, channel: RProcessChannel, timeout: TimeInterval,
                          event: @escaping @Sendable (RuntimeEnvelope) -> Void,
                          console: @escaping @Sendable (String, Data) -> Void) async throws -> RuntimeTranscript {
        guard inFlight == nil else { throw RuntimeError.busy }
        let task = Task.detached(priority: .userInitiated) { try channel.exchange(command, timeout: timeout, event: event, console: console) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
