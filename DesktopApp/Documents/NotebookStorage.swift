import Foundation

enum NotebookStorage {
    static var cacheDirectory: URL {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["RNOTEBOOK_VALIDATION_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Caches")
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-TestCache-" + String(ProcessInfo.processInfo.processIdentifier))
        }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.hiox.Rnotebook", isDirectory: true)
    }
    static var applicationSupport: URL {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["RNOTEBOOK_VALIDATION_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rnotebook", isDirectory: true)
    }
}
