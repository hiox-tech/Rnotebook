import Darwin
import Foundation

struct GraphicResource: Identifiable, Sendable {
    let id: String
    let taskID: UUID
    let data: Data
    let checksum: DocumentRevision
}

/// A resource is resolved relative to a verified, session-owned directory. It
/// never accepts a file URL or a path from an event.
struct ResourceService: Sendable {
    let rootURL: URL
    private let device: dev_t
    private let inode: ino_t

    init(rootURL: URL) throws {
        var info = stat()
        guard lstat(rootURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw RuntimeError.resource(L10n.string("资源目录不属于当前会话")) }
        self.rootURL = rootURL; device = info.st_dev; inode = info.st_ino
    }

    func resolve(_ event: RuntimeEnvelope) throws -> GraphicResource {
        guard event.kind == "display_image", let id = event.payload.resourceID, validID(id, task: event.taskID),
              event.payload.mime == "image/png", let expected = event.payload.sizeBytes,
              expected > 0, expected <= 16_777_216 else { throw RuntimeError.resource(L10n.string("图形句柄无效")) }
        let directory = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw RuntimeError.resource(L10n.string("会话资源已失效")) }
        defer { Darwin.close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_dev == device, parent.st_ino == inode else { throw RuntimeError.resource(L10n.string("资源目录已被替换")) }
        let fd = openat(directory, id + ".png", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeError.resource(L10n.string("资源不存在或为符号链接")) }
        defer { Darwin.close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_size == expected else { throw RuntimeError.resource(L10n.string("资源类型、所有者或大小不符")) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= expected {
            let count = Darwin.read(fd, &buffer, min(buffer.count, expected + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw RuntimeError.resource(L10n.string("读取失败")) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == expected, data.starts(with: [137,80,78,71,13,10,26,10]), data.count >= 24 else { throw RuntimeError.resource(L10n.string("PNG 内容或长度错误")) }
        let width = data[16..<20].reduce(0) { ($0 << 8) | Int($1) }, height = data[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        guard (1...8192).contains(width), (1...8192).contains(height) else { throw RuntimeError.resource(L10n.string("图像尺寸超限")) }
        return GraphicResource(id: id, taskID: event.taskID, data: data, checksum: DocumentRevision(data: data))
    }

    func validID(_ id: String, task: UUID) -> Bool { Self.validResourceID(id, task: task) }
    static func validResourceID(_ id: String, task: UUID) -> Bool {
        let prefix = task.uuidString + "-"
        return id.hasPrefix(prefix) && id.count == prefix.count + 6 && id.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
    }
    func removeResources(except tasks: Set<UUID>) {
        let directory = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_dev == device, info.st_ino == inode else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" {
            let id = file.deletingPathExtension().lastPathComponent
            if let task = UUID(uuidString: String(id.prefix(36))), validID(id, task: task), !tasks.contains(task) { _ = unlinkat(directory, file.lastPathComponent, 0) }
        }
    }
}
