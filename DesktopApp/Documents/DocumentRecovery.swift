import AppKit
import Darwin
import SwiftUI

/// Private crash protection. Restoring always creates an unsaved copy and never
/// replaces the original QMD or restores outputs/R memory.
@MainActor final class DocumentRecoveryStore {
    struct Metadata: Codable {
        let originalURL: URL?
        let updatedAt: Date
        let ownerPID: Int32
    }
    struct Draft: Identifiable {
        let id: String
        let source: String
        let originalURL: URL?
        let updatedAt: Date
        var title: String { originalURL?.lastPathComponent ?? L10n.string("未命名文档") }
    }
    static let shared = DocumentRecoveryStore(directory: NotebookStorage.applicationSupport.appendingPathComponent("Recovery", isDirectory: true))
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func write(id: UUID, source: String, originalURL: URL?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(source.utf8).write(to: directory.appendingPathComponent(id.uuidString + ".qmd"), options: .atomic)
        let metadata = Metadata(originalURL: originalURL, updatedAt: Date(), ownerPID: getpid())
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
    }
    func remove(id: String) {
        // Accept only a single UUID stem; legacy drafts use the same naming.
        guard UUID(uuidString: id) != nil else { return }
        for ext in ["qmd", "json"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + "." + ext)) }
    }
    func drafts(includeLiveOwners: Bool = false) throws -> [Draft] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "qmd" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { url -> Draft? in
                let id = url.deletingPathExtension().lastPathComponent
                let metadataURL = directory.appendingPathComponent(id + ".json")
                let metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
                if !includeLiveOwners, let pid = metadata?.ownerPID, pid > 0,
                   kill(pid, 0) == 0 || errno == EPERM { return nil }
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                // Old versions created an empty snapshot for every clean document.
                if metadata == nil && source.isEmpty { return nil }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return Draft(id: id, source: source, originalURL: metadata?.originalURL, updatedAt: metadata?.updatedAt ?? modified ?? .distantPast)
            }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

struct DocumentRecoveryView: View {
    let drafts: [DocumentRecoveryStore.Draft]
    let restore: ([DocumentRecoveryStore.Draft]) -> Void
    let discard: ([DocumentRecoveryStore.Draft]) -> Void
    let later: () -> Void
    @State private var selected = Set<String>()
    @State private var confirmingDiscard = false
    private var chosen: [DocumentRecoveryStore.Draft] { drafts.filter { selected.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("恢复未保存文档")).font(.title2)
            Text(L10n.string("上次中断时保留了以下正文。恢复后会打开未保存的副本，原文件保留；代码不会自动执行。"))
                .foregroundStyle(.secondary)
            List(drafts) { draft in
                Toggle(isOn: Binding(get: { selected.contains(draft.id) }, set: {
                    if $0 { selected.insert(draft.id) } else { selected.remove(draft.id) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.title)
                        Text(draft.originalURL?.path ?? L10n.string("尚未保存的文档")).font(.caption).foregroundStyle(.secondary)
                        Text(draft.updatedAt, style: .date).font(.caption)
                        Text(String(draft.source.prefix(120))).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox)
            }
            HStack {
                Button(L10n.string("删除所选暂存…"), role: .destructive) { confirmingDiscard = true }.disabled(chosen.isEmpty)
                Spacer()
                Button(L10n.string("稍后处理"), action: later).keyboardShortcut(.cancelAction)
                Button(L10n.string("恢复所选")) { restore(chosen) }.disabled(chosen.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 600, height: 430)
            .onAppear { selected = Set(drafts.map(\.id)) }
            .confirmationDialog(L10n.string("删除所选的未保存正文？此操作不能撤销。"), isPresented: $confirmingDiscard) {
                Button(L10n.string("删除所选暂存"), role: .destructive) { discard(chosen) }
            }
    }
}
