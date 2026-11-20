import AppKit
import EdmundCore

/// Stable display identities are session state, independent of result values.
@MainActor final class RecordVisualBlockIndex {
    struct Block {
        let id: String
        let label: String?
        let language: String
        let range: NSRange
        let contentRange: NSRange
        let sourceHash: String
        let canRun: Bool
        let reason: String
        var options = NotebookExecutionOptions()
        var executable = true
    }
    private var source = ""
    private var sourceBytes = Data()
    private var cached: [Block] = []
    func blocks(in text: String) -> [Block] {
        let bytes = Data(text.utf8)
        if sourceBytes == bytes { return cached }
        let old = source as NSString, next = text as NSString
        var prefix = 0, suffix = 0
        while prefix < min(old.length, next.length), old.character(at: prefix) == next.character(at: prefix) { prefix += 1 }
        while suffix < min(old.length, next.length) - prefix,
              old.character(at: old.length - suffix - 1) == next.character(at: next.length - suffix - 1) { suffix += 1 }
        let scan = FenceScanner().scan(text)
        let entries = scan.fences
        let snapshots = Dictionary(uniqueKeysWithValues: scan.cells.map { ($0.range.location, $0) })
        let fingerprints = entries.map { entry in
            snapshots[entry.range.location]?.sourceHash ?? DocumentRevision(text: next.substring(with: entry.bodyRange)).rawValue
        }
        let fingerprintCounts = Dictionary(grouping: fingerprints, by: { $0 }).mapValues(\.count)
        var used = Set<String>()
        let result = entries.map { fence -> Block in
            let cell = snapshots[fence.range.location]
            let language = fence.language
            let hash = cell?.sourceHash ?? DocumentRevision(text: next.substring(with: fence.bodyRange)).rawValue
            let duplicate = cell?.label.map { label in scan.cells.filter { $0.label == label }.count > 1 } ?? false
            let id: String
            if let label = cell?.label, !duplicate { id = label }
            else {
                let exact = cached.filter { $0.label == nil && $0.sourceHash == hash && $0.language == language && !used.contains($0.id) }
                let exactNewCount = fingerprintCounts[hash] ?? 0
                if exact.count == 1 && exactNewCount == 1 { id = exact[0].id }
                else if let hit = cached.first(where: {
                    $0.label == nil && $0.range.location == fence.range.location && $0.language == language && !used.contains($0.id)
                        && prefix >= $0.range.location && old.length - suffix <= NSMaxRange($0.range)
                }) { id = hit.id }
                else { id = "local-" + UUID().uuidString }
            }
            used.insert(id)
            return Block(id: id, label: cell?.label, language: language, range: fence.range,
                         contentRange: fence.bodyRange, sourceHash: hash,
                         canRun: cell?.canRun == true && !duplicate,
                         reason: cell?.issues.joined(separator: "\n") ?? (language == "r" ? L10n.string("代码围栏未闭合或不支持逐块定位。") : L10n.string("此语言没有接入运行。")),
                         options: scan.defaults.overriding(cell?.options ?? .init()), executable: fence.executable)
        }
        source = text; sourceBytes = bytes; cached = result
        return result
    }
}

@MainActor enum RecordOutputEvent {
    case text(String), table([String], [[String]]), image(NSImage, pngData: Data? = nil), message(String), warning(String), error(String)
    case rich(RecordRichOutput)
    var tabKind: String {
        switch self {
        case .text: return L10n.string("控制台")
        case .table: return L10n.string("表格")
        case .image: return L10n.string("图形")
        case .message: return L10n.string("消息")
        case .warning: return L10n.string("警告")
        case .error: return L10n.string("错误")
        case .rich(let output): return output.title.isEmpty ? L10n.string("富结果") : output.title
        }
    }
    var symbol: String {
        switch self {
        case .text: return "terminal"
        case .table: return "tablecells"
        case .image: return "chart.xyaxis.line"
        case .message: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "exclamationmark.circle"
        case .rich: return "doc.richtext"
        }
    }
    static func samples(for label: String?) -> [RecordOutputEvent] {
        if label == "preview-data" {
            let fixtures: [RecordOutputEvent] = [.text(L10n.string("head(data1) · 示例数据")),
                    .table(["sample_id", "reference", "candidate"], [
                        ["A01", "10.2", "10.5"], ["A02", "20.4", "20.1"], ["A03", "30.6", "30.9"],
                        ["A04", "40.8", "41.2"], ["A05", "51.0", "50.7"], ["A06", "61.2", "61.8"]]),
                    .message(L10n.string("表格展示示例，尚未运行 R。"))]
            if ProcessInfo.processInfo.environment["KAIL_OUTPUT_SCROLL_PROBE"] == "1" {
                return fixtures + samples(for: "preview-summary")
            }
            return fixtures
        }
        let image = NSImage(size: NSSize(width: 420, height: 180), flipped: false) { rect in
            NSColor.textBackgroundColor.setFill(); rect.fill()
            NSColor.secondaryLabelColor.setStroke()
            let axes = NSBezierPath(); axes.move(to: NSPoint(x: 35, y: 25)); axes.line(to: NSPoint(x: 35, y: 155))
            axes.move(to: NSPoint(x: 35, y: 25)); axes.line(to: NSPoint(x: 395, y: 25)); axes.stroke()
            NSColor.controlAccentColor.setStroke(); NSColor.controlAccentColor.setFill()
            let points = [NSPoint(x: 60, y: 42), NSPoint(x: 125, y: 64), NSPoint(x: 195, y: 90), NSPoint(x: 270, y: 115), NSPoint(x: 360, y: 142)]
            let line = NSBezierPath(); line.move(to: points[0]); for p in points.dropFirst() { line.line(to: p) }; line.stroke()
            for p in points { NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill() }
            (L10n.string("图像示例 · 固定预置图形") as NSString).draw(at: NSPoint(x: 45, y: 158), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
        let kable = RecordRichOutput(title: "kable", representations: [
            .init(mime: "text/html", text: L10n.string("<table><thead><tr><th>样本</th><th>参考方法</th><th>候选方法</th></tr></thead><tbody><tr><td>A01</td><td style='text-align:right'>10.2</td><td style='text-align:right'>10.5</td></tr><tr><td>A02</td><td style='text-align:right'>20.4</td><td style='text-align:right'>20.1</td></tr></tbody></table>")),
            .init(mime: "text/plain", text: L10n.string("样本\t参考方法\t候选方法\nA01\t10.2\t10.5\nA02\t20.4\t20.1"))])
        let flextable = RecordRichOutput(title: "flextable", representations: [
            .init(mime: "text/html", text: L10n.string("<table><thead><tr><th rowspan='2' class='heading'>样本</th><th colspan='2' class='heading'>方法比较</th></tr><tr><th class='heading'>参考方法</th><th class='heading'>候选方法</th></tr></thead><tbody><tr><td>A01</td><td class='number'>10.2</td><td class='number'>10.5</td></tr><tr><td>A02</td><td class='number'>20.4</td><td class='number'>20.1</td></tr></tbody></table>")),
            .init(mime: "text/plain", text: L10n.string("样本\t参考方法\t候选方法\nA01\t10.2\t10.5\nA02\t20.4\t20.1"))],
            styles: [".heading{background-color:#e8edf4;font-weight:bold;text-align:center;border-bottom:1px solid #8896a8}.number{text-align:right}"])
        return [.text(L10n.string("summary(data1) · 示例输出\nreference    candidate\n10.2–61.2    10.5–61.8")), .image(image),
                .text(L10n.string("控制台输出 2 · 示例\n图形之后继续输出文字，按返回顺序保留。")), .image(image), .rich(kable), .rich(flextable),
                .message(L10n.string("消息示例：结果按代码块归属显示。")),
                .warning(L10n.string("警告示例：这里展示警告的呈现方式。")),
                .error(L10n.string("错误示例：错误信息保留在结果区，不改动源码。"))]
    }
}

/// A moving notebook result is not a window-level scroll surface. Use native
/// clipping and scrollers without registering nested NSScrollViews with the
/// window's title-bar/scroll-edge machinery.
@MainActor final class RecordOutputViewport: NSView {
    // A non-text result and its empty padding are an interaction surface of
    // their own. NSImageView may forward mouseDown through the responder chain;
    // stop it here instead of placing a caret in the enclosing source editor.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { }
    override func mouseDragged(with event: NSEvent) { }

    let contentView = NSClipView()
    private let headerClip = NSClipView()
    private let vertical = NSScroller()
    private let horizontal = NSScroller()
    var hasVerticalScroller = false { didSet { needsLayout = true } }
    var hasHorizontalScroller = false { didSet { needsLayout = true } }
    // Rich NSTextTable borders must not sit beneath the native overlay knob.
    // Other result surfaces and the editor's full-width/minimap scroll view keep
    // their existing geometry.
    var reservesVerticalScrollerSpace = false { didSet { needsLayout = true } }
    var documentView: NSView? {
        get { contentView.documentView }
        set {
            if let old = contentView.documentView { NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: old) }
            contentView.documentView = newValue
            headerClip.documentView = (newValue as? NSTableView)?.headerView
            if let newValue {
                newValue.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(documentChanged), name: NSView.frameDidChangeNotification, object: newValue)
            }
            needsLayout = true
        }
    }
    var contentSize: NSSize {
        NSSize(width: max(0, bounds.width - verticalScrollerGutter), height: max(0, bounds.height - headerHeight))
    }
    var verticalScrollerGutter: CGFloat {
        reservesVerticalScrollerSpace && hasVerticalScroller ? NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay) : 0
    }
    private var headerHeight: CGFloat { headerClip.documentView == nil ? 0 : 22 }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        for clip in [contentView, headerClip] { clip.drawsBackground = false; clip.clipsToBounds = true; addSubview(clip) }
        for scroller in [vertical, horizontal] {
            scroller.scrollerStyle = .overlay; scroller.controlSize = .small
            scroller.target = self; scroller.action = #selector(scrollerChanged(_:)); addSubview(scroller)
        }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        setAccessibilityElement(true); setAccessibilityRole(.scrollArea)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func documentChanged(_ notification: Notification) { needsLayout = true }
    @objc private func boundsChanged(_ notification: Notification) { updateScrollers() }
    override func layout() {
        super.layout()
        headerClip.isHidden = headerHeight == 0
        headerClip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        headerClip.documentView?.frame.size = NSSize(width: documentView?.frame.width ?? bounds.width, height: headerHeight)
        contentView.frame = NSRect(x: 0, y: headerHeight, width: contentSize.width, height: contentSize.height)
        let thickness = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
        vertical.frame = NSRect(x: max(0, bounds.width - thickness), y: headerHeight, width: thickness, height: contentSize.height)
        horizontal.frame = NSRect(x: 0, y: max(0, bounds.height - thickness), width: bounds.width, height: thickness)
        scroll(to: contentView.bounds.origin)
    }
    func scroll(to point: NSPoint) {
        var proposed = contentView.bounds; proposed.origin = point
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        updateScrollers()
    }
    private func updateScrollers() {
        let size = documentView?.frame.size ?? .zero, visible = contentView.bounds
        let maxX = max(0, size.width - visible.width), maxY = max(0, size.height - visible.height)
        vertical.isHidden = !hasVerticalScroller || maxY <= 0.5
        horizontal.isHidden = !hasHorizontalScroller || maxX <= 0.5
        vertical.knobProportion = min(1, visible.height / max(1, size.height))
        horizontal.knobProportion = min(1, visible.width / max(1, size.width))
        vertical.doubleValue = maxY > 0 ? visible.minY / maxY : 0
        horizontal.doubleValue = maxX > 0 ? visible.minX / maxX : 0
        headerClip.scroll(to: NSPoint(x: visible.minX, y: 0))
    }
    override func scrollWheel(with event: NSEvent) {
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let old = contentView.bounds.origin
        scroll(to: NSPoint(x: old.x - event.scrollingDeltaX * multiplier, y: old.y - event.scrollingDeltaY * multiplier))
        if contentView.bounds.origin == old { super.scrollWheel(with: event) }
    }
    @objc private func scrollerChanged(_ scroller: NSScroller) {
        var point = contentView.bounds.origin
        let isVertical = scroller === vertical
        let size = documentView?.frame.size ?? .zero
        let visible = isVertical ? contentView.bounds.height : contentView.bounds.width
        let maximum = max(0, (isVertical ? size.height : size.width) - visible)
        var offset = isVertical ? point.y : point.x
        switch scroller.hitPart {
        case .decrementLine: offset -= 20
        case .incrementLine: offset += 20
        case .decrementPage: offset -= visible * 0.9
        case .incrementPage: offset += visible * 0.9
        default: offset = CGFloat(scroller.doubleValue) * maximum
        }
        if isVertical { point.y = offset } else { point.x = offset }
        scroll(to: point)
    }
}

@MainActor final class RecordOutputItem: NSView, NSTableViewDataSource {
    // A non-text result and its empty padding are an interaction surface of
    // their own. NSImageView may forward mouseDown through the responder chain;
    // stop it here instead of placing a caret in the enclosing source editor.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { }
    override func mouseDragged(with event: NSEvent) { }

    let event: RecordOutputEvent
    private let label = NSTextField(wrappingLabelWithString: "")
    private let symbol = NSImageView()
    private var text: NSTextView?
    private var textClip: NSClipView?
    private var scroll: RecordOutputViewport?
    private var image: NSImageView?
    private var rows: [[String]] = []
    private var tableRowHeight: CGFloat = 23
    private var rich: RecordRichOutputView?
    override var isFlipped: Bool { true }
    init(event: RecordOutputEvent, font: NSFont, bodyFont: NSFont? = nil) {
        let bodyFont = bodyFont ?? font
        self.event = event
        super.init(frame: .zero)
        switch event {
        case .text(let value):
            let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.drawsBackground = false; text.font = font; text.string = value; text.textContainerInset = NSSize(width: 2, height: 3)
            text.textColor = .labelColor
            // The result body measures and sets this read-only surface's frame.
            // Automatic NSTextView resizing expects an NSClipView parent and
            // otherwise registers expensive unrelated frame observers.
            text.isVerticallyResizable = false
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.heightTracksTextView = false
            text.textContainer?.lineFragmentPadding = 0
            let clip = NSClipView(); clip.drawsBackground = false
            clip.documentView = text
            addSubview(clip); self.text = text; textClip = clip
        case .table(let headings, let values):
            rows = values
            let table = NSTableView()
            tableRowHeight = ceil(max(23, bodyFont.ascender - bodyFont.descender + bodyFont.leading + 7))
            table.rowHeight = tableRowHeight; table.usesAlternatingRowBackgroundColors = true
            table.style = .plain; table.gridStyleMask = .solidHorizontalGridLineMask
            table.dataSource = self; table.allowsColumnResizing = true
            for (index, heading) in headings.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = heading; column.headerCell.font = bodyFont; column.width = max(120, CGFloat(heading.count * 8 + 28)); column.minWidth = 90
                column.isEditable = false
                let cell = NSTextFieldCell(); cell.font = bodyFont; cell.isEditable = false; cell.isSelectable = true; column.dataCell = cell
                table.addTableColumn(column)
            }
            let scroll = RecordOutputViewport(frame: .zero); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.documentView = table
            addSubview(scroll); self.scroll = scroll
        case .image(let value, let pngData):
            let view = RecordResultImageView(frame: .zero); view.image = value; view.originalPNG = pngData
            addSubview(view); image = view
        case .rich(let output):
            let view = RecordRichOutputView(output: output, font: bodyFont)
            addSubview(view); rich = view
        case .message(let value), .warning(let value), .error(let value):
            label.stringValue = value; label.font = bodyFont; label.isSelectable = true
            let name: String, color: NSColor
            switch event {
            case .warning: name = "exclamationmark.triangle"; color = .systemOrange
            case .error: name = "exclamationmark.circle"; color = .systemRed
            default: name = "info.circle"; color = .secondaryLabelColor
            }
            symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil); symbol.contentTintColor = color
            addSubview(symbol); addSubview(label)
        }
    }
    required init?(coder: NSCoder) { nil }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let index = tableColumn.flatMap({ Int($0.identifier.rawValue) }), row < rows.count, index < rows[row].count else { return nil }
        return rows[row][index]
    }
    func measuredHeight(width: CGFloat) -> CGFloat {
        switch event {
        case .text(let value):
            let height = (value as NSString).boundingRect(with: NSSize(width: max(30, width - 4), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text?.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).height
            return max(28, ceil(height) + 12)
        case .table: return min(190, CGFloat(rows.count) * tableRowHeight + 28)
        case .image(let value, _): return min(1600, max(80, min(width, value.size.width) * value.size.height / max(1, value.size.width)))
        case .rich: return rich?.desiredHeight(width: width) ?? 100
        default:
            return max(26, ceil(label.attributedStringValue.boundingRect(with: NSSize(width: max(30, width - 28), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 8)
        }
    }
    override func layout() {
        super.layout()
        textClip?.frame = bounds
        text?.frame = bounds
        text?.textContainer?.containerSize = NSSize(width: max(1, bounds.width - 4), height: .greatestFiniteMagnitude)
        scroll?.frame = bounds; image?.frame = bounds; rich?.frame = bounds
        symbol.frame = NSRect(x: 1, y: 5, width: 14, height: 14)
        label.frame = NSRect(x: 24, y: 3, width: max(1, bounds.width - 24), height: max(1, bounds.height - 6))
    }
}

@MainActor private final class RecordResultBody: NSView {
    override var isFlipped: Bool { true }
    var items: [RecordOutputItem] = []
    func arrange(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for item in items {
            let height = item.measuredHeight(width: width)
            item.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + 8
        }
        frame.size = NSSize(width: width, height: max(0, y - 8))
        return frame.height
    }
}

/// Host-only companions to Edmund's drawn copy button. Never takes text focus
/// on a mouse click; an unrevealed button does not intercept editor gestures.
@MainActor final class RecordMarginButton: NSButton {
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(visibleRect, cursor: .arrow) }
    var revealed = false { didSet { if oldValue != revealed { needsDisplay = true } } }
    var ink: NSColor = .secondaryLabelColor
    var hoverFill: NSColor = .quaternaryLabelColor
    var symbol = "play.fill" { didSet { if oldValue != symbol { needsDisplay = true } } }
    var pointerInside = false { didSet { if oldValue != pointerInside { needsDisplay = true } } }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard revealed else { return nil }
        return super.hitTest(point)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard revealed || window?.firstResponder === self else { return }
        let glyphBox = bounds.insetBy(dx: 4, dy: 4)
        if pointerInside || isHighlighted || window?.firstResponder === self {
            hoverFill.setFill()
            // Edmund paints 3pt outside its glyph slot, inside a 4pt hit inset.
            NSBezierPath(roundedRect: glyphBox.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4).fill()
        }
        let size = max(1, glyphBox.width)
        let color = isEnabled ? ink : ink.withAlphaComponent(0.4)
        guard let full = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return }
        let pointSize = size * min(size / full.size.width, size / full.size.height)
        let image = full.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))) ?? full
        image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                              width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    func configure(label: String, id: String) {
        title = ""; isBordered = false; imagePosition = .imageOnly; bezelStyle = .inline
        setAccessibilityElement(true); setAccessibilityRole(.button)
        toolTip = label; setAccessibilityLabel(label); setAccessibilityIdentifier(id)
    }
}

@MainActor class RecordMarginActions: NSView {
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(visibleRect, cursor: .arrow) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("结果操作"))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor private final class RecordResultTabButton: NSButton {
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(visibleRect, cursor: .arrow) }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        if selected || isHighlighted {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = selected ? .labelColor : .secondaryLabelColor
        let textFont = font ?? NSFont.systemFont(ofSize: 13)
        let iconSide = max(10, textFont.pointSize)
        let icon = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconSide, weight: .regular).applying(.init(paletteColors: [color])))
        icon?.draw(in: NSRect(x: 6, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let label = NSAttributedString(string: title, attributes: [.font: textFont, .foregroundColor: color])
        label.draw(in: NSRect(x: iconSide + 11, y: (bounds.height - label.size().height) / 2, width: max(0, bounds.width - iconSide - 15), height: label.size().height))
    }
}

@MainActor final class RecordOutputShelf: NSView {
    // A non-text result and its empty padding are an interaction surface of
    // their own. NSImageView may forward mouseDown through the responder chain;
    // stop it here instead of placing a caret in the enclosing source editor.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { }
    override func mouseDragged(with event: NSEvent) { }

    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(visibleRect, cursor: .arrow) }
    let titleLabel = NSTextField(labelWithString: "")
    let statusIcon = NSImageView()
    private let tabsScroll = RecordOutputViewport(frame: .zero)
    private let tabs = RecordResultBody()
    private let previousTab = NSButton()
    private let nextTab = NSButton()
    private(set) var tabButtons: [NSButton] = []
    private var selectedIndex = 0
    private var revealSelection = false
    let toggle = RecordMarginButton()
    let clear = RecordMarginButton()
    /// Sibling margin controls; their space is outside the result content.
    let actions = RecordMarginActions()
    var frameColor: NSColor = .clear { didSet { if oldValue != frameColor { needsDisplay = true } } }
    var contentBackground: NSColor = .textBackgroundColor { didSet { if oldValue != contentBackground { needsDisplay = true } } }
    private let bodyScroll = RecordOutputViewport(frame: .zero)
    private let body = RecordResultBody()
    private var signature = ""
    private var statusSignature = ""
    private var collapsed = false
    private var headerHeight: CGFloat = 34
    private var headerIconSize: CGFloat = 15
    private var showsImage = false
    var onToggle: (() -> Void)?
    var onClear: (() -> Void)?
    var onSelect: ((Int) -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium); titleLabel.lineBreakMode = .byTruncatingTail
        configureButton(toggle, symbol: "chevron.down", label: L10n.string("收起结果"), action: #selector(togglePressed))
        configureButton(clear, symbol: "trash", label: L10n.string("删除结果"), action: #selector(clearPressed))
        bodyScroll.hasVerticalScroller = true
        bodyScroll.documentView = body
        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.setAccessibilityElement(true); statusIcon.setAccessibilityRole(.image)
        tabsScroll.documentView = tabs
        tabsScroll.contentView.documentCursor = .arrow
        tabsScroll.clipsToBounds = true; tabsScroll.contentView.clipsToBounds = true
        bodyScroll.clipsToBounds = true; bodyScroll.contentView.clipsToBounds = true
        tabs.setAccessibilityElement(true); tabs.setAccessibilityRole(.group); tabs.setAccessibilityLabel(L10n.string("结果选项卡"))
        for view in [statusIcon, tabsScroll, bodyScroll, titleLabel] { addSubview(view) }
        for (button, symbol, label, action) in [(previousTab, "chevron.left", L10n.string("前一个结果"), #selector(previousPressed)), (nextTab, "chevron.right", L10n.string("下一个结果"), #selector(nextPressed))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly; button.isBordered = false; button.controlSize = .small
            button.target = self; button.action = action; button.toolTip = label
            button.setAccessibilityLabel(label); addSubview(button)
        }
        actions.addSubview(toggle); actions.addSubview(clear)
        actions.setAccessibilityChildren([toggle, clear])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("示例结果"))
    }
    required init?(coder: NSCoder) { nil }
    private func configureButton(_ button: RecordMarginButton, symbol: String, label: String, action: Selector) {
        button.symbol = symbol; button.configure(label: label, id: "")
        button.target = self; button.action = action
    }
    @objc private func togglePressed() { onToggle?() }
    @objc private func clearPressed() { onClear?() }
    func configure(id: String, state: RecordOutputLayout.State, stale: Bool, font: NSFont, bodyFont: NSFont? = nil) {
        let bodyFont = bodyFont ?? font
        headerHeight = max(34, ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading) + 12)
        headerIconSize = max(15, bodyFont.pointSize)
        titleLabel.font = bodyFont
        let status = state.skipped ? L10n.string("本次已跳过 · eval 禁用") + (state.events.isEmpty ? "" : L10n.string(" · 保留旧结果")) : stale ? L10n.string("代码或会话已变化 · 历史结果") : state.isSample
            ? (state.running ? L10n.string("运行中（预览）") : state.stopped ? L10n.string("已停止（预览）") : L10n.string("未运行 R")) : state.phase
        titleLabel.stringValue = (state.isSample ? L10n.string("示例结果 · ") : L10n.string("R 输出 · ")) + status + (state.runSummary.map { " · " + $0 } ?? "")
        titleLabel.toolTip = titleLabel.stringValue
        titleLabel.isHidden = !state.skipped && state.runSummary == nil && state.manualNote == nil
        titleLabel.setAccessibilityIdentifier("visual-result-note-" + id)
        titleLabel.textColor = .secondaryLabelColor
        let symbol = state.skipped ? "forward.end" : stale ? "clock.arrow.circlepath" : state.running ? "hourglass" : state.stopped ? "stop.circle" : state.failed ? "exclamationmark.circle" : state.isSample ? "circle.dashed" : "checkmark.circle"
        if statusSignature != id + titleLabel.stringValue {
            needsLayout = true
            statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status)
            statusIcon.contentTintColor = .secondaryLabelColor
            statusIcon.toolTip = titleLabel.stringValue; statusIcon.setAccessibilityLabel(titleLabel.stringValue)
            statusIcon.setAccessibilityIdentifier("visual-result-status-" + id)
            setAccessibilityLabel(titleLabel.stringValue)
            statusSignature = id + titleLabel.stringValue
        }
        let changedCollapse = collapsed != state.collapsed
        collapsed = state.collapsed
        let action = collapsed ? L10n.string("展开结果") : L10n.string("收起结果")
        toggle.symbol = collapsed ? "chevron.right" : "chevron.down"
        toggle.toolTip = action; toggle.setAccessibilityLabel(action)
        toggle.setAccessibilityIdentifier("visual-result-toggle-" + id)
        clear.setAccessibilityIdentifier("visual-result-delete-" + id)
        setAccessibilityIdentifier("visual-result-" + id)
        bodyScroll.isHidden = collapsed
        let index = state.events.indices.contains(state.selectedOutputIndex) ? state.selectedOutputIndex : 0
        showsImage = state.events.indices.contains(index) && { if case .image = state.events[index] { return true }; return false }()
        let changedSelection = selectedIndex != index
        selectedIndex = index
        let next = "\(state.contentID)|\(font.fontName)|\(font.pointSize)|\(bodyFont.fontName)|\(bodyFont.pointSize)|\(index)"
        if signature != next {
            for view in body.subviews { view.removeFromSuperview() }
            // Only the selected output allocates its native rendering surface.
            body.items = state.events.indices.contains(index) ? [RecordOutputItem(event: state.events[index], font: font, bodyFont: bodyFont)] : []
            for item in body.items { body.addSubview(item) }
            for button in tabButtons { button.removeFromSuperview() }
            var counts: [String: Int] = [:]
            tabButtons = state.events.enumerated().map { offset, event in
                counts[event.tabKind, default: 0] += 1
                let button = RecordResultTabButton(title: event.tabKind + " " + String(counts[event.tabKind]!), target: self, action: #selector(selectPressed(_:)))
                button.setButtonType(.pushOnPushOff); button.bezelStyle = .inline; button.controlSize = .small
                button.font = bodyFont; button.imagePosition = .imageLeading
                button.image = NSImage(systemSymbolName: event.symbol, accessibilityDescription: nil)
                button.imageScaling = .scaleProportionallyDown; button.tag = offset
                button.state = offset == index ? .on : .off
                button.setAccessibilityValue(offset == index ? 1 : 0)
                button.toolTip = button.title
                button.setAccessibilityLabel(button.title); button.setAccessibilityRole(.radioButton)
                button.setAccessibilityIdentifier("visual-result-tab-" + id + "-" + String(offset))
                tabs.addSubview(button)
                return button
            }
            tabs.setAccessibilityChildren(tabButtons)
            signature = next
            revealSelection = true
        }
        previousTab.isEnabled = index > 0; nextTab.isEnabled = index + 1 < state.events.count
        for (offset, button) in tabButtons.enumerated() {
            // Clicking the active tab must not toggle its visual state off.
            let desired: NSControl.StateValue = offset == index ? .on : .off
            if button.state != desired {
                button.state = desired; button.needsDisplay = true
                button.setAccessibilityValue(offset == index ? 1 : 0)
            }
        }
        previousTab.setAccessibilityIdentifier("visual-result-previous-" + id)
        nextTab.setAccessibilityIdentifier("visual-result-next-" + id)
        if revealSelection || changedSelection || changedCollapse { needsLayout = true }
    }
    @objc private func selectPressed(_ button: NSButton) { onSelect?(button.tag) }
    @objc private func previousPressed() { onSelect?(max(0, selectedIndex - 1)) }
    @objc private func nextPressed() { onSelect?(min(tabButtons.count - 1, selectedIndex + 1)) }
    func desiredHeight(width: CGFloat) -> CGFloat {
        let minimum = max(headerHeight + 2, actions.frame.height)
        if collapsed { return minimum }
        let contentHeight = body.arrange(width: max(40, width - 24))
        return max(minimum, headerHeight + 16 + (showsImage ? contentHeight : min(340, contentHeight)))
    }
    private func tabWidth(_ button: NSButton) -> CGFloat {
        let font = button.font ?? NSFont.systemFont(ofSize: 13)
        return max(68, ceil((button.title as NSString).size(withAttributes: [.font: font]).width) + max(10, font.pointSize) + 22)
    }
    override func layout() {
        super.layout()
        statusIcon.frame = NSRect(x: 10, y: (headerHeight - headerIconSize) / 2, width: headerIconSize, height: headerIconSize)
        let tabStart = statusIcon.frame.maxX + 8
        let arrowWidth = max(16, headerIconSize)
        // A previously hidden/truncated NSTextField can report a cached 2pt
        // intrinsic width. Measure the actual native font independently.
        let noteSize = (titleLabel.stringValue as NSString).size(withAttributes: [.font: titleLabel.font ?? NSFont.systemFont(ofSize: 12)])
        let noteWidth = titleLabel.isHidden ? 0 : min(max(0, bounds.width - tabStart - 110), min(bounds.width * 0.55, ceil(noteSize.width) + 4))
        let headerEnd = bounds.width - (noteWidth > 0 ? noteWidth + 16 : 0)
        let noteHeight = ceil(noteSize.height) + 2
        titleLabel.frame = NSRect(x: headerEnd + 6, y: (headerHeight - noteHeight) / 2,
                                 width: noteWidth, height: noteHeight)
        let totalWidth = tabButtons.reduce(CGFloat(0)) { $0 + tabWidth($1) + 4 }
        let overflow = totalWidth > headerEnd - tabStart - 8
        previousTab.isHidden = !overflow; nextTab.isHidden = !overflow
        previousTab.frame = NSRect(x: headerEnd - arrowWidth * 2 - 9, y: 4, width: arrowWidth, height: headerHeight - 8)
        nextTab.frame = NSRect(x: headerEnd - arrowWidth - 5, y: 4, width: arrowWidth, height: headerHeight - 8)
        tabsScroll.frame = NSRect(x: tabStart, y: 2, width: max(1, headerEnd - tabStart - (overflow ? arrowWidth * 2 + 14 : 8)), height: headerHeight - 2)
        var x: CGFloat = 0
        for button in tabButtons {
            let width = tabWidth(button)
            button.frame = NSRect(x: x, y: 2, width: width, height: headerHeight - 6)
            x += width + 4
        }
        tabs.frame.size = NSSize(width: max(1, x), height: headerHeight - 2)
        if revealSelection, tabButtons.indices.contains(selectedIndex) {
            tabButtons[selectedIndex].scrollToVisible(tabButtons[selectedIndex].bounds)
            revealSelection = false
        }
        bodyScroll.frame = NSRect(x: 12, y: headerHeight + 6, width: max(1, bounds.width - 24), height: max(0, bounds.height - headerHeight - 16))
        _ = body.arrange(width: max(40, bodyScroll.contentSize.width))
    }
    override func draw(_ dirtyRect: NSRect) {
        contentBackground.setFill(); bounds.fill()
        // All four edges use the native code background, not a separator tint.
        frameColor.setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: 0.5, y: 0))
        edge.line(to: NSPoint(x: 0.5, y: bounds.maxY - 0.5))
        edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY - 0.5))
        edge.line(to: NSPoint(x: bounds.maxX - 0.5, y: 0))
        edge.close()
        edge.lineWidth = 1
        edge.stroke()
    }
}

@MainActor final class RecordCodeActions: RecordMarginActions {
    let run = RecordMarginButton()
    let format = RecordMarginButton()
    var hoverRect = NSRect.zero
    var onRun: (() -> Void)?
    var onFormat: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        run.target = self; run.action = #selector(runPressed); addSubview(run)
        format.target = self; format.action = #selector(formatPressed); format.symbol = "text.alignleft"; addSubview(format)
        setAccessibilityChildren([run, format])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("代码块操作"))
    }
    required init?(coder: NSCoder) { nil }
    @objc private func runPressed() { onRun?() }
    @objc private func formatPressed() { onFormat?() }
    func configure(_ block: RecordVisualBlockIndex.Block, running: Bool) {
        run.symbol = running ? "stop.fill" : "play.fill"
        run.isEnabled = block.canRun
        run.isHidden = block.language != "r"
        let label = running ? L10n.string("停止当前块") : L10n.string("运行当前块")
        run.configure(label: label, id: "visual-code-run-" + block.id)
        run.toolTip = block.canRun ? label + ((!block.options.enabled || !block.options.evaluate) ? " · " + L10n.string("手动运行，忽略 eval 禁用") : "") + "\n" + block.options.explanation : block.reason
        format.configure(label: L10n.string("格式化 R 代码块"), id: "visual-code-format-" + block.id)
        setAccessibilityIdentifier("visual-code-actions-" + block.id)
    }
    override func layout() {
        super.layout()
        let side = bounds.width
        run.frame = NSRect(x: 0, y: 0, width: side, height: side)
        format.frame = run.frame.offsetBy(dx: 0, dy: side + 2)
    }
}

@MainActor final class RecordOutputLayout: NSResponder {
    struct State {
        let hash: String
        var collapsed = false
        var cleared = false
        var running = false
        var stopped = false
        var isSample = true
        var failed = false
        var skipped = false
        var runSummary: String?
        var manualNote: String?
        var phase = L10n.string("已完成")
        var sessionID: UUID?
        var taskID: UUID?
        var events: [RecordOutputEvent] = [] {
            didSet {
                contentID = UUID().uuidString
                if !events.indices.contains(selectedOutputIndex) { selectedOutputIndex = 0 }
            }
        }
        var contentID = UUID().uuidString
        var selectedOutputIndex = 0
    }
    let editor: EditorTextView
    let model: RecordLayoutModel
    var states: [String: State] { get { model.outputStates } set { model.outputStates = newValue } }
    var shelves: [String: RecordOutputShelf] = [:]
    var codeActions: [String: RecordCodeActions] = [:]
    private var hoverMonitor: Any?
    private var resultOwnsCursor = false
    private var pointerRefreshPending = false
    private var cursorRectsNeedRefresh = false
    private let cursorProbeEnabled = ProcessInfo.processInfo.environment["KAIL_RESULT_CURSOR_PROBE"] == "1"
    private var detached = false
    var applying = false
    var pending = false
    var applyCount = 0
    private(set) var viewportRefreshCount = 0
    private var viewportPending = false
    private var appliedWidth: CGFloat?
    private var appliedSource: Data?
    private var paragraphRects: [Int: NSRect] = [:]
    private var paragraphAdvances: [Int: CGFloat] = [:]
    private var visibleParagraphs = Set<Int>()
    private struct ViewportStamp: Equatable {
        let bounds: NSRect
        let start: Int
        let end: Int
        let frames: [NSRect]
    }
    private var viewportStamp: ViewportStamp?
    func settleViewport() {
        guard !detached, !applying else { return }
        refreshViewport()
    }
    var hidesForSource = false
    var onApplyTiming: ((Double) -> Void)?
    var editorChromeCursor: ((NSPoint) -> NSCursor?)?
    var editorChromeRects: (() -> [NSRect])?
    func refreshExecutionControls() {
        guard !hidesForSource else { return }
        let current = blocks()
        for (id, actions) in codeActions {
            guard let block = current.first(where: { $0.id == id }) else { continue }
            let running = model.notebook.isBusy && model.notebook.activeBlockID == id
            actions.configure(block, running: running || states[id]?.running == true)
            if !model.usesSampleOutputs {
                actions.run.isEnabled = block.canRun && (!model.notebook.isBusy || running)
            }
        }
    }
    init(editor: EditorTextView, model: RecordLayoutModel) {
        self.editor = editor; self.model = model
        super.init()
        editor.embeddedViewCursor = { [weak self] point in
            guard let self else { return nil }
            let cursor = self.resultCursor(at: point)
            if cursor != nil { self.resultOwnsCursor = true }
            self.probePointer(at: point, cursor: cursor)
            return cursor
        }
        editor.embeddedViewRects = { [weak self] in
            guard let self, !self.detached else { return [] }
            let chrome = self.editorChromeRects?() ?? []
            guard !self.hidesForSource else { return chrome }
            return chrome + self.shelves.values.filter { !$0.isHidden }.flatMap { [$0.frame, $0.actions.frame] }
                + self.codeActions.values.filter { !$0.isHidden }.map(\.frame)
        }
        if model.usesSampleOutputs, !model.didSeedVisualOutputs {
            for block in blocks() {
                if let hash = RecordLayoutModel.fixtureHash(label: block.label) {
                    states[block.id] = State(hash: hash, events: RecordOutputEvent.samples(for: block.label))
                }
            }
            model.didSeedVisualOutputs = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(prepareResultSpacing), name: NSTextStorage.willProcessEditingNotification, object: editor.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
        editor.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: editor)
        if let clip = editor.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        // Nested result viewports also move content underneath a stationary
        // pointer. Observe their clips without reapplying the notebook layout.
        NotificationCenter.default.addObserver(self, selector: #selector(resultClipChanged), name: NSView.boundsDidChangeNotification, object: nil)
        // A second mouseMoved tracking area on the text view can take events
        // away from Edmund's native copy/table hover pass. Keep its area as
        // the sole mouseMoved owner; only resolve moves over host controls.
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Events in other windows must not reset this editor's ownership.
            guard event.window === self.editor.window else { return event }
            if event.type == .scrollWheel {
                self.schedulePointerRefresh()
                return event
            }
            self.observeHover(event)
            // NSTextView's private enter/exit tracking can set its I-beam
            // after the public cursorUpdate callback. Reconcile once after
            // native boundary dispatch, without consuming the original event.
            if event.type == .mouseEntered || event.type == .mouseExited { self.schedulePointerRefresh() }
            // Native children such as table headers may own mouseMoved and
            // bypass the enclosing editor's callback. Also resolve their final
            // cursor after dispatch, including leaving a column resize edge.
            if event.type == .mouseMoved,
               self.resultOwnsCursor || self.resultCursor(at: self.editor.convert(event.locationInWindow, from: nil)) != nil {
                self.schedulePointerRefresh()
            }
            return event
        }
    }
    required init?(coder: NSCoder) { nil }
    func detach() {
        detached = true
        if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor) }
        hoverMonitor = nil
        editor.embeddedViewCursor = nil
        editor.embeddedViewRects = nil
        for view in Array(shelves.values).flatMap({ [$0, $0.actions] }) + Array(codeActions.values) {
            for area in view.trackingAreas where area.owner === self { view.removeTrackingArea(area) }
        }
        NotificationCenter.default.removeObserver(self)
        editor.minSize.height = 0
    }
    func observeHover(_ event: NSEvent) {
        guard !detached else { return }
        // Child text/table/scroll controls emit mouseExited while the pointer
        // is still inside the result. Reveal state belongs to the whole band.
        // A click may arrive without a preceding mouseMoved (fast movement,
        // scrolling beneath a stationary pointer, or window activation).
        // Reveal before NSWindow hit-testing, then let the native button
        // track mouse-up/cancellation; do not execute or consume the event.
        guard let window = editor.window, event.window === window,
              window.isKeyWindow || event.type == .leftMouseDown else { updateHover(at: nil); return }
        updateHover(at: editor.convert(event.locationInWindow, from: nil))
    }
    /// Use the actual frontmost child, including its clip, rather than a fixed
    /// header band or a result's unclipped frame. Selectable output keeps its
    /// I-beam; images, padding, tabs and controls use the arrow.
    func resultCursor(at point: NSPoint) -> NSCursor? {
        guard !detached else { return nil }
        if let cursor = editorChromeCursor?(point) { return cursor }
        guard !detached, !hidesForSource, editor.visibleRect.contains(point),
              let root = editor.window?.contentView,
              let hit = root.hitTest(editor.convert(point, to: root.superview)),
              shelves.values.contains(where: { !$0.isHidden && (hit.isDescendant(of: $0) || hit.isDescendant(of: $0.actions)) })
                || codeActions.values.contains(where: { !$0.isHidden && hit.isDescendant(of: $0) }) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== editor {
            if current is NSButton || current is NSScroller { return .arrow }
            if let header = current as? NSTableHeaderView, let table = header.tableView, table.allowsColumnResizing {
                let local = header.convert(point, from: editor)
                for column in table.tableColumns.indices where table.tableColumns[column].resizingMask.contains(.userResizingMask) {
                    if abs(local.x - header.headerRect(ofColumn: column).maxX) <= 3 { return .resizeLeftRight }
                }
                return .arrow
            }
            if let text = current as? NSTextView, text.isSelectable { return .iBeam }
            if let field = current as? NSTextField, field.isSelectable { return .iBeam }
            view = current.superview
        }
        return .arrow
    }
    @discardableResult private func updatePointerCursor(at point: NSPoint, event: NSEvent? = nil) -> Bool {
        guard !detached, let window = editor.window, window.isKeyWindow else { return false }
        let cursor = resultCursor(at: point)
        probePointer(at: point, cursor: cursor)
        if let cursor {
            if !resultOwnsCursor, let event { editor.mouseExited(with: event) }
            resultOwnsCursor = true
            cursor.set()
            return true
        }
        // A result may scroll away without another mouse event. Restore the
        // editor only when it is now the hit view, never over another control.
        if resultOwnsCursor, editor.visibleRect.contains(point),
           let root = window.contentView,
           root.hitTest(editor.convert(point, to: root.superview)) === editor {
            NSCursor.iBeam.set()
        }
        resultOwnsCursor = false
        return false
    }
    private func probePointer(at point: NSPoint, cursor: NSCursor?) {
        if cursorProbeEnabled, let window = editor.window {
            let root = window.contentView!
            let hit = root.hitTest(editor.convert(point, to: root.superview))
            let name = cursor == .iBeam ? "text" : cursor == .arrow ? "arrow" : cursor == .resizeLeftRight ? "resize" : "native"
            let line = "CURSOR point=\(point) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") target=\(name)\n"
            FileHandle.standardError.write(Data(line.utf8))
            DispatchQueue.main.async {
                let current = NSCursor.current
                let actual = current == .iBeam ? "text" : current == .arrow ? "arrow" : current == .resizeLeftRight ? "resize" : "other"
                FileHandle.standardError.write(Data("CURSOR settled=\(actual)\n".utf8))
            }
        }
    }
    override func cursorUpdate(with event: NSEvent) {
        _ = updatePointerCursor(at: editor.convert(event.locationInWindow, from: nil), event: event)
    }
    private func trackPointer(in view: NSView) {
        // Track the host's child surfaces, not the enclosing NSTextView. This
        // receives cursorUpdate after NSWindow has resolved cursor rectangles,
        // and leaves Edmund's own mouseMoved area/hover handling untouched.
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        view.addTrackingArea(area)
    }
    private func refreshPointer(invalidateCursorRects: Bool = false) {
        guard !detached, let window = editor.window, window.isKeyWindow else { updateHover(at: nil); return }
        if invalidateCursorRects { window.invalidateCursorRects(for: editor) }
        let point = editor.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(at: point)
        _ = updatePointerCursor(at: point)
    }
    private func schedulePointerRefresh(invalidateCursorRects: Bool = false) {
        cursorRectsNeedRefresh = cursorRectsNeedRefresh || invalidateCursorRects
        guard !pointerRefreshPending, !detached else { return }
        pointerRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pointerRefreshPending = false
            let invalidate = self.cursorRectsNeedRefresh
            self.cursorRectsNeedRefresh = false
            self.refreshPointer(invalidateCursorRects: invalidate)
        }
    }
    @objc private func resultClipChanged(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView, clip.isDescendant(of: editor) else { return }
        schedulePointerRefresh(invalidateCursorRects: true)
    }
    @objc private func windowBecameKey(_ notification: Notification) {
        if notification.object as? NSWindow === editor.window { schedulePointerRefresh(invalidateCursorRects: true) }
    }
    func updateHover(at point: NSPoint?) {
        let point = !hidesForSource && point.map(editor.visibleRect.contains) == true ? point : nil
        for actions in codeActions.values {
            let revealed = !actions.isHidden && point.map { actions.hoverRect.contains($0) || actions.frame.contains($0) } == true
            for button in [actions.run, actions.format] {
                button.revealed = revealed
                button.pointerInside = point.map { button.convert(button.bounds, to: editor).contains($0) } == true
            }
        }
        for shelf in shelves.values {
            let revealed = !shelf.isHidden && point.map { shelf.frame.union(shelf.actions.frame).contains($0) } == true
            for button in [shelf.toggle, shelf.clear] {
                button.revealed = revealed
                button.pointerInside = point.map { button.convert(button.bounds, to: editor).contains($0) } == true
            }
        }
    }
    @objc private func windowResignedKey(_ notification: Notification) {
        if let window = editor.window, notification.object as? NSWindow === window {
            updateHover(at: nil)
            resultOwnsCursor = false
        }
    }
    @objc func viewportChanged(_ notification: Notification) {
        guard !detached, !hidesForSource else { return }
        guard !viewportPending else { return }
        viewportPending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.detached else { return }
            self.viewportPending = false
            guard !self.applying else { self.viewportChanged(notification); return }
            let width = max(100, (self.editor.enclosingScrollView?.contentSize.width ?? self.editor.bounds.width) - 48)
            guard let appliedWidth = self.appliedWidth, abs(width - appliedWidth) < 0.5 else {
                self.changed(notification); return
            }
            self.refreshViewport()
        }
    }
    func layoutViewportDidComplete() {
        guard !detached, !applying else { return }
        let width = max(100, (editor.enclosingScrollView?.contentSize.width ?? editor.bounds.width) - 48)
        if let appliedWidth, abs(width - appliedWidth) >= 0.5 {
            viewportChanged(Notification(name: NSView.frameDidChangeNotification))
        }
        refreshViewport()
    }
    private func refreshViewport() {
        guard !hidesForSource, !editor.hasMarkedText(), !applying else { return }
        if let manager = editor.textLayoutManager, let viewport = manager.textViewportLayoutController.viewportRange {
            var frames: [NSRect] = []
            let end = manager.offset(from: manager.documentRange.location, to: viewport.endLocation)
            manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                let offset = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
                guard offset <= end else { return false }
                frames.append(fragment.layoutFragmentFrame); return true
            }
            let stamp = ViewportStamp(bounds: editor.visibleRect,
                start: manager.offset(from: manager.documentRange.location, to: viewport.location),
                end: end, frames: frames)
            guard viewportStamp != stamp else { return }
            viewportStamp = stamp
        }
        applying = true
        defer { applying = false }
        viewportRefreshCount += 1
        let current = blocks()
        cacheParagraphRects()
        positionShelves(current)
        positionCodeActions(current, updateState: false)
        publishAccessibility(current)
        schedulePointerRefresh()
    }
    func blocks() -> [RecordVisualBlockIndex.Block] { model.visualBlocks.blocks(in: editor.rawSource) }
    func stale(_ id: String) -> Bool {
        guard let state = states[id], let block = blocks().first(where: { $0.id == id }) else { return true }
        return state.hash != block.sourceHash || (!state.isSample && state.sessionID != model.notebook.sessionID)
    }
    func height(_ id: String) -> CGFloat {
        guard !hidesForSource, let state = states[id], !state.cleared else { return 0 }
        return shelves[id]?.desiredHeight(width: editor.enclosingScrollView?.contentSize.width ?? editor.bounds.width) ?? (state.collapsed ? 34 : 124)
    }
    @objc private func prepareResultSpacing(_ notification: Notification) {
        guard !detached, !applying, !hidesForSource, !editor.hasMarkedText(),
              let storage = editor.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let ns = storage.string as NSString
        var heights: [Int: CGFloat] = [:]
        // Character edits move paragraph identities before native layout runs.
        // Existing fragments retain their own margins; new fragments see the
        // remapped host dictionary without inheriting any paragraph attributes.
        for block in model.visualBlocks.blocks(in: storage.string) {
            guard states[block.id]?.cleared == false, let shelf = shelves[block.id], block.range.length > 0 else { continue }
            let paragraph = ns.paragraphRange(for: NSRange(location: min(ns.length - 1, block.range.upperBound - 1), length: 0))
            heights[paragraph.location] = shelf.frame.height + 7
        }
        editor.paragraphSupplementaryHeights = heights
    }
    @objc func changed(_ notification: Notification) {
        let attributesOnly = (notification.object as? NSTextStorage).map { !$0.editedMask.contains(.editedCharacters) } ?? false
        // Preserve exact extents as small documents finish native styling.
        // Large documents must not reapply all results for each styling slice.
        if attributesOnly { return }
        guard !detached, !applying, !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.detached else { return }
            self.pending = false
            // Mode changes can replace attributed storage with identical
            // characters. The host has already applied their new presentation.
            if notification.object is NSTextStorage, !attributesOnly,
               self.appliedSource == Data(self.editor.rawSource.utf8) { return }
            if notification.name == NSView.frameDidChangeNotification || notification.name == NSView.boundsDidChangeNotification {
                let width = max(100, (self.editor.enclosingScrollView?.contentSize.width ?? self.editor.bounds.width) - 48)
                // A presentation update may already have consumed the queued
                // resize. Recheck before doing an identical whole-result pass.
                if let appliedWidth = self.appliedWidth, abs(width - appliedWidth) < 0.5 { return }
            }
            self.apply()
        }
    }
    func selectOutput(_ id: String, index: Int) {
        guard var state = states[id], state.events.indices.contains(index) else { return }
        state.selectedOutputIndex = index; state.collapsed = false
        states[id] = state; apply()
    }
    func toggle(_ id: String) { guard var state = states[id] else { return }; state.collapsed.toggle(); states[id] = state; apply() }
    func clear(_ id: String) {
        guard var state = states[id] else { return }
        state.cleared = true; state.collapsed = false; state.events = []; state.selectedOutputIndex = 0; state.contentID = UUID().uuidString
        states[id] = state
        if let shelf = shelves.removeValue(forKey: id) {
            shelf.isHidden = true; shelf.removeFromSuperview(); shelf.actions.removeFromSuperview()
        }
        apply()
    }
    func restore(_ id: String) { guard var state = states[id] else { return }; state.cleared = false; state.collapsed = false; states[id] = state; apply() }
    func runPreview(_ id: String) {
        if !model.usesSampleOutputs { model.runNotebookBlock(id); return }
        guard !hidesForSource, let block = blocks().first(where: { $0.id == id && $0.canRun }) else { return }
        let stopping = states[id]?.running == true
        if stopping {
            states[id]?.running = false; states[id]?.stopped = true
            apply(); return
        }
        for key in states.keys { states[key]?.running = false }
        var state = states[id] ?? State(hash: block.sourceHash)
        if state.hash != block.sourceHash || state.cleared || state.events.isEmpty {
            state = State(hash: block.sourceHash, events: RecordOutputEvent.samples(for: block.label))
        }
        state.running = !stopping; state.stopped = stopping; state.cleared = false
        states[id] = state; apply()
    }
    private func paragraph(_ block: RecordVisualBlockIndex.Block, opening: Bool) -> NSRange {
        let ns = editor.rawSource as NSString
        return ns.paragraphRange(for: NSRange(location: min(ns.length - 1, opening ? block.range.location : NSMaxRange(block.range) - 1), length: 0))
    }
    func rect(_ range: NSRange, lineOnly: Bool = false) -> NSRect {
        guard let manager = editor.textLayoutManager,
              let location = manager.location(manager.documentRange.location, offsetBy: range.location) else { return .zero }
        // The closing paragraph can be read directly. Walking from document
        // start with ensuresLayout on every scroll forces unrelated rendering.
        manager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = manager.textLayoutFragment(for: location) else { return .zero }
        var frame = fragment.layoutFragmentFrame
        // Preserve the terminal-fence fix: exclude TextKit's extra EOF line.
        let contentLines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        if lineOnly, let first = contentLines.first {
            frame.origin.y += first.typographicBounds.minY
            frame.size.height = contentLines.map(\.typographicBounds.maxY).max()! - first.typographicBounds.minY
        }
        return frame.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
    }
    private func setSupplementarySpace(_ desired: [Int: (NSRange, CGFloat)], storage: NSTextStorage) {
        let heights = desired.mapValues { $0.1 }
        let old = editor.paragraphSupplementaryHeights
        guard old != heights else { return }
        editor.paragraphSupplementaryHeights = heights
        let changed = Set(old.keys).union(heights.keys).filter { old[$0] != heights[$0] }
        storage.beginEditing()
        for offset in changed where offset >= 0 && offset < storage.length {
            // Attribute invalidation re-vends the corresponding native fragment.
            // No actual source attribute or undo state is modified.
            storage.edited(.editedAttributes, range: NSRange(location: offset, length: 1), changeInLength: 0)
        }
        storage.endEditing()
    }
    func blockAtResultPoint(_ point: NSPoint) -> RecordVisualBlockIndex.Block? {
        blocks().first { block in
            guard let shelf = shelves[block.id], !shelf.isHidden else { return false }
            return shelf.frame.contains(point)
        }
    }
    func apply() {
        guard !detached, !applying, !editor.hasMarkedText(), Data(editor.rawSource.utf8) == Data(editor.string.utf8),
              let storage = editor.textStorage else { return }
        let start = ProcessInfo.processInfo.systemUptime
        applying = true
        defer { applying = false; onApplyTiming?((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        applyCount += 1
        appliedSource = Data(editor.rawSource.utf8)
        viewportStamp = nil
        let current = blocks(), ids = Set(current.map(\.id))
        for id in states.keys where !ids.contains(id) { states.removeValue(forKey: id) }
        for id in Array(shelves.keys) where !ids.contains(id) || states[id]?.cleared != false {
            if let shelf = shelves.removeValue(forKey: id) { shelf.removeFromSuperview(); shelf.actions.removeFromSuperview() }
        }
        for id in Array(codeActions.keys) where !ids.contains(id) { codeActions.removeValue(forKey: id)?.removeFromSuperview() }
        let width = max(100, (editor.enclosingScrollView?.contentSize.width ?? editor.bounds.width) - 48)
        appliedWidth = width
        let margin = editor.codeBlockMarginStyle
        let side = margin.slot.width + 8
        var outputs: [Int: (NSRange, CGFloat)] = [:]
        for block in current where !hidesForSource {
            if let state = states[block.id], !state.cleared {
                let shelf = shelves[block.id] ?? RecordOutputShelf(frame: .zero)
                if shelves[block.id] == nil {
                    shelves[block.id] = shelf
                    shelf.isHidden = true; shelf.actions.isHidden = true
                    trackPointer(in: shelf); trackPointer(in: shelf.actions)
                }
                shelf.actions.frame.size = NSSize(width: side, height: side * 2 + 2)
                shelf.frameColor = margin.background; shelf.contentBackground = editor.backgroundColor
                shelf.toggle.frame = NSRect(x: 0, y: 0, width: side, height: side)
                shelf.clear.frame = NSRect(x: 0, y: side + 2, width: side, height: side)
                for button in [shelf.toggle, shelf.clear] { button.ink = margin.ink; button.hoverFill = margin.hoverFill }
                shelf.onToggle = { [weak self] in self?.toggle(block.id) }
                shelf.onClear = { [weak self] in self?.clear(block.id) }
                shelf.onSelect = { [weak self] index in self?.selectOutput(block.id, index: index) }
                let isStale = state.hash != block.sourceHash || (!state.isSample && state.sessionID != model.notebook.sessionID)
                shelf.configure(id: block.id, state: state, stale: isStale,
                    font: editor.theme.monospaceFont(ofSize: model.fontSize), bodyFont: editor.bodyFont)
                let closing = paragraph(block, opening: false)
                let height = shelf.desiredHeight(width: width)
                outputs[closing.location] = (closing, height + 7)
                let size = NSSize(width: width, height: height)
                if shelf.frame.size != size { shelf.setFrameSize(size) }
            }
        }
        setSupplementarySpace(outputs, storage: storage)
        // Small documents keep an exact native scroll extent. Long documents
        // use viewport layout so a mode change never drains the whole file.
        if editor.string.utf16.count <= 100_000, let manager = editor.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
        }
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        guard !hidesForSource else {
            for shelf in shelves.values {
                shelf.isHidden = true; shelf.actions.isHidden = true
                shelf.removeFromSuperview(); shelf.actions.removeFromSuperview()
            }
            for actions in codeActions.values { actions.isHidden = true; actions.removeFromSuperview() }
            updateDocumentMinimumHeight()
            updateHover(at: nil)
            refreshPointer(invalidateCursorRects: true)
            editor.setAccessibilityChildren([])
            return
        }
        if shelves.isEmpty {
            paragraphRects.removeAll(keepingCapacity: true); visibleParagraphs.removeAll(keepingCapacity: true)
        } else {
            cacheParagraphRects()
        }
        positionShelves(current)
        positionCodeActions(current, updateState: true)
        publishAccessibility(current)
        updateDocumentMinimumHeight()
        refreshPointer(invalidateCursorRects: true)
    }
    private func positionShelves(_ current: [RecordVisualBlockIndex.Block]) {
        let slot = editor.codeBlockMarginStyle.slot
        for block in current {
            guard let shelf = shelves[block.id] else { continue }
            let paragraph = paragraph(block, opening: false)
            guard let closing = paragraphRects[paragraph.location] else {
                shelf.isHidden = true; shelf.actions.isHidden = true
                shelf.removeFromSuperview(); shelf.actions.removeFromSuperview()
                continue
            }
            var y = closing.maxY
            var bodyVisible = false
            if block.contentRange.length > 0 {
                let body = (editor.rawSource as NSString).paragraphRange(for: NSRange(location: block.contentRange.upperBound - 1, length: 0))
                bodyVisible = visibleParagraphs.contains(body.location)
                if bodyVisible, let rect = paragraphRects[body.location], let advance = paragraphAdvances[paragraph.location] {
                    // EOF/hidden closing fences can retain an estimated frame.
                    // The adjacent visible code line supplies the native base.
                    y = rect.maxY + advance
                }
            }
            let origin = NSPoint(x: 24, y: y)
            if shelf.frame.origin != origin { shelf.setFrameOrigin(origin) }
            let actionOrigin = NSPoint(x: slot.minX - 4, y: origin.y)
            if shelf.actions.frame.origin != actionOrigin { shelf.actions.setFrameOrigin(actionOrigin) }
            let visible = visibleParagraphs.contains(paragraph.location) || (bodyVisible && shelf.frame.intersects(editor.visibleRect))
            shelf.isHidden = !visible; shelf.actions.isHidden = !visible
            if visible {
                if shelf.superview == nil { editor.addSubview(shelf); editor.addSubview(shelf.actions) }
            } else { shelf.removeFromSuperview(); shelf.actions.removeFromSuperview() }
        }
    }
    private func cacheParagraphRects() {
        guard let manager = editor.textLayoutManager else { return }
        paragraphRects.removeAll(keepingCapacity: true); paragraphAdvances.removeAll(keepingCapacity: true)
        visibleParagraphs.removeAll(keepingCapacity: true)
        let viewport = manager.textViewportLayoutController.viewportRange
        let viewportEnd = viewport.map { manager.offset(from: manager.documentRange.location, to: $0.endLocation) } ?? Int.max
        let origin = editor.textContainerOrigin, visible = editor.visibleRect
        manager.enumerateTextLayoutFragments(from: viewport?.location, options: []) { fragment in
            let offset = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
            if offset > viewportEnd { return false }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > visible.maxY { return false }
            guard frame.height > 0 else { return true }
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            var lineRect = frame
            if let first = lines.first {
                lineRect.origin.y += first.typographicBounds.minY
                lineRect.size.height = (lines.map(\.typographicBounds.maxY).max() ?? 0) - first.typographicBounds.minY
            }
            self.paragraphRects[offset] = lineRect
            self.paragraphAdvances[offset] = lines.map(\.typographicBounds.maxY).max() ?? frame.height
            // Hidden fence glyphs can have zero width while their trailing
            // result spacing is visible across the editor's full width.
            if frame.maxY > visible.minY && frame.minY < visible.maxY { self.visibleParagraphs.insert(offset) }
            return true
        }
    }
    private func positionCodeActions(_ current: [RecordVisualBlockIndex.Block], updateState: Bool) {
        let margin = editor.codeBlockMarginStyle
        let side = margin.slot.width + 8
        let anchors = Dictionary(uniqueKeysWithValues: editor.codeBlockMarginAnchors().map { ($0.range.location, $0) })
        var visible = Set<String>()
        for block in current where block.language == "r" {
            guard let anchor = anchors[block.range.location] else { continue }
            visible.insert(block.id)
            let created = codeActions[block.id] == nil
            let actions = codeActions[block.id] ?? RecordCodeActions(frame: .zero)
            if actions.superview == nil { editor.addSubview(actions) }
            if created {
                codeActions[block.id] = actions
                trackPointer(in: actions)
                actions.onRun = { [weak self] in self?.runPreview(block.id) }
                actions.onFormat = { [weak self] in self?.model.formatRBlock(block.id) }
            }
            if created || updateState {
                actions.configure(block, running: states[block.id]?.running == true)
                if !model.usesSampleOutputs {
                    actions.run.isEnabled = block.canRun && (!model.notebook.isBusy || model.notebook.activeBlockID == block.id)
                }
                actions.format.isEnabled = editor.isEditable && !editor.hasMarkedText()
                for button in [actions.run, actions.format] { button.ink = margin.ink; button.hoverFill = margin.hoverFill }
            }
            var frame = anchor.copyRect.insetBy(dx: -4, dy: -4).offsetBy(dx: 0, dy: side + 2)
            frame.size.height = side * 2 + 2
            if actions.frame != frame { actions.frame = frame }
            actions.hoverRect = anchor.hoverRect
            if actions.isHidden { actions.isHidden = false }
        }
        for (id, actions) in codeActions where !visible.contains(id) {
            actions.isHidden = true; actions.removeFromSuperview()
        }
    }
    private func publishAccessibility(_ current: [RecordVisualBlockIndex.Block]) {
        editor.setAccessibilityChildren(current.flatMap { block -> [Any] in
            var children: [Any] = []
            if let actions = codeActions[block.id], !actions.isHidden { children.append(actions) }
            if let shelf = shelves[block.id], !shelf.isHidden { children.append(contentsOf: [shelf, shelf.actions]) }
            return children
        })
    }

    private func updateDocumentMinimumHeight() {
        // TextKit excludes a final paragraph's trailing spacing from used height.
        // Results are sibling views in that spacing, so include their real bottom
        // in NSTextView's native sizing without inserting a synthetic source line.
        let bottom = shelves.values.filter { !$0.isHidden }.map { $0.frame.maxY }.max() ?? 0
        let minimum = bottom > 0 ? bottom + editor.textContainerOrigin.y
            + (editor.enclosingScrollView?.contentSize.height ?? 0) / 2 : 0
        guard abs(editor.minSize.height - minimum) > 0.5 || editor.frame.height < minimum else { return }
        editor.minSize.height = minimum
        editor.sizeToFit()
    }
}
