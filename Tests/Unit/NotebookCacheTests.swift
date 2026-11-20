import Darwin
import Foundation
import XCTest
@testable import Rnotebook

final class NotebookCacheTests: XCTestCase {
    func testExistingSystemCacheRootBecomesPrivateWithoutChangingLegacyContents() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(store.root.path, 0o755), 0)
        let legacy = store.root.appendingPathComponent("fsCachedData")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(legacy.path, 0o755), 0)
        let database = store.root.appendingPathComponent("Cache.db")
        try Data("existing URL cache".utf8).write(to: database)
        let attributes = try FileManager.default.attributesOfItem(atPath: database.path)
        // Launch/manual sweep must also accept the pre-existing URL cache root.
        XCTAssertEqual(try store.sweep(removeAllFinished: true).removed, 0)
        for kind in NotebookCacheStore.Kind.allCases {
            let lease = try store.create(kind)
            try lease.finish()
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.root.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: legacy.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try Data(contentsOf: database), Data("existing URL cache".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: database.path)[.posixPermissions] as? Int,
                       attributes[.posixPermissions] as? Int)
    }
    func testRootPermissionRepairRejectsSymlinkAndDoesNotChangeTargetPermissions() throws {
        let store = try store()
        let outside = store.root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(outside.path, 0o755), 0)
        try FileManager.default.createSymbolicLink(at: store.root, withDestinationURL: outside)
        XCTAssertThrowsError(try store.create(.sessions))
        XCTAssertThrowsError(try store.sweep())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testRootRepairDoesNotAdoptPermissiveTaskCategoryOrUnknownContent() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(store.root.path, 0o755), 0)
        let category = store.root.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(category.path, 0o755), 0)
        let unknown = category.appendingPathComponent("user.qmd")
        try Data("keep".utf8).write(to: unknown)
        XCTAssertThrowsError(try store.create(.sessions))
        XCTAssertEqual(try store.sweep(removeAllFinished: true).removed, 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: category.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "keep")
    }
    private func store() throws -> NotebookCacheStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-cache-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return NotebookCacheStore(root: root.appendingPathComponent("Caches"))
    }
    func testActiveTasksSurviveExpirationCapacityAndManualCleanupThenFinishImmediately() throws {
        let store = try store()
        for kind in NotebookCacheStore.Kind.allCases {
            let lease = try store.create(kind, now: .distantPast)
            let payload = lease.directory.appendingPathComponent("payload")
            try Data(repeating: 3, count: 1024).write(to: payload)
            XCTAssertEqual(try store.sweep(maximumBytes: 0, failureLifetime: 0, removeAllFinished: true).removed, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
            try lease.finish()
            XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
        }
    }
    func testFailedExportsKeepOnlyDiagnosticsExpireAfterSevenDaysAndRespectCapacityOrder() throws {
        let store = try store(), now = Date()
        let first = try store.create(.exports), second = try store.create(.exports)
        for lease in [first, second] {
            for name in ["record.json", "stdout.log", "stderr.log", "metadata.json", "source-copy.qmd"] {
                try Data(repeating: 65, count: 2048).write(to: lease.directory.appendingPathComponent(name))
            }
            let output = lease.directory.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try Data(repeating: 65, count: 8192).write(to: output.appendingPathComponent("report.pdf"))
        }
        try first.finish(failed: true, now: now.addingTimeInterval(-100))
        try second.finish(failed: true, now: now)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: first.directory.path)),
                       ["owner.json", "lease.lock", "record.json", "stdout.log", "stderr.log"])
        XCTAssertEqual(try store.sweep(now: now).removed, 0)
        let limit: Int64 = 8000
        XCTAssertEqual(try store.sweep(now: now, maximumBytes: limit).removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
        XCTAssertEqual(try store.sweep(now: now.addingTimeInterval(NotebookCacheStore.failureLifetime + 1)).removed, 1)
    }
    func testAbandonedTasksAreRecoveredButUnknownDirectoriesAndRecoveryDataArePreserved() throws {
        let store = try store()
        var lease: NotebookCacheLease? = try store.create(.sessions)
        let abandoned = try XCTUnwrap(lease).directory
        try Data("cached".utf8).write(to: abandoned.appendingPathComponent("plot.png"))
        lease = nil
        let unknown = store.root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("user".utf8).write(to: unknown.appendingPathComponent("user.qmd"))
        let recovery = store.root.deletingLastPathComponent().appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        try Data("unsaved".utf8).write(to: recovery.appendingPathComponent("draft.qmd"))
        XCTAssertEqual(try store.sweep(removeAllFinished: true).removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try String(contentsOf: unknown.appendingPathComponent("user.qmd"), encoding: .utf8), "user")
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("draft.qmd"), encoding: .utf8), "unsaved")
    }
    func testSymlinkedRootTaskAndPayloadNeverDeleteExternalFiles() throws {
        let store = try store(), lease = try store.create(.sessions)
        let outside = store.root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let user = outside.appendingPathComponent("data.csv")
        try Data("keep".utf8).write(to: user)
        try FileManager.default.createSymbolicLink(at: lease.directory.appendingPathComponent("escape"), withDestinationURL: outside)
        try lease.finish()
        XCTAssertEqual(try String(contentsOf: user, encoding: .utf8), "keep")
        let taskLink = store.root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: taskLink, withDestinationURL: outside)
        XCTAssertEqual(try store.sweep(removeAllFinished: true).removed, 0)
        let alias = store.root.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store.root)
        XCTAssertThrowsError(try NotebookCacheStore(root: alias).sweep(removeAllFinished: true))
        XCTAssertEqual(try String(contentsOf: user, encoding: .utf8), "keep")
    }
    func testStagedSourceCleanupRequiresExactTaskNameAndUnmodifiedBytes() throws {
        let store = try store()
        for modified in [false, true] {
            var lease: NotebookCacheLease? = try store.create(.exports)
            let source = store.root.deletingLastPathComponent().appendingPathComponent("rnotebook-render-" + lease!.id.uuidString + ".qmd")
            let bytes = Data("preview source".utf8)
            try bytes.write(to: source)
            try lease!.recordStagedSource(source, source: bytes)
            let artifacts = source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_files")
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
            try Data("generated".utf8).write(to: artifacts.appendingPathComponent("plot.png"))
            if modified { try Data("user changed this".utf8).write(to: source) }
            lease = nil
            _ = try store.sweep(removeAllFinished: true)
            XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), modified)
            XCTAssertEqual(FileManager.default.fileExists(atPath: artifacts.path), modified)
        }
    }
    func testChildInheritedLockProtectsCacheAfterParentLeaseIsReleased() throws {
        try inheritedLockScenario(finishBeforeExit: false)
    }
    func testFinishCannotDeleteCacheWhileAChildStillHoldsTheInheritedLock() throws {
        try inheritedLockScenario(finishBeforeExit: true)
    }
    private func inheritedLockScenario(finishBeforeExit: Bool) throws {
        let store = try store()
        var lease: NotebookCacheLease? = try store.create(.sessions)
        let directory = lease!.directory
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let inherited = try lease!.inheritLock(in: &actions)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let words: [String] = ["/bin/sleep", "20"]
        let args = words.map { strdup($0) } + [nil]
        defer { for arg in args { free(arg) } }
        var pid: pid_t = 0
        let result = args.withUnsafeBufferPointer { argv in
            posix_spawn(&pid, "/bin/sleep", &actions, &attributes, UnsafeMutablePointer(mutating: argv.baseAddress!), nil)
        }
        close(inherited)
        XCTAssertEqual(result, 0)
        guard result == 0 else { return }
        var reaped = false
        defer { if !reaped { kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) } }
        if finishBeforeExit { try lease!.finish() }
        lease = nil
        XCTAssertEqual(try store.sweep(maximumBytes: 0, removeAllFinished: true).removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        kill(pid, SIGTERM); var status: Int32 = 0; waitpid(pid, &status, 0); reaped = true
        XCTAssertEqual(try store.sweep().removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
