import AppKit
import Foundation
import UniformTypeIdentifiers

/// An explicit user export, independent of QMD saving and draft recovery.
struct NotebookWorkspaceDestination {
    let url: URL
    private let initialHash: String?
    init(_ url: URL, overwrite: Bool) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "rdata" else {
            throw Self.error(L10n.string("请选择 .RData 文件保存 R 工作区。"))
        }
        self.url = url
        initialHash = try Self.hash(url)
        guard initialHash == nil || overwrite else { throw Self.error(L10n.string("RData 文件已存在，未覆盖。")) }
    }
    private static func hash(_ url: URL) throws -> String? {
        do { return try QuartoDestination.hashIfPresent(url) }
        catch { throw Self.error(L10n.string("无法读取 RData 目标文件，或目标不是普通文件。")) }
    }
    func publish(_ artifact: URL) throws {
        let values = try artifact.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw Self.error(L10n.string("未生成完整的 RData 文件。"))
        }
        guard try Self.hash(url) == initialHash else { throw Self.error(L10n.string("保存期间 RData 目标被外部修改，未覆盖。")) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".rnotebook-workspace-" + UUID().uuidString)
        try FileManager.default.copyItem(at: artifact, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if initialHash == nil { try FileManager.default.moveItem(at: temporary, to: url) }
        else { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
    }
    static func error(_ text: String) -> NSError {
        NSError(domain: "Rnotebook.WorkspaceSave", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

extension RecordLayoutModel {
    static func workspaceSaveName(documentURL: URL?) -> String {
        var name = documentURL?.lastPathComponent ?? "Workspace"
        while ["qmd", "rmd", "rdata"].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
        }
        return (name.isEmpty ? "Workspace" : name) + ".RData"
    }
    func requestWorkspaceSave() {
        guard notebook.canSaveWorkspace, let window = notebook.window, let session = notebook.sessionID else { return }
        let panel = NSSavePanel()
        panel.title = L10n.string("保存 R 工作区")
        panel.allowedContentTypes = [UTType(filenameExtension: "RData") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.workspaceSaveName(documentURL: documentURL)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do { notebook.saveWorkspace(to: try NotebookWorkspaceDestination(url, overwrite: true), expectedSession: session) }
            catch { notice = error.localizedDescription }
        }
    }
}
