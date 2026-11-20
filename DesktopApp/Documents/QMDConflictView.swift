import SwiftUI

struct QMDConflictView: View {
    @ObservedObject var synchronization: QMDFileSynchronization
    var body: some View {
        if let conflict = synchronization.conflict {
            QMDConflictContent(synchronization: synchronization, conflict: conflict,
                               comparison: QMDComparison(editor: conflict.editor, external: conflict.external ?? ""))
                .id(conflict.id)
        }
    }
}

private struct QMDConflictContent: View {
    @ObservedObject var synchronization: QMDFileSynchronization
    let conflict: QMDFileSynchronization.Conflict
    let comparison: QMDComparison
    @StateObject private var scroll = QMDComparisonScroll()
    @State private var current = 0
    @State private var synchronized = true
    @State private var showingBase = false
    @State private var resolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("比对文档版本")).font(.headline)
                Text(synchronization.documentName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    .help(synchronization.documentPath)
                Text(L10n.string("保存已暂停。选择版本前，请检查两侧差异；选择后将替换另一版本的内容。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(String(format: L10n.string("差异 %ld / %ld"), comparison.changes.isEmpty ? 0 : current + 1, comparison.changes.count))
                    .monospacedDigit().foregroundStyle(.secondary).accessibilityIdentifier("comparison-change-count")
                Button { navigate(-1) } label: { Image(systemName: "chevron.up") }
                    .help(L10n.string("上一处差异")).accessibilityLabel(L10n.string("上一处差异"))
                    .accessibilityIdentifier("comparison-previous").disabled(comparison.changes.isEmpty)
                Button { navigate(1) } label: { Image(systemName: "chevron.down") }
                    .help(L10n.string("下一处差异")).accessibilityLabel(L10n.string("下一处差异"))
                    .accessibilityIdentifier("comparison-next").disabled(comparison.changes.isEmpty)
                Spacer()
                Toggle(L10n.string("同步滚动"), isOn: $synchronized).toggleStyle(.checkbox)
                    .accessibilityIdentifier("comparison-sync-scroll")
                    .onChange(of: synchronized) { _, value in scroll.synchronized = value }
                Toggle(L10n.string("显示共同基准"), isOn: $showingBase).toggleStyle(.checkbox)
                    .accessibilityIdentifier("comparison-show-base")
            }.controlSize(.small)
            if comparison.simplified {
                Text(L10n.string("文档较大，已显示完整内容并简化差异定位。")).font(.caption).foregroundStyle(.secondary)
            }
            if conflict.external == nil {
                Label(L10n.string("文件已被移除，暂无可加载的外部版本。"), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HSplitView {
                version(L10n.string("编辑器版本"), side: true)
                version(L10n.string("外部版本"), side: false)
            }.frame(minHeight: 220)
            if showingBase {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("共同基准")).font(.subheadline).foregroundStyle(.secondary)
                    ScrollView([.vertical, .horizontal]) {
                        Text(conflict.base).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.background(Color(nsColor: .textBackgroundColor)).frame(height: 120)
                        .overlay(Rectangle().strokeBorder(.separator, lineWidth: 0.5))
                }
            }
            Divider()
            HStack {
                Button(L10n.string("暂不处理")) { resolve(.later) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("使用外部版本")) { resolve(.external) }
                    .help(L10n.string("将外部内容载入编辑器。"))
                    .disabled(conflict.external == nil)
                Button(L10n.string("使用编辑器版本")) { resolve(.editor) }
                    .help(L10n.string("将编辑器内容保存到磁盘。"))
            }.disabled(resolving)
        }
        .padding(20).frame(minWidth: 740, idealWidth: 900, minHeight: 470, idealHeight: 600)
        .accessibilityElement(children: .contain).accessibilityIdentifier("qmd-conflict-comparison")
        .onAppear { if let first = comparison.changes.first { scroll.reveal(row: first) } }
    }
    private func version(_ title: String, side: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: side ? "pencil" : "externaldrive")
                Text(title).fontWeight(.medium)
                Spacer()
                Text(side ? L10n.string("橙色：编辑器差异") : L10n.string("绿色：外部差异"))
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.callout).padding(10).background(.quaternary.opacity(0.4))
            Divider()
            QMDComparisonPane(comparison: comparison, editorSide: side, scroll: scroll)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Rectangle().strokeBorder(.separator, lineWidth: 0.5))
    }
    private func navigate(_ direction: Int) {
        guard !comparison.changes.isEmpty else { return }
        current = (current + direction + comparison.changes.count) % comparison.changes.count
        scroll.reveal(row: comparison.changes[current])
    }
    private func resolve(_ choice: QMDFileSynchronization.Choice) {
        resolving = true
        Task { await synchronization.resolve(choice); resolving = false }
    }
}

struct QMDSynchronizationOverlay: ViewModifier {
    @ObservedObject var model: RecordLayoutModel
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let sync = model.document?.synchronization, sync.paused {
                    HStack {
                        Text(sync.conflict == nil ? L10n.string("保存已暂停") : L10n.string("检测到外部修改，保存已暂停")).font(.caption)
                        if sync.conflict != nil { Button(L10n.string("比对版本…")) { sync.requestComparison() } }
                    }
                    .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(12)
                }
            }
            .sheet(isPresented: Binding(get: { model.document?.synchronization.showingConflict ?? false },
                                        set: { model.document?.synchronization.showingConflict = $0 })) {
                if let sync = model.document?.synchronization { QMDConflictView(synchronization: sync) }
            }
    }
}
