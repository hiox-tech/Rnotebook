import Darwin
import Foundation

/// Continuously drains native fd1/fd2, including between requests. These bytes
/// are diagnostic logs, without a claimed ordering relative to Notebook events.
final class ConsoleDrain: @unchecked Sendable {
    struct Snapshot { let stdout: Data; let stderr: Data; let stdoutTruncated: Bool; let stderrTruncated: Bool }
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private let queue = DispatchQueue(label: "KailIVD.console-drain", qos: .utility)
    private var descriptors: [Int32]
    private var logs = [Data(), Data()]
    private var truncated = [false, false]
    private var callback: (@Sendable (String, Data) -> Void)?
    private var stopping = false

    init(stdout: Int32, stderr: Int32) {
        descriptors = [stdout, stderr]
        finished.enter()
        queue.async { [self] in
            defer { finished.leave() }
            while true {
                let state = lock.withLock { (stopping, descriptors) }
                if state.0 { return }
                var polls = state.1.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                _ = poll(&polls, nfds_t(polls.count), 25)
                drainAvailable()
            }
        }
    }
    func begin(_ callback: @escaping @Sendable (String, Data) -> Void) {
        lock.withLock { logs = [Data(), Data()]; truncated = [false, false]; self.callback = callback }
    }
    func snapshot() -> Snapshot {
        drainAvailable()
        return lock.withLock {
            Snapshot(stdout: logs[0], stderr: logs[1], stdoutTruncated: truncated[0], stderrTruncated: truncated[1])
        }
    }
    func end() { lock.withLock { callback = nil } }
    func stop() throws {
        lock.withLock { stopping = true; callback = nil }
        guard finished.wait(timeout: .now() + 1) == .success else { throw RuntimeError.timedOut(L10n.string("日志读取停止")) }
    }
    private func drainAvailable() {
        var deliveries: [(String, Data)] = []
        lock.lock()
        let callback = self.callback
        var buffer = [UInt8](repeating: 0, count: 65536)
        for index in descriptors.indices where descriptors[index] >= 0 {
            // Fair and bounded even if an idle background writer never stops.
            for _ in 0..<16 {
                let received = Darwin.read(descriptors[index], &buffer, buffer.count)
                if received <= 0 {
                    if received == 0 { descriptors[index] = -1 }
                    break
                }
                let retained = min(received, max(0, 65536 - logs[index].count))
                if retained > 0 {
                    let data = Data(buffer.prefix(retained)); logs[index].append(data)
                    if callback != nil { deliveries.append((index == 0 ? "stdout" : "stderr", data)) }
                }
                if retained < received { truncated[index] = true }
            }
        }
        lock.unlock()
        for delivery in deliveries { callback?(delivery.0, delivery.1) }
    }
}
