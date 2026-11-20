import Foundation
import Darwin

/// Watch both the file and its parent so atomic editor replacements are seen.
@MainActor final class QMDFileWatcher {
    private var file: DispatchSourceFileSystemObject?
    private var parent: DispatchSourceFileSystemObject?
    private let url: URL
    private let notify: @Sendable () -> Void
    init(url: URL, notify: @escaping @Sendable () -> Void) {
        self.url = url; self.notify = notify
        parent = watch(url.deletingLastPathComponent(), mask: [.write, .rename, .delete])
        rearm()
    }
    private func watch(_ url: URL, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        // The owner and its cancellation closure are main-actor isolated.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler(handler: notify)
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }
    func rearm() {
        file?.cancel()
        file = watch(url, mask: [.write, .rename, .delete, .attrib, .revoke])
    }
    func stop() { file?.cancel(); parent?.cancel(); file = nil; parent = nil }
    deinit { file?.cancel(); parent?.cancel() }
}
