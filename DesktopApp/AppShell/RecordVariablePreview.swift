import AppKit
import SwiftUI

struct InspectorPreviewSelection: Identifiable {
    let id = UUID()
    let name: String
    let sessionID: UUID
    let revision: Int
}

struct RecordVariablePreviewSheet: View {
    @ObservedObject var session: NotebookExecution
    let selection: InspectorPreviewSelection
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = InspectorPreviewBrowser()
    @State private var outlineRows = 0
    private var stale: Bool { selection.sessionID != session.sessionID || selection.revision != session.inspectorRevision }
    private var preview: NotebookObjectPreview? { browser.root }
    private var scalar: Bool { preview?.kind == "vector" && preview?.totalRows == 1 }
    private var width: CGFloat {
        guard let preview else { return 460 }
        if preview.totalRows == 0 && preview.kind != "table" { return 320 }
        if preview.kind == "list" { return 720 }
        if preview.kind == "table" { return min(860, max(420, InspectorReadOnlyTable.contentWidth(preview) + 28)) }
        if preview.totalRows == 0 { return 320 }
        if preview.kind == "summary" { return 380 }
        if scalar { return preview.scalarText == nil ? 320 : 460 }
        return min(620, max(360, InspectorReadOnlyTable.contentWidth(preview) + 28))
    }
    private var contentHeight: CGFloat {
        guard !stale, let preview else { return 64 }
        if preview.totalRows == 0 { return 40 }
        if preview.kind == "summary" { return 40 }
        if scalar {
            let text = preview.scalarText ?? preview.rows.first?.last ?? ""
            let bounds = (text as NSString).boundingRect(with: NSSize(width: width - 40, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            return min(260, max(36, ceil(bounds.height) + 16))
        }
        let rows = preview.kind == "list" ? max(outlineRows, browser.roots.count) : preview.rows.count
        return min(380, CGFloat(max(1, rows)) * 22 + 28)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(selection.name).font(.headline).lineLimit(1).help(selection.name)
                Text(L10n.string("只读")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
                Button { browser.reset(); pump() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.string("重新读取")).disabled(session.isBusy || stale)
                    .accessibilityIdentifier("record-preview-refresh")
            }
            if !stale, let preview, preview.kind != "summary" {
                Text(scalar && preview.scalarText == nil ? preview.type : preview.summary).foregroundStyle(.secondary).font(.system(size: 11)).lineLimit(1)
                    .help(preview.summary).textSelection(.enabled).accessibilityIdentifier("record-preview-summary")
            }
            content.frame(height: contentHeight)
            if !stale, let preview, preview.kind != "list", preview.totalRows > 100 || preview.totalColumns > 30 {
                pagination(preview)
            }
            if preview != nil, let error = browser.error, !stale {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("record-preview-error")
            }
            HStack {
                Spacer()
                Button(L10n.string("关闭"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("record-preview-close")
            }.controlSize(.small)
        }
        .padding(14).frame(width: width).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain).accessibilityIdentifier("record-variable-preview-sheet")
        .task { browser.reset(); pump() }
        .onChange(of: session.isBusy) { _, busy in
            guard !busy, !stale else { return }
            if browser.pending != nil { browser.receive(session.objectPreview, error: session.previewError) }
            pump()
        }
    }
    @ViewBuilder private var content: some View {
        if stale {
            Text(L10n.string("R 会话或对象已变化，请关闭后重新选择变量。")).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
        } else if let preview {
            if preview.totalRows == 0 && preview.kind != "table" {
                Text(L10n.string("空对象")).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            } else if preview.kind == "summary" {
                Text(preview.rows.first?.last ?? preview.type).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else if scalar {
                ScrollView {
                    Text(preview.scalarText ?? preview.rows.first?.last ?? "").font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.background(Color(nsColor: .textBackgroundColor)).accessibilityIdentifier("record-preview-scalar")
            } else if preview.kind == "list" {
                InspectorObjectOutline(browser: browser, load: pump) { count in if outlineRows != count { outlineRows = count } }
            } else {
                InspectorReadOnlyTable(preview: preview, expand: { _ in })
                    .accessibilityIdentifier("record-preview-table")
            }
        } else if let error = browser.error {
            Text(error).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("record-preview-error")
        } else {
            ProgressView(L10n.string("正在读取变量…")).controlSize(.small).frame(maxWidth: .infinity)
        }
    }
    private func pagination(_ preview: NotebookObjectPreview) -> some View {
        HStack(spacing: 8) {
            if preview.totalRows > 100 {
                Button(L10n.string("上一页")) { page(preview, rows: -100) }.disabled(preview.request.rowOffset == 0)
                    .accessibilityIdentifier("record-preview-previous")
                Text("\(preview.request.rowOffset + 1)–\(preview.request.rowOffset + preview.rows.count) / \(preview.totalRows)").monospacedDigit()
                Button(L10n.string("下一页")) { page(preview, rows: 100) }.disabled(preview.request.rowOffset + preview.rows.count >= preview.totalRows)
                    .accessibilityIdentifier("record-preview-next")
            }
            Spacer()
            if preview.kind == "table", preview.totalColumns > 30 {
                Button { page(preview, columns: -30) } label: { Image(systemName: "chevron.left") }
                    .disabled(preview.request.columnOffset == 0).help(L10n.string("上一组列"))
                Text(L10n.string("\(String(preview.request.columnOffset + 1))–\(String(preview.request.columnOffset + preview.columns.count)) / \(String(preview.totalColumns)) 列")).monospacedDigit()
                Button { page(preview, columns: 30) } label: { Image(systemName: "chevron.right") }
                    .disabled(preview.request.columnOffset + preview.columns.count >= preview.totalColumns).help(L10n.string("下一组列"))
            }
        }.font(.system(size: 11)).controlSize(.small).disabled(session.isBusy)
    }
    private func page(_ preview: NotebookObjectPreview, rows: Int = 0, columns: Int = 0) {
        var request = preview.request
        request.rowOffset = max(0, request.rowOffset + rows); request.columnOffset = max(0, request.columnOffset + columns)
        browser.showPage(request); pump()
    }
    private func pump() {
        guard !stale, !session.isBusy, let request = browser.next() else { return }
        session.manage(.init(operation: .previewObject, name: selection.name, preview: request), expectedSession: selection.sessionID)
    }
}

/// Compact, native read-only cells. Vectors already carry their index: no duplicate # column.
struct InspectorReadOnlyTable: NSViewRepresentable {
    let preview: NotebookObjectPreview
    var expand: (Int) -> Void
    static func widths(_ preview: NotebookObjectPreview) -> [CGFloat] {
        let headings = preview.kind == "table" ? ["#"] + preview.columns : (preview.kind == "vector" ? [L10n.string("索引"), L10n.string("值")] : preview.columns)
        return headings.enumerated().map { index, heading in
            if index == 0 {
                let labels = preview.kind == "table" ? (preview.rowNames ?? []) : preview.rows.map { $0.first ?? "" }
                let measured = labels.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width }.max() ?? 0
                return min(140, max(44, ceil(measured) + 18))
            }
            let values = preview.rows.map { row in row[index - (preview.kind == "table" ? 1 : 0)] }
            let longest = ([heading] + values).map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width }.max() ?? 70
            return min(preview.kind == "vector" ? 380 : 220, max(80, ceil(longest) + 18))
        }
    }
    static func contentWidth(_ preview: NotebookObjectPreview) -> CGFloat { widths(preview).reduce(0, +) + CGFloat(widths(preview).count) * 8 + 16 }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let table = NSTableView(); table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 20; table.intercellSpacing = NSSize(width: 8, height: 2)
        table.columnAutoresizingStyle = preview.kind == "vector" ? .lastColumnOnlyAutoresizingStyle : .noColumnAutoresizing
        table.allowsMultipleSelection = true; table.setAccessibilityIdentifier("record-readonly-variable-table")
        scroll.documentView = table; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        let headings = preview.kind == "table" ? ["#"] + preview.columns : (preview.kind == "vector" ? [L10n.string("索引"), L10n.string("值")] : preview.columns)
        if table.tableColumns.map(\.title) != headings {
            for column in table.tableColumns { table.removeTableColumn(column) }
            let widths = Self.widths(preview)
            for (i, heading) in headings.enumerated() {
                let column = NSTableColumn(identifier: .init(String(i))); column.title = heading
                column.isEditable = false; column.minWidth = i == 0 ? 40 : 60; column.width = widths[i]
                table.addTableColumn(column)
            }
        }
        table.reloadData()
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: InspectorReadOnlyTable
        init(_ parent: InspectorReadOnlyTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.preview.rows.count }
        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let index = Int(tableColumn?.identifier.rawValue ?? ""), row >= 0, row < parent.preview.rows.count else { return nil }
            let preview = parent.preview
            let text = preview.kind == "table" ? (index == 0 ? (preview.rowNames?[row] ?? String(preview.request.rowOffset + row + 1)) : preview.rows[row][index - 1]) : preview.rows[row][index]
            let field = NSTextField(labelWithString: text); field.isSelectable = true; field.isEditable = false
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular); field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1; field.toolTip = text
            if index == 0 { field.textColor = .secondaryLabelColor }
            return field
        }
    }
}
