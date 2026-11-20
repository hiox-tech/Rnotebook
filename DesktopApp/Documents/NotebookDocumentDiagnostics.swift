import AppKit
import UniformTypeIdentifiers

/// Explicit, read-only CLI diagnostics for a computer where type matching
/// differs. This branch does not start the app UI or change any handlers.
@MainActor enum NotebookDocumentDiagnostics {
    static func write(paths: [String]) {
        let bundle = Bundle.main
        let workspace = NSWorkspace.shared
        let preview = bundle.builtInPlugInsURL
            .flatMap { Bundle(url: $0.appendingPathComponent("RnotebookPreview.appex")) }
        let extensionInfo = preview?.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        let attributes = extensionInfo?["NSExtensionAttributes"] as? [String: Any]
        let extensions: [[String: Any]] = ["qmd", "QMD", "rmd", "Rmd", "RMD"].map { suffix in
            let types = UTType.types(tag: suffix, tagClass: .filenameExtension, conformingTo: nil)
            return ["extension": suffix, "types": types.map { type in
                ["identifier": type.identifier,
                 "dynamic": type.isDynamic,
                 "declared": type.isDeclared,
                 "conformsToPlainText": type.conforms(to: .plainText),
                 "applications": workspace.urlsForApplications(toOpen: type).map(\.path)] as [String: Any]
            }]
        }
        let files: [[String: Any]] = paths.map { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var result: [String: Any] = ["path": url.path, "supportedSuffix": NotebookDocumentType.supports(url)]
            do {
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .isDirectoryKey])
                result["liveContentType"] = values.contentType?.identifier ?? "unknown"
                result["isRegularFile"] = values.isRegularFile ?? false
                result["isDirectory"] = values.isDirectory ?? false
            } catch { result["error"] = error.localizedDescription }
            result["applications"] = workspace.urlsForApplications(toOpen: url).map(\.path)
            result["defaultApplication"] = workspace.urlForApplication(toOpen: url)?.path ?? "none"
            return result
        }
        let report: [String: Any] = [
            "application": bundle.bundleURL.path,
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "documentDeclarations": bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") ?? [],
            "previewVersion": preview?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "missing",
            "previewSupportedTypes": attributes?["QLSupportedContentTypes"] ?? [],
            "registeredApplicationCopies": workspace.urlsForApplications(withBundleIdentifier: "org.hiox.Rnotebook").map(\.path),
            "extensionTypes": extensions,
            "files": files
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0a)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }
    }
}
