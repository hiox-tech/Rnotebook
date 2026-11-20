import AppKit
import SwiftUI

/// Session-local, lazily loaded nodes. Paths are integer indices, never R source.
@MainActor final class InspectorPreviewBrowser: ObservableObject {
    final class Node: NSObject {
        let id: String
        let path: [Int]
        let cells: [String]
        let canExpand: Bool
        let page: NotebookPreviewRequest?
        var children: [Node] = []
        var loaded = false
        init(id: String, path: [Int], cells: [String], canExpand: Bool = false, page: NotebookPreviewRequest? = nil) {
            self.id = id; self.path = path; self.cells = cells; self.canExpand = canExpand; self.page = page
        }
    }
    @Published private(set) var root: NotebookObjectPreview?
    @Published private(set) var roots: [Node] = []
    @Published private(set) var version = 0
    @Published private(set) var error: String?
    private(set) var pending: NotebookPreviewRequest?
    private var queue: [NotebookPreviewRequest] = []
    private var owners: [NotebookPreviewRequest: Node] = [:]

    func reset() {
        root = nil; roots = []; error = nil; queue = [.init()]
        pending = nil; owners = [:]; version += 1
    }
    func next() -> NotebookPreviewRequest? {
        guard pending == nil, !queue.isEmpty else { return nil }
        pending = queue.removeFirst(); return pending
    }
    func expand(_ node: Node) {
        guard node.canExpand, !node.loaded else { return }
        enqueue(.init(path: node.path, structure: true), owner: node)
    }
    func more(_ node: Node) {
        guard let request = node.page else { return }
        enqueue(request, owner: owners[request])
    }
    private func enqueue(_ request: NotebookPreviewRequest, owner: Node?) {
        guard pending != request, !queue.contains(request) else { return }
        if let owner { owners[request] = owner }
        queue.append(request); error = nil; version += 1
    }
    func receive(_ preview: NotebookObjectPreview?, error failure: String?) {
        guard let request = pending else { return }
        pending = nil
        guard let preview, preview.request == request else {
            error = failure ?? L10n.string("无法读取变量预览"); queue = []; version += 1; return
        }
        error = nil
        if request.path.isEmpty && request.rowOffset == 0 && request.columnOffset == 0 {
            root = preview
            if preview.kind == "list" { roots = makeNodes(preview) }
        } else if root?.kind == "list" {
            let owner = owners[request]
            let children = makeNodes(preview)
            if let owner {
                if request.rowOffset == 0 && request.columnOffset == 0 { owner.children = children }
                else { owner.children.removeAll { $0.page == request }; owner.children += children }
                owner.loaded = true
            } else {
                roots.removeAll { $0.page == request }; roots += children
            }
        } else { root = preview }
        version += 1
    }
    func showPage(_ request: NotebookPreviewRequest) { enqueue(request, owner: nil) }
    private func makeNodes(_ preview: NotebookObjectPreview) -> [Node] {
        let request = preview.request
        var result = preview.rows.enumerated().map { index, row -> Node in
            let path = request.path + [request.rowOffset + index]
            let id = path.map(String.init).joined(separator: "/") + (preview.kind == "table" ? ":\(request.columnOffset)" : "")
            let cells: [String]
            if preview.kind == "list" { cells = row }
            else if preview.kind == "vector" { cells = [row[0], "", preview.scalarText ?? row[1]] }
            else if preview.kind == "table" {
                cells = [preview.rowNames?[index] ?? String(request.rowOffset + index + 1), "", zip(preview.columns, row).map { "\($0): \($1)" }.joined(separator: ", ")]
            } else { cells = [row.first ?? "", "", row.last ?? ""] }
            let node = Node(id: id, path: path, cells: cells, canExpand: preview.kind == "list" && preview.expandable[index] && path.count <= 12)
            return node
        }
        func more(_ next: NotebookPreviewRequest, _ title: String) -> Node {
            let node = Node(id: "more:\(next)", path: request.path, cells: [title, "", ""], page: next)
            if let owner = owners[request] { owners[next] = owner }
            return node
        }
        if request.rowOffset + preview.rows.count < preview.totalRows {
            var next = request; next.rowOffset += preview.rows.count
            result.append(more(next, L10n.string("载入更多…")))
        }
        if preview.kind == "table", request.rowOffset == 0, request.columnOffset + preview.columns.count < preview.totalColumns {
            var next = request; next.columnOffset += preview.columns.count
            result.append(more(next, L10n.string("载入更多列…")))
        }
        return result
    }
}

/// Native disclosure triangles preserve expanded siblings and selection while a child loads.
struct InspectorObjectOutline: NSViewRepresentable {
    @ObservedObject var browser: InspectorPreviewBrowser
    var load: () -> Void
    var rowsChanged: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let outline = NSOutlineView(); outline.delegate = context.coordinator; outline.dataSource = context.coordinator
        outline.rowHeight = 20; outline.indentationPerLevel = 14; outline.intercellSpacing = NSSize(width: 8, height: 2)
        outline.usesAlternatingRowBackgroundColors = true; outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (index, title) in [L10n.string("成员"), L10n.string("类型"), L10n.string("值")].enumerated() {
            let column = NSTableColumn(identifier: .init(String(index))); column.title = title; column.isEditable = false
            column.minWidth = index == 0 ? 100 : 70; column.width = [230.0, 130, 310][index]
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.target = context.coordinator; outline.doubleAction = #selector(Coordinator.activate(_:))
        outline.setAccessibilityIdentifier("record-object-outline")
        scroll.documentView = outline; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let outline = scroll.documentView as? NSOutlineView, coordinator.version != browser.version else { return }
        coordinator.version = browser.version
        let selected = (outline.item(atRow: outline.selectedRow) as? InspectorPreviewBrowser.Node)?.id
        let origin = scroll.contentView.bounds.origin
        coordinator.reloading = true
        outline.reloadData()
        func restore(_ nodes: [InspectorPreviewBrowser.Node]) {
            for node in nodes where coordinator.expanded.contains(node.id) {
                outline.expandItem(node)
                restore(node.children)
            }
        }
        restore(browser.roots)
        if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? InspectorPreviewBrowser.Node)?.id == selected }) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.reloading = false
        coordinator.reportRows(outline)
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: InspectorObjectOutline
        var version = -1
        var expanded = Set<String>()
        var reloading = false
        init(_ parent: InspectorObjectOutline) { self.parent = parent }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? InspectorPreviewBrowser.Node else { return parent.browser.roots.count }
            return node.loaded ? node.children.count : (node.canExpand ? 1 : 0)
        }
        private var loading: [String: InspectorPreviewBrowser.Node] = [:]
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? InspectorPreviewBrowser.Node else { return parent.browser.roots[index] }
            if node.loaded { return node.children[index] }
            if let placeholder = loading[node.id] { return placeholder }
            let placeholder = InspectorPreviewBrowser.Node(id: "loading:" + node.id, path: [], cells: ["…", "", ""])
            loading[node.id] = placeholder; return placeholder
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? InspectorPreviewBrowser.Node)?.canExpand == true }
        func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool { false }
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? InspectorPreviewBrowser.Node else { return false }
            if !reloading { expanded.insert(node.id); parent.browser.expand(node); parent.load() }
            return true
        }
        func outlineViewItemDidExpand(_ notification: Notification) { if let outline = notification.object as? NSOutlineView { reportRows(outline) } }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            if !reloading, let node = notification.userInfo?["NSObject"] as? InspectorPreviewBrowser.Node { expanded.remove(node.id) }
            if let outline = notification.object as? NSOutlineView { reportRows(outline) }
        }
        func reportRows(_ outline: NSOutlineView) {
            let count = outline.numberOfRows
            DispatchQueue.main.async { [weak self] in self?.parent.rowsChanged(count) }
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? InspectorPreviewBrowser.Node, let index = Int(tableColumn?.identifier.rawValue ?? ""), index < node.cells.count else { return nil }
            if index == 0, node.page != nil {
                let button = NSButton(title: node.cells[0], target: self, action: #selector(more(_:)))
                button.bezelStyle = .inline; button.controlSize = .small; button.identifier = .init(node.id)
                return button
            }
            let field = NSTextField(labelWithString: node.cells[index]); field.isSelectable = true
            field.font = index == 2 ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            field.textColor = index == 1 ? .secondaryLabelColor : .labelColor
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1; field.toolTip = node.cells[index]
            return field
        }
        @objc func more(_ sender: NSButton) {
            guard let outline = sender.enclosingScrollView?.documentView as? NSOutlineView,
                  let node = outline.item(atRow: outline.row(for: sender)) as? InspectorPreviewBrowser.Node else { return }
            parent.browser.more(node); parent.load()
        }
        @objc func activate(_ sender: NSOutlineView) {
            guard let node = sender.item(atRow: sender.clickedRow) as? InspectorPreviewBrowser.Node else { return }
            if node.page != nil { parent.browser.more(node); parent.load() }
            else if node.canExpand { if sender.isItemExpanded(node) { sender.collapseItem(node) } else { sender.expandItem(node) } }
        }
    }
}
