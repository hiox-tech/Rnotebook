import Darwin
import Foundation

private func runtimeTrace(_ message: String) {
    #if DEBUG
    if ProcessInfo.processInfo.environment["KAIL_RUNTIME_TRACE"] == "1" {
        FileHandle.standardError.write(Data(("[R lifecycle] " + message + "\n").utf8))
    }
    #endif
}

private final class ProcessTermination: @unchecked Sendable {
    private let condition = NSCondition()
    private var exited = false
    var isRunning: Bool { condition.lock(); defer { condition.unlock() }; return !exited }
    func markExited() { condition.lock(); exited = true; condition.broadcast(); condition.unlock() }
    func wait(seconds: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while !exited { if !condition.wait(until: deadline) { return exited } }
        return true
    }
}

/// One process and its owned file descriptors. Only exchange runs on the I/O
/// task; interrupt/kill only signal the immutable PID. Close follows task exit.
final class RProcessChannel: @unchecked Sendable {
    let sessionID: UUID
    let rootURL: URL
    let resourceURL: URL
    var isRunning: Bool { termination.isRunning }
    private let cacheLease: NotebookCacheLease
    let pid: Int32
    private let input: Pipe
    private let output: Pipe
    private let errorOutput: Pipe
    private let fifo: Int32
    private var decoder = ResponseFrameDecoder()
    private var sawResponse = false
    private let consoleDrain: ConsoleDrain
    private var closed = false
    private let termination: ProcessTermination
    private let ownsProcessGroup: Bool

    init(executable: URL, worker: URL, project: URL, library: URL? = nil, temporaryRoot: URL? = nil) throws {
        let store = temporaryRoot.map { NotebookCacheStore(root: $0.appendingPathComponent("RnotebookCache")) } ?? NotebookCacheStore()
        let lease = try store.create(.sessions)
        let session = lease.id, root = lease.directory
        var successful = false
        defer { if !successful { try? lease.finish() } }
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fifoURL = root.appendingPathComponent("response.fifo")
        guard mkfifo(fifoURL.path, 0o600) == 0 else { throw RuntimeError.io("mkfifo", errno) }
        var info = stat()
        guard lstat(fifoURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw RuntimeError.protocolViolation(L10n.string("FIFO 类型、所有者或权限错误")) }
        let responseFD = open(fifoURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard responseFD >= 0 else { throw RuntimeError.io("open FIFO", errno) }
        defer { if !successful { Darwin.close(responseFD) } }
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        let termination = ProcessTermination()
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("font-cache").path
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        environment["TMPDIR"] = temporary.path
        environment["KAIL_PARENT_PID"] = String(getpid())
        environment = try NotebookLibrary.environment(environment, library: library, rscript: executable)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw RuntimeError.io("spawn init", errno) }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let inheritedLock = try lease.inheritLock(in: &actions)
        defer { Darwin.close(inheritedLock) }
        var codes = [posix_spawn_file_actions_adddup2(&actions, stdinPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO),
                     posix_spawn_file_actions_addchdir_np(&actions, project.path),
                     posix_spawnattr_setpgroup(&attributes, 0)]
        var mask = sigset_t(); sigemptyset(&mask)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGCHLD] { sigaddset(&defaults, signal) }
        codes += [posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults),
                  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))]
        if let code = codes.first(where: { $0 != 0 }) { throw RuntimeError.io("spawn setup", code) }
        let argv = [executable.path, "--vanilla", worker.path, fifoURL.path, session.uuidString, resources.path, project.path].map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&child, executable.path, &actions, &attributes,
                UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
        } }
        guard code == 0 else { throw RuntimeError.io("spawn R", code) }
        let launched = child
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(launched, &status, 0) < 0 && errno == EINTR {}
            termination.markExited()
        }
        ownsProcessGroup = true
        runtimeTrace("launched \(child)")
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        for handle in [stdinPipe.fileHandleForWriting, stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading] {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        sessionID = session; rootURL = root; resourceURL = resources; cacheLease = lease; pid = child
        input = stdinPipe; output = stdoutPipe; errorOutput = stderrPipe; fifo = responseFD
        self.termination = termination
        consoleDrain = ConsoleDrain(stdout: stdoutPipe.fileHandleForReading.fileDescriptor, stderr: stderrPipe.fileHandleForReading.fileDescriptor)
        successful = true
    }

    func exchange(_ command: RuntimeCommand, timeout: TimeInterval,
                  event: @Sendable (RuntimeEnvelope) -> Void,
                  console: @escaping @Sendable (String, Data) -> Void) throws -> RuntimeTranscript {
        guard !closed else { throw RuntimeError.stopped }
        runtimeTrace("exchange " + command.kind + " \(pid)")
        let encoded = try JSONEncoder().encode(command)
        guard encoded.count + 1 <= ResponseFrameDecoder.maximumFrameBytes else { throw RuntimeError.invalidFrame(L10n.string("命令超过 1 MiB")) }
        var commandBytes = encoded; commandBytes.append(10)
        var written = 0
        var validator = ResponseValidator(command: command)
        var events: [RuntimeEnvelope] = []
        var responseBytes = 0
        consoleDrain.begin(console)
        defer { consoleDrain.end() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = [UInt8](repeating: 0, count: 65536)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptors = [
                pollfd(fd: fifo, events: Int16(POLLIN), revents: 0),
                pollfd(fd: written < commandBytes.count ? input.fileHandleForWriting.fileDescriptor : -1, events: Int16(POLLOUT), revents: 0)
            ]
            let count = poll(&descriptors, nfds_t(descriptors.count), 50)
            if count < 0 { if errno == EINTR { continue }; throw RuntimeError.io("poll", errno) }
            if descriptors[1].revents & Int16(POLLOUT) != 0 {
                let result = commandBytes.withUnsafeBytes { bytes in
                    Darwin.write(descriptors[1].fd, bytes.baseAddress!.advanced(by: written), min(65536, bytes.count - written))
                }
                if result > 0 { written += result }
                else if result < 0 && errno != EAGAIN && errno != EINTR { throw RuntimeError.io("stdin write", errno) }
            }
            // On this macOS FIFO EOF can return no poll revents at all. Probe
            // the nonblocking fd after the first writer has produced a frame.
            if descriptors[0].revents != 0 || sawResponse {
                if descriptors[0].revents & Int16(POLLNVAL | POLLERR) != 0 { throw RuntimeError.disconnected }
                let received = Darwin.read(fifo, &buffer, buffer.count)
                if received < 0 {
                    if errno == EAGAIN || errno == EINTR {
                        if !isRunning { try decoder.finish(); throw RuntimeError.disconnected }
                        continue
                    }
                    throw RuntimeError.io("read", errno)
                }
                if received == 0 {
                    if sawResponse { try decoder.finish(); throw RuntimeError.disconnected }
                    usleep(5000) // Initial FIFO has no writer yet; avoid a HUP spin.
                    continue
                }
                let bytes = Data(buffer.prefix(received))
                    sawResponse = true
                    responseBytes += bytes.count
                    guard responseBytes <= 4_194_304 else { throw RuntimeError.protocolViolation(L10n.string("单任务响应超过 4 MiB")) }
                    for envelope in try decoder.feed(bytes) {
                        try validator.accept(envelope)
                        events.append(envelope)
                        guard events.count <= 4096 else { throw RuntimeError.protocolViolation(L10n.string("事件数量超限")) }
                        event(envelope)
                    }
            }
            if validator.terminal {
                runtimeTrace("terminal " + command.kind + " \(pid)")
                guard !decoder.hasPartialFrame else { throw RuntimeError.protocolViolation(L10n.string("终态后还有不完整响应")) }
                let logs = consoleDrain.snapshot()
                return RuntimeTranscript(sessionID: sessionID, events: events, stdout: logs.stdout, stderr: logs.stderr,
                    stdoutTruncated: logs.stdoutTruncated, stderrTruncated: logs.stderrTruncated)
            }
            if !isRunning { try decoder.finish(); throw RuntimeError.disconnected }
        }
        throw RuntimeError.timedOut(command.kind == "hello" ? L10n.string("启动握手") : L10n.string("任务响应"))
    }

    func startupLog() -> String { String(decoding: consoleDrain.snapshot().stderr.suffix(8192), as: UTF8.self) }

    private func signalSession(_ signal: Int32) {
        // Spawn creates this child in its own process group. Include
        // package-install subprocesses, but never signal the app's own group.
        let running = isRunning
        let absent = !running && kill(pid, 0) == -1 && errno == ESRCH
        if ownsProcessGroup && (running || absent) { _ = kill(-pid, signal) }
        else if running { _ = kill(pid, signal) }
    }
    func signalInterrupt() { signalSession(SIGINT) }
    func killWorker() { signalSession(SIGKILL) }
    func close() throws {
        guard !closed else { return }
        runtimeTrace("close \(pid)")
        killWorker()
        runtimeTrace("wait \(pid)")
        // Foundation's waitUntilExit can stall its caller's RunLoop when
        // successive workers are launched/closed on different executor threads.
        // Its termination callback runs after reaping and needs no caller RunLoop.
        guard termination.wait(seconds: 3) else { throw RuntimeError.timedOut(L10n.string("进程退出")) }
        runtimeTrace("reaped \(pid)")
        try consoleDrain.stop()
        closed = true
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errorOutput.fileHandleForReading.close()
        Darwin.close(fifo)
        try? cacheLease.finish()
    }
    deinit {
        if !closed {
            killWorker()
            let exited = termination.wait(seconds: 3)
            try? consoleDrain.stop()
            Darwin.close(fifo)
            if exited { try? cacheLease.finish() }
        }
    }
}
