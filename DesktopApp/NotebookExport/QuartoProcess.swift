import Darwin
import Foundation

struct QuartoProcessOutput: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let truncated: Bool
    let cancelled: Bool
    let timedOut: Bool
}

/// Dedicated process group for Quarto and its R/pandoc children. Never signals
/// the interactive Worker. Pipes continue draining after their retained limit.
final class QuartoProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var started = false
    var isCancelled: Bool { lock.withLock { cancellationRequested } }
    func cancel() { lock.withLock { cancellationRequested = true } }

    func run(executable: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval, input: Data? = nil, cacheLease: NotebookCacheLease? = nil,
             log: @escaping @Sendable (Int, Data) -> Void = { _, _ in }) async throws -> QuartoProcessOutput {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                try runSync(executable: executable, arguments: arguments, directory: directory, environment: environment, timeout: timeout, input: input, cacheLease: cacheLease, log: log)
            }.value
        } onCancel: { self.cancel() }
    }
    private func runSync(executable: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval, input: Data?, cacheLease: NotebookCacheLease?,
                         log: @Sendable (Int, Data) -> Void) throws -> QuartoProcessOutput {
        guard timeout.isFinite, timeout > 0, lock.withLock({ if started { return false }; started = true; return true }) else { throw QuartoExportError.invalidRequest }
        if isCancelled { return QuartoProcessOutput(exitCode: -1, stdout: Data(), stderr: Data(), truncated: false, cancelled: true, timedOut: false) }
        let inputLease = cacheLease == nil && input != nil ? try NotebookCacheStore().create(.completion) : nil
        let taskLease = cacheLease ?? inputLease
        defer { try? inputLease?.finish() }
        var taskEnvironment = environment
        if let taskLease {
            let temporary = taskLease.directory.appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            taskEnvironment["TMPDIR"] = temporary.path
        }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw QuartoExportError.process(errno) }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw QuartoExportError.process(errno) }
        defer { for fd in out + err { close(fd) } }
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        for fd in [out[0], err[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw QuartoExportError.process(errno) }
        }
        let inputURL = input.map { _ in taskLease!.directory.appendingPathComponent("standard-input") }
        if let input, let inputURL { try input.write(to: inputURL, options: [.atomic]) }
        defer { if let inputURL { try? FileManager.default.removeItem(at: inputURL) } }
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attr) == 0 else { throw QuartoExportError.invalidRequest }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        let inheritedLock = try taskLease?.inheritLock(in: &actions)
        defer { if let inheritedLock { close(inheritedLock) } }
        var codes = [posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, inputURL?.path ?? "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO),
                     posix_spawn_file_actions_addchdir_np(&actions, directory.path),
                     posix_spawnattr_setpgroup(&attr, 0),
                     posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))]
        for fd in out + err { codes.append(posix_spawn_file_actions_addclose(&actions, fd)) }
        if let code = codes.first(where: { $0 != 0 }) { throw QuartoExportError.process(code) }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = taskEnvironment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, executable.path, &actions, &attr, UnsafeMutablePointer(mutating: arguments.baseAddress!), UnsafeMutablePointer(mutating: variables.baseAddress!))
            }
        }
        guard code == 0 else { throw QuartoExportError.process(code) }
        var reaped = false
        var pidCleanupStatus: Int32 = 0
        defer {
            kill(-pid, SIGKILL)
            if !reaped {
                kill(pid, SIGKILL)
                while waitpid(pid, &pidCleanupStatus, 0) < 0 && errno == EINTR {}
            }
        }
        close(out[1]); out[1] = -1; close(err[1]); err[1] = -1
        var polls = [out[0], err[0]].map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
        var logs = [Data(), Data()], truncated = false, status: Int32 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stopAt: TimeInterval?, exitedAt: TimeInterval?
        var timedOut = false, cancelled = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true; exitedAt = now }
                else if result < 0 && errno != EINTR { throw QuartoExportError.process(errno) }
            }
            if stopAt == nil && (isCancelled || now >= deadline) {
                cancelled = isCancelled; timedOut = !cancelled; stopAt = now
                kill(-pid, SIGTERM)
                if !reaped { kill(pid, SIGTERM) }
            }
            if let stopAt, now >= stopAt + 0.3 { kill(-pid, SIGKILL); if !reaped { kill(pid, SIGKILL) } }
            if reaped && polls.allSatisfy({ $0.fd < 0 }) { break }
            // A child retaining pipes after its parent exits is still owned by
            // this render group; terminate it rather than leak a background R.
            if let exitedAt, stopAt == nil, now >= exitedAt + 0.5 { kill(-pid, SIGTERM); stopAt = now }
            if let stopAt, now >= stopAt + 1, reaped { break }
            let ready = polls.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 25) }
            if ready < 0 && errno != EINTR { throw QuartoExportError.process(errno) }
            for index in polls.indices where polls[index].fd >= 0 && polls[index].revents != 0 {
                for _ in 0..<16 {
                    let count = read(polls[index].fd, &buffer, buffer.count)
                    if count > 0 {
                        let retained = min(count, max(0, 1_048_576 - logs[index].count))
                        if retained > 0 { let data = Data(buffer.prefix(retained)); logs[index].append(data); log(index, data) }
                        if retained < count { truncated = true }
                    } else if count == 0 { polls[index].fd = -1; break }
                    else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
                    else { throw QuartoExportError.process(errno) }
                }
            }
        }
        // Also clean descendants that closed their output descriptors early.
        kill(-pid, SIGKILL)
        if !reaped { _ = waitpid(pid, &status, 0) }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return QuartoProcessOutput(exitCode: exitCode, stdout: logs[0], stderr: logs[1], truncated: truncated, cancelled: cancelled, timedOut: timedOut)
    }
}
