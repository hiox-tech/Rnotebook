import Foundation

enum NotebookLibrary {
    static var defaultURL: URL {
        NotebookStorage.applicationSupport.appendingPathComponent("R/library", isDirectory: true)
    }
    static func selected(defaults: UserDefaults = .standard) -> URL {
        let path = defaults.string(forKey: "notebook.packageLibrary") ?? ""
        return path.isEmpty ? defaultURL : URL(fileURLWithPath: path, isDirectory: true)
    }
    static func environment(_ original: [String: String], library: URL? = nil,
                            rscript: URL? = nil) throws -> [String: String] {
        let library = library ?? selected()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var environment = NotebookBundledRuntime.environment(original)
        // The shared runtime library is built for the bundled R 4.6.2. Never
        // expose it to a user-selected system R of a different version/arch.
        let bundled = NotebookBundledRuntime.rscript?.resolvingSymlinksInPath().standardizedFileURL
        let selected = rscript?.resolvingSymlinksInPath().standardizedFileURL
        let shared = bundled != nil && selected != nil && bundled == selected
            ? NotebookBundledRuntime.sharedRLibrary?.path : nil
        let base = [library.path] + (shared.map { [$0] } ?? [])
        let others = (environment["R_LIBS"] ?? "").split(separator: ":").map(String.init)
            .filter { !base.contains($0) }
        environment["R_LIBS"] = (base + others).joined(separator: ":")
        return environment
    }
}
