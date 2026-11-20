import Foundation

/// Optional fully-offline runtime installed by the component PKG.
///
/// The layout is deliberately version-independent so an installer can replace
/// the payload without touching user documents, preferences or package
/// libraries. A user-selected path in Settings always wins over this location.
enum NotebookBundledRuntime {
    /// Tests replace this with a temporary tree; Release/Debug builds use the
    /// installer location. An environment override keeps QA deployments able
    /// to install under a disposable root.
    nonisolated(unsafe) static var overrideRoot: URL?

    static var root: URL {
        if let overrideRoot { return overrideRoot }
        if let env = ProcessInfo.processInfo.environment["RNOTEBOOK_RUNTIME_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Library/Rnotebook", isDirectory: true)
    }

    private static func executable(_ url: URL) -> URL? {
        FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    private static func directory(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    static var rFramework: URL { root.appendingPathComponent("R.framework", isDirectory: true) }
    static var rscript: URL? { executable(rFramework.appendingPathComponent("Resources/bin/Rscript")) }
    static var quarto: URL? { executable(root.appendingPathComponent("quarto/bin/quarto")) }
    static var sharedRLibrary: URL? { directory(root.appendingPathComponent("R/library", isDirectory: true)) }

    static var texBin: URL? {
        for name in ["bin/universal-darwin", "bin/arm64-darwin", "bin/x86_64-darwin"] {
            if let url = directory(root.appendingPathComponent("TinyTeX", isDirectory: true).appendingPathComponent(name, isDirectory: true)) {
                return url
            }
        }
        return nil
    }
    static var chromeHeadlessShell: URL? {
        executable(root.appendingPathComponent("chrome-headless-shell/chrome-headless-shell"))
    }
    static var userTeXMF: URL { NotebookStorage.applicationSupport.appendingPathComponent("texmf", isDirectory: true) }

    /// Prepends bundled tool directories and supplies Quarto/TeX locations
    /// explicitly; callers never rely on the user's shell startup files.
    static func environment(_ original: [String: String]) -> [String: String] {
        var environment = original
        var bins: [String] = []
        if let r = rscript { bins.append(r.deletingLastPathComponent().path) }
        if let q = quarto { bins.append(q.deletingLastPathComponent().path) }
        if let texBin { bins.append(texBin.path) }
        if let chrome = chromeHeadlessShell { bins.append(chrome.deletingLastPathComponent().path) }
        if !bins.isEmpty {
            let existing = environment["PATH"].flatMap { $0.isEmpty ? nil : [$0] } ?? []
            environment["PATH"] = (bins + existing).joined(separator: ":")
        }
        if let chrome = chromeHeadlessShell { environment["QUARTO_CHROMIUM"] = chrome.path }
        if texBin != nil {
            try? FileManager.default.createDirectory(at: userTeXMF, withIntermediateDirectories: true)
            environment["TEXMFHOME"] = userTeXMF.path
        }
        return environment
    }
}
