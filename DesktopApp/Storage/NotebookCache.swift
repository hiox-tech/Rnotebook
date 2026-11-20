import CryptoKit
import Darwin
import Foundation

/// Only this namespace and manifest format authorize deletion. No legacy-prefix sweep.
struct NotebookCacheStore: Sendable {
    enum Kind: String, Codable, CaseIterable { case sessions = "Sessions", exports = "Exports", completion = "Completion" }
    struct Manifest: Codable {
        var schema = 1
        var application = "org.hiox.Rnotebook.Cache"
        let id: UUID
        let kind: Kind
        let created: Date
        var finished: Date?
        var failed = false
        var stagedSource: URL?
        var stagedHash: String?
    }
    struct SweepResult: Sendable { var removed = 0; var bytes: Int64 = 0 }
    let root: URL
    init(root: URL = NotebookStorage.cacheDirectory) { self.root = root.standardizedFileURL }
    static let failureLifetime: TimeInterval = 7 * 24 * 3600
    static let maximumBytes: Int64 = 500 * 1024 * 1024

    func create(_ kind: Kind, now: Date = Date()) throws -> NotebookCacheLease {
        let rootFD = try openRoot(create: true); defer { close(rootFD) }
        let kindFD = try CacheFiles.directory(at: rootFD, name: kind.rawValue, create: true, privateOnly: true); defer { close(kindFD) }
        let id = UUID(), name = id.uuidString
        guard mkdirat(kindFD, name, 0o700) == 0 else { throw CacheFiles.error() }
        let directoryFD = try CacheFiles.directory(at: kindFD, name: name, privateOnly: true)
        let lockFD = openat(directoryFD, "lease.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { close(directoryFD); throw CacheFiles.error() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); close(directoryFD); throw CacheFiles.error() }
        let manifest = Manifest(id: id, kind: kind, created: now)
        do { try CacheFiles.write(manifest, at: directoryFD) }
        catch { close(lockFD); close(directoryFD); throw error }
        return NotebookCacheLease(store: self, manifest: manifest, directoryFD: directoryFD, lockFD: lockFD)
    }

    /// Active leases (including inherited locks in child processes) are never eligible.
    func sweep(now: Date = Date(), maximumBytes: Int64 = Self.maximumBytes,
               failureLifetime: TimeInterval = Self.failureLifetime, removeAllFinished: Bool = false) throws -> SweepResult {
        guard FileManager.default.fileExists(atPath: root.path) else { return .init() }
        let rootFD = try openRoot(); defer { close(rootFD) }
        var retained: [(Kind, String, Date, Int64)] = [], result = SweepResult()
        for kind in Kind.allCases {
            guard let kindFD = try? CacheFiles.directory(at: rootFD, name: kind.rawValue, privateOnly: true) else { continue }
            defer { close(kindFD) }
            for name in CacheFiles.names(at: kindFD) where UUID(uuidString: name) != nil {
                guard let fd = try? CacheFiles.directory(at: kindFD, name: name, privateOnly: true) else { continue }
                defer { close(fd) }
                let lockFD = openat(fd, "lease.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard lockFD >= 0 else { continue }
                defer { close(lockFD) }
                guard CacheFiles.regularOwned(lockFD), flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { continue }
                guard var manifest = try? CacheFiles.readManifest(at: fd), valid(manifest, kind: kind, name: name) else { continue }
                // An unlocked unfinished task is an abandoned task, not an active session.
                if manifest.finished == nil {
                    CacheFiles.cleanStagedSource(manifest)
                    if kind == .exports {
                        try CacheFiles.trimFailure(at: fd)
                        manifest.failed = true
                        // Give interrupted exports a useful retention window from their last work.
                        manifest.finished = manifest.created
                        try CacheFiles.write(manifest, at: fd)
                    }
                }
                let bytes = CacheFiles.size(at: fd)
                if kind != .exports || !manifest.failed || removeAllFinished ||
                    now.timeIntervalSince(manifest.finished ?? manifest.created) >= failureLifetime {
                    try CacheFiles.removeContents(at: fd)
                    if unlinkat(kindFD, name, AT_REMOVEDIR) == 0 { result.removed += 1; result.bytes += bytes }
                } else { retained.append((kind, name, manifest.finished ?? manifest.created, bytes)) }
            }
        }
        var retainedBytes = retained.reduce(Int64(0)) { $0 + $1.3 }
        for (kind, name, _, _) in retained.sorted(by: { $0.2 < $1.2 }) where retainedBytes > maximumBytes {
            // Reacquire/verify each candidate: another process may have changed it since enumeration.
            let kindFD = try CacheFiles.directory(at: rootFD, name: kind.rawValue, privateOnly: true); defer { close(kindFD) }
            guard let fd = try? CacheFiles.directory(at: kindFD, name: name, privateOnly: true) else { continue }
            defer { close(fd) }
            let lockFD = openat(fd, "lease.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard lockFD >= 0 else { continue }; defer { close(lockFD) }
            guard CacheFiles.regularOwned(lockFD), flock(lockFD, LOCK_EX | LOCK_NB) == 0,
                  let manifest = try? CacheFiles.readManifest(at: fd), valid(manifest, kind: kind, name: name),
                  manifest.finished != nil else { continue }
            let size = CacheFiles.size(at: fd)
            try CacheFiles.removeContents(at: fd)
            if unlinkat(kindFD, name, AT_REMOVEDIR) == 0 { retainedBytes -= size; result.removed += 1; result.bytes += size }
        }
        return result
    }

    fileprivate func valid(_ manifest: Manifest, kind: Kind, name: String) -> Bool {
        manifest.schema == 1 && manifest.application == "org.hiox.Rnotebook.Cache" &&
            manifest.kind == kind && manifest.id.uuidString == name
    }
    fileprivate func openRoot(create: Bool = false) throws -> Int32 {
        // Resolve the system's parent aliases (/var -> /private/var), never a cache-root link.
        let parent = root.deletingLastPathComponent().resolvingSymlinksInPath()
        if create { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw CacheFiles.error() }; defer { close(parentFD) }
        // URLSession/WebKit may already have created this app's standard cache
        // root with 0755. Secure that owned directory through its verified fd;
        // never change permissions recursively or adopt unknown task folders.
        return try CacheFiles.directory(at: parentFD, name: root.lastPathComponent, create: create, privateOnly: true, makePrivate: true)
    }
}

final class NotebookCacheLease: @unchecked Sendable {
    let id: UUID
    let directory: URL
    private let store: NotebookCacheStore
    private let mutex = NSLock()
    private var manifest: NotebookCacheStore.Manifest
    private let directoryFD: Int32
    private var lockFD: Int32
    private var finished = false

    fileprivate init(store: NotebookCacheStore, manifest: NotebookCacheStore.Manifest, directoryFD: Int32, lockFD: Int32) {
        self.store = store; self.manifest = manifest; self.directoryFD = directoryFD; self.lockFD = lockFD
        id = manifest.id
        directory = store.root.appendingPathComponent(manifest.kind.rawValue).appendingPathComponent(id.uuidString)
    }
    deinit { if lockFD >= 0 { close(lockFD) }; close(directoryFD) }

    /// A distinct dup2 target is whitelisted by POSIX_SPAWN_CLOEXEC_DEFAULT.
    /// The task stays protected if the UI process dies while a child is running.
    func inheritLock(in actions: inout posix_spawn_file_actions_t?) throws -> Int32 {
        try mutex.withLock {
            guard !finished, lockFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let inherited = fcntl(lockFD, F_DUPFD_CLOEXEC, 10)
            guard inherited >= 0 else { throw CacheFiles.error() }
            guard posix_spawn_file_actions_adddup2(&actions, lockFD, inherited) == 0 else { close(inherited); throw CacheFiles.error() }
            return inherited
        }
    }
    func recordStagedSource(_ url: URL, source: Data) throws {
        try mutex.withLock {
            guard !finished, url.lastPathComponent == "rnotebook-render-" + id.uuidString + ".qmd" else { throw CocoaError(.fileWriteInvalidFileName) }
            manifest.stagedSource = url.standardizedFileURL
            manifest.stagedHash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
            try CacheFiles.write(manifest, at: directoryFD)
        }
    }
    func finish(failed: Bool = false, now: Date = Date()) throws {
        try mutex.withLock {
            guard !finished else { return }
            let cleanupLock = openat(directoryFD, "lease.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard cleanupLock >= 0, CacheFiles.regularOwned(cleanupLock) else {
                if cleanupLock >= 0 { close(cleanupLock) }
                throw CocoaError(.fileWriteUnknown)
            }
            defer { close(cleanupLock) }
            // Closing our reference never unlocks a child's inherited reference.
            // Do not clean while any descendant still holds the original lock.
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            guard flock(cleanupLock, LOCK_EX | LOCK_NB) == 0 else { finished = true; return }
            CacheFiles.cleanStagedSource(manifest)
            if failed, manifest.kind == .exports {
                try CacheFiles.trimFailure(at: directoryFD)
                manifest.failed = true; manifest.finished = now
                try CacheFiles.write(manifest, at: directoryFD)
            } else {
                // Keep parent/lease descriptors anchored while deleting; never follow links.
                let rootFD = try store.openRoot(); defer { close(rootFD) }
                let kindFD = try CacheFiles.directory(at: rootFD, name: manifest.kind.rawValue, privateOnly: true); defer { close(kindFD) }
                var expected = stat(), current = stat()
                guard fstat(directoryFD, &expected) == 0,
                      fstatat(kindFD, id.uuidString, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      expected.st_dev == current.st_dev, expected.st_ino == current.st_ino else { throw CocoaError(.fileWriteUnknown) }
                try CacheFiles.removeContents(at: directoryFD)
                guard unlinkat(kindFD, id.uuidString, AT_REMOVEDIR) == 0 else { throw CacheFiles.error() }
            }
            finished = true
        }
    }
}

private enum CacheFiles {
    static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    static func directory(at parent: Int32, name: String, create: Bool = false, privateOnly: Bool = false, makePrivate: Bool = false) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw CocoaError(.fileWriteInvalidFileName) }
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw error() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { close(fd); throw CocoaError(.fileReadNoPermission) }
        if makePrivate, info.st_mode & 0o7777 != 0o700 {
            guard fchmod(fd, 0o700) == 0 else { let failure = error(); close(fd); throw failure }
            guard fstat(fd, &info) == 0 else { let failure = error(); close(fd); throw failure }
        }
        guard !privateOnly || info.st_mode & 0o077 == 0 else { close(fd); throw CocoaError(.fileReadNoPermission) }
        return fd
    }
    static func regularOwned(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
    }
    static func names(at fd: Int32) -> [String] {
        guard let stream = fdopendir(dup(fd)) else { return [] }; defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
    static func readManifest(at fd: Int32) throws -> NotebookCacheStore.Manifest {
        let file = openat(fd, "owner.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw error() }; defer { close(file) }
        var info = stat()
        guard regularOwned(file), fstat(file, &info) == 0, info.st_size <= 32_768 else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        guard count == data.count else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(NotebookCacheStore.Manifest.self, from: data)
    }
    static func write(_ manifest: NotebookCacheStore.Manifest, at fd: Int32) throws {
        let data = try JSONEncoder().encode(manifest)
        let temporary = "owner-" + UUID().uuidString + ".tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw error() }
        defer { close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw error() }; offset += count
            }
        }
        guard renameat(fd, temporary, fd, "owner.json") == 0 else { throw error() }
    }
    static func size(at fd: Int32) -> Int64 {
        names(at: fd).reduce(0) { total, name in
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return total }
            if info.st_mode & S_IFMT == S_IFDIR, let child = try? directory(at: fd, name: name) {
                defer { close(child) }; return total + size(at: child)
            }
            return total + Int64(info.st_size)
        }
    }
    static func removeContents(at fd: Int32, except keep: Set<String> = []) throws {
        for name in names(at: fd) where !keep.contains(name) {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { if errno == ENOENT { continue }; throw error() }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = try directory(at: fd, name: name); defer { close(child) }
                try removeContents(at: child)
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw error() }
            } else { guard unlinkat(fd, name, 0) == 0 else { throw error() } }
        }
    }
    static func trimFailure(at fd: Int32) throws {
        try removeContents(at: fd, except: ["lease.lock", "owner.json", "record.json", "stdout.log", "stderr.log"])
    }
    static func cleanStagedSource(_ manifest: NotebookCacheStore.Manifest) {
        guard let url = manifest.stagedSource, let expected = manifest.stagedHash, url.isFileURL,
              url.lastPathComponent == "rnotebook-render-" + manifest.id.uuidString + ".qmd" else { return }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return }; defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }; defer { close(fd) }
        var before = stat(), after = stat()
        guard regularOwned(fd), fstat(fd, &before) == 0 else { return }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }; if count < 0 { return }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected,
              fstatat(parent, url.lastPathComponent, &after, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino else { return }
        _ = unlinkat(parent, url.lastPathComponent, 0)
        // The same unique stem's known Quarto products were created for this source.
        // Never enumerate the document folder or infer ownership from a generic prefix.
        let stem = url.deletingPathExtension().lastPathComponent
        for suffix in ["_files", "_cache", ".rmarkdown", ".knit.md", ".utf8.md", ".tex", ".log", ".aux", ".out", ".toc", ".typ", ".pdf", ".synctex.gz", ".fls", ".fdb_latexmk"] {
            let name = stem + suffix
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid() else { continue }
            if info.st_mode & S_IFMT == S_IFDIR, let child = try? directory(at: parent, name: name) {
                defer { close(child) }
                if (try? removeContents(at: child)) != nil { _ = unlinkat(parent, name, AT_REMOVEDIR) }
            } else if info.st_mode & S_IFMT == S_IFREG { _ = unlinkat(parent, name, 0) }
        }
    }
}
