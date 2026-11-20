import AppKit

/// A standalone picker delegate. In particular, do not forward AppKit's
/// document-type callbacks, which can reapply a conflicting UTI restriction.
@MainActor final class NotebookOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // Picker URLs may not have complete resource metadata yet. A known
        // suffix must not be disabled just because isRegularFile is missing.
        if NotebookDocumentType.supports(url) { return true }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        if values.isDirectory == true { return values.isPackage != true }
        return false
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard NotebookDocumentType.supports(url),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSURLErrorKey: url,
                NSLocalizedDescriptionKey: L10n.string("请选择 .qmd 或 .Rmd 文稿。")
            ])
        }
    }
}
