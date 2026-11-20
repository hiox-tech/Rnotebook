import AppKit
import Foundation

actor InspectorRVersion {
    static let shared = InspectorRVersion()
    private var cache: [String: String] = [:]
    func version(executable: URL?) async -> String? {
        guard let executable else { return nil }
        let modified = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = executable.path + String(modified)
        if let value = cache[key] { return value }
        let value = await Task.detached(priority: .utility) { Self.probe(executable) }.value
        if let value { cache[key] = value }
        return value
    }
    private nonisolated static func probe(_ executable: URL) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-RVersion-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil), let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process(); process.executableURL = executable; process.arguments = ["--version"]
        process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date(timeIntervalSinceNow: 4)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            guard process.terminationStatus == 0, let data = try? Data(contentsOf: output), data.count < 32768 else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            guard let range = text.range(of: #"\b\d+\.\d+\.\d+\b"#, options: .regularExpression) else { return nil }
            return String(text[range])
        } catch { return nil }
    }
}

actor InspectorPackageCatalog {
    static let shared = InspectorPackageCatalog()
    private var cache: [String: [String]] = [:]
    func matches(_ query: String, repository: String) async -> [String] {
        (try? await search(query, repository: repository)) ?? []
    }
    func search(_ query: String, repository: String) async throws -> [String] {
        guard query.count >= 2, let root = URL(string: repository), ["https", "http"].contains(root.scheme),
              root.host != nil, root.user == nil, root.password == nil else { return [] }
        let names: [String]
        if let known = cache[repository] { names = known }
        else {
            var request = URLRequest(url: root.appendingPathComponent("src/contrib/PACKAGES"))
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 32_000_000 else { throw URLError(.badServerResponse) }
            names = Array(Set(String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).compactMap {
                $0.hasPrefix("Package: ") ? String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces) : nil
            })).sorted()
            guard !names.isEmpty else { throw URLError(.cannotParseResponse) }
            if cache.count > 8 { cache.removeAll() }
            cache[repository] = names
        }
        let matching = names.filter { $0.localizedCaseInsensitiveContains(query) }
        let exact = matching.filter { $0.caseInsensitiveCompare(query) == .orderedSame }
        let prefix = matching.filter { $0.caseInsensitiveCompare(query) != .orderedSame && $0.lowercased().hasPrefix(query.lowercased()) }
        let others = matching.filter { !$0.lowercased().hasPrefix(query.lowercased()) }
        return Array((exact + prefix + others).prefix(100))
    }
}
