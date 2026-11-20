import AppKit
import EdmundCore

enum RecordNavigationGeometry {
    static func selectionFill(accent: NSColor, appearance: NSAppearance) -> NSColor {
        var color = NSColor.clear
        appearance.performAsCurrentDrawingAppearance { color = accent.withAlphaComponent(0.3) }
        return color
    }
    static func width(for available: CGFloat) -> CGFloat {
        min(112, max(72, available * 0.16))
    }
}

@MainActor final class RecordDocumentOutline: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let tree = RecordOutlineTree()
    private let scroll = NSScrollView()
    private var headings: [OutlineHeading] = []
    private var roots: [OutlineNode] = []
    private var updating = false
    private var deferredHeadings: [OutlineHeading]?
    private var deferredOffset: Int?
    weak var editor: EditorTextView?
    var navigationBackground: NSColor {
        editor?.backgroundColor ?? .textBackgroundColor
    }
    func refreshBackground() {
        tree.backgroundColor = navigationBackground
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Task { @MainActor [weak self] in
            await Task.yield(); self?.refreshBackground()
        }
    }
    var selectionAccentColor: NSColor = .controlAccentColor {
        didSet { if oldValue != selectionAccentColor { tree.needsDisplay = true } }
    }
    var viewportFillColor: NSColor {
        RecordNavigationGeometry.selectionFill(accent: selectionAccentColor, appearance: effectiveAppearance)
    }
    var navigate: ((NSRange) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; clipsToBounds = true
        setAccessibilityIdentifier("record-document-outline")
        let column = NSTableColumn(identifier: .init("heading"))
        tree.addTableColumn(column); tree.outlineTableColumn = column
        tree.headerView = nil; tree.rowHeight = 21; tree.indentationPerLevel = 8
        tree.indentationMarkerFollowsCell = false
        tree.backgroundColor = .textBackgroundColor
        tree.style = .plain; tree.selectionHighlightStyle = .regular
        tree.allowsEmptySelection = true; tree.focusRingType = .none
        tree.dataSource = self; tree.delegate = self
        tree.target = self; tree.action = #selector(clicked(_:))
        tree.interactionEnded = { [weak self] in
            guard let self else { return }
            if let headings = deferredHeadings { deferredHeadings = nil; update(headings) }
            // A click established a new navigation target. A pre-click tracking
            // sample must not immediately select/scroll the old row again.
            deferredOffset = nil
        }
        tree.keyboardNavigate = { [weak self] in
            guard let self else { return }
            self.jump(row: self.tree.selectedRow)
        }
        tree.setAccessibilityIdentifier("record-outline-tree")
        scroll.documentView = tree; scroll.hasVerticalScroller = true
        scroll.clipsToBounds = true
        scroll.contentView.drawsBackground = false
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 4, y: 8, width: max(0, bounds.width - 8), height: max(0, bounds.height - 16))
        tree.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }
    override func draw(_ dirtyRect: NSRect) {
        navigationBackground.setFill(); bounds.fill()
        if hovered {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: 1 / (window?.backingScaleFactor ?? 2), height: bounds.height).fill()
        }
    }
    func update(_ headings: [OutlineHeading]) {
        guard self.headings != headings else { return }
        if tree.isInteracting { deferredHeadings = headings; return }
        // Keep expansion across body edits and retitles; independent nodes have
        // a positional identity, including identical titles at different levels.
        let oldNodes = flatten(roots)
        if self.headings.count == headings.count,
           zip(self.headings, headings).allSatisfy({ $0.level == $1.level }) {
            // Source offsets change on every body keystroke. Keep native row
            // identity/selection and redraw only an actual title change.
            self.headings = headings
            for node in oldNodes {
                let heading = headings[node.index]
                let retitled = node.heading.title != heading.title
                node.heading = heading
                if retitled { tree.reloadItem(node, reloadChildren: false) }
            }
            return
        }
        let collapsedIndices = Set(oldNodes.filter { !$0.children.isEmpty && !tree.isItemExpanded($0) }.map(\.index))
        let oldCount = self.headings.count
        self.headings = headings; roots = OutlineNode.tree(headings)
        updating = true
        tree.reloadData(); tree.expandItem(nil, expandChildren: true)
        if oldCount == headings.count {
            for node in flatten(roots) where collapsedIndices.contains(node.index) { tree.collapseItem(node) }
        }
        updating = false
    }
    func track(offset: Int) {
        // Native text layout can finish while the outline is reloading or
        // selecting. Wait for the next viewport update before selecting again.
        guard !updating, !headings.isEmpty else { return }
        if tree.isInteracting { deferredOffset = offset; return }
        let current = headings.lastIndex { $0.range.location <= offset } ?? 0
        let nodes = flatten(roots)
        var node = nodes.first { $0.index == current }
        // NSOutlineView need not remember a hidden item's parent after a branch
        // collapses. Use the source hierarchy, not the table's visible rows.
        while let item = node, tree.row(forItem: item) < 0 {
            node = nodes.last { $0.index < item.index && $0.heading.level < item.heading.level }
        }
        guard let node else { return }
        let row = tree.row(forItem: node)
        if row >= 0, tree.selectedRow != row {
            updating = true
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tree.scrollRowToVisible(row)
            updating = false
        }
    }
    private func flatten(_ nodes: [OutlineNode]) -> [OutlineNode] { nodes.flatMap { [$0] + flatten($0.children) } }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? OutlineNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? OutlineNode)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! OutlineNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let heading = (item as! OutlineNode).heading
        let cell = RecordOutlineNavigationCell()
        cell.textField?.stringValue = heading.title.isEmpty ? L10n.string("无标题") : heading.title
        cell.toolTip = heading.title
        return cell
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = RecordOutlineNavigationRow()
        row.navigation = self
        return row
    }
    @objc private func clicked(_ sender: Any?) {
        guard !updating, let node = (tree.pressedItem ?? tree.item(atRow: tree.clickedRow)) as? OutlineNode else { return }
        navigate?(NSRange(location: node.heading.range.location, length: 0))
    }
    private func jump(row: Int) {
        guard !updating, let node = tree.item(atRow: row) as? OutlineNode else { return }
        navigate?(NSRange(location: node.heading.range.location, length: 0))
    }
}

@MainActor private final class RecordOutlineNavigationRow: NSTableRowView {
    weak var navigation: RecordDocumentOutline?
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        (navigation?.viewportFillColor ?? .clear).setFill(); path.fill()
        (navigation?.selectionAccentColor ?? .controlAccentColor).withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.5; path.stroke()
    }
}

/// Tracking and reloads select rows programmatically, sometimes with delayed
/// notifications. Only an actual click or keyboard gesture navigates the text.
@MainActor final class RecordOutlineTree: NSOutlineView {
    var keyboardNavigate: (() -> Void)?
    var interactionEnded: (() -> Void)?
    private(set) var isInteracting = false
    private(set) var pressedItem: Any?
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        pressedItem = row >= 0 ? item(atRow: row) : nil
        isInteracting = true
        defer { pressedItem = nil; isInteracting = false; interactionEnded?() }
        super.mouseDown(with: event)
    }
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let line = rect(ofRow: row)
        return NSRect(x: 2 + CGFloat(level(forRow: row)) * indentationPerLevel,
            y: line.midY - 7, width: 12, height: 14)
    }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if column == 0, row >= 0 {
            frame.origin.x = frameOfOutlineCell(atRow: row).maxX + 1
            frame.size.width = max(0, bounds.width - frame.minX - 4)
        }
        return frame
    }
    override func keyDown(with event: NSEvent) {
        isInteracting = true
        defer { isInteracting = false; interactionEnded?() }
        super.keyDown(with: event)
        if [36, 76, 125, 126].contains(event.keyCode) { keyboardNavigate?() }
    }
}

@MainActor private final class RecordOutlineNavigationCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
        addSubview(field); textField = field
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        guard let textField else { return }
        let height = textField.intrinsicContentSize.height
        textField.frame = NSRect(x: 0, y: (bounds.height - height) / 2,
            width: bounds.width, height: height)
    }
}
