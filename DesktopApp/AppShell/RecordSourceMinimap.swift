import AppKit
import CoreText
import EdmundCore

/// A presentation-only overview. Reads colors from the source buffer and uses
/// the editor's public TextKit 2 scroll API; never changes text or the selection.
@MainActor final class RecordSourceMinimap: NSView {
    struct Stroke {
        let line: Int
        let column: Int
        let length: Int
        let color: NSColor
    }
    private weak var editor: EditorTextView?
    private weak var scroll: NSScrollView?
    private(set) var strokes: [Stroke] = []
    private(set) var lineCount = 1
    private var rowStarts = [0]
    private var wrappedSource: Data?
    private var wrapWidth: CGFloat = 0
    private var wrapFont: NSFont?
    private var coloredSource: Data?
    private var coloredTheme: EditorTheme?
    private var coloredDark = false
    private var image: NSImage?
    private var pending = false
    private var detached = false
    var revealSource: ((NSRange) -> Void)?
    private var dragAnchor: CGFloat?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    var selectionAccentColor: NSColor = .controlAccentColor {
        didSet { if oldValue != selectionAccentColor { needsDisplay = true } }
    }
    var viewportFillColor: NSColor {
        RecordNavigationGeometry.selectionFill(accent: selectionAccentColor, appearance: effectiveAppearance)
    }
    override var isFlipped: Bool { true }

    init(editor: EditorTextView, scroll: NSScrollView) {
        self.editor = editor; self.scroll = scroll
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(L10n.string("源码概览"))
        setAccessibilityIdentifier("record-source-minimap")
        setAccessibilityHelp(L10n.string("点击概览跳转，拖动可视范围块上下浏览源码。"))
        scroll.contentView.postsBoundsChangedNotifications = true
        editor.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.frameDidChangeNotification, object: editor)
        NotificationCenter.default.addObserver(self, selector: #selector(edited),
            name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
        rebuild()
    }
    required init?(coder: NSCoder) { nil }

    @objc private func scrolled(_ notification: Notification) { needsDisplay = true }
    @objc private func edited(_ notification: Notification) {
        scheduleRebuild()
    }
    private func scheduleRebuild() {
        guard !pending, !detached else { return }
        pending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.detached else { return }
            self.pending = false
            // Composition is provisional; wait for the committed storage notification.
            guard self.editor?.hasMarkedText() == false else { return }
            self.rebuild()
        }
    }

    func rebuild() {
        guard let editor, editor.viewMode == .source, !editor.hasMarkedText(),
              let storage = editor.textStorage,
              Data(editor.rawSource.utf8) == Data(editor.string.utf8) else { return }
        let units = Array(editor.rawSource.utf16)
        let width = max(1, (editor.textContainer?.size.width ?? editor.bounds.width)
            - 2 * (editor.textContainer?.lineFragmentPadding ?? 0))
        let font = editor.theme.monospaceFont(ofSize: editor.theme.fontSize)
        let bytes = Data(editor.rawSource.utf8)
        let dark = editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if coloredSource == bytes, wrapWidth == width, wrapFont == font,
           coloredTheme == editor.theme, coloredDark == dark {
            needsDisplay = true
            return
        }
        if wrappedSource != bytes || wrapWidth != width || wrapFont != font {
            // A separate CoreText typesetter predicts soft wraps without forcing
            // the main editor to lay out offscreen text or creating another editor.
            let text = NSAttributedString(string: editor.rawSource, attributes: [.font: font])
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            var starts = [0], offset = 0
            while offset < units.count {
                let length = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(width)))
                offset = min(units.count, offset + length)
                if offset < units.count || units.last == 10 { starts.append(offset) }
            }
            rowStarts = starts; wrappedSource = bytes; wrapWidth = width; wrapFont = font
        }
        var result: [Stroke] = []
        var line = 0, column = 0
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let color = value as? NSColor ?? .textColor
            var start: Int?
            func flush() {
                if let start, column > start {
                    result.append(Stroke(line: line, column: start, length: column - start, color: color))
                }
                start = nil
            }
            for index in range.location..<range.upperBound {
                if line + 1 < rowStarts.count, index == rowStarts[line + 1] {
                    flush(); line += 1; column = 0
                }
                let unit = units[index]
                if unit == 10 { flush() }
                else if unit == 9 { flush(); column += 4 - column % 4 }
                else if unit == 32 || unit == 13 { flush(); column += unit == 32 ? 1 : 0 }
                else { if start == nil { start = column }; column += 1 }
            }
            flush()
        }
        strokes = result; lineCount = rowStarts.count
        coloredSource = bytes; coloredTheme = editor.theme; coloredDark = dark
        image = nil; needsDisplay = true
    }

    private func row(forOffset offset: Int) -> Int {
        var lo = 0, hi = rowStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Short files retain tiny line spacing; long files fit their full outline.
    var overviewRect: NSRect {
        NSRect(x: 4, y: 8, width: max(0, bounds.width - 8),
            height: min(max(0, bounds.height - 16), max(8, CGFloat(lineCount) * 3)))
    }

    /// Visual-line coordinates from already laid-out visible fragments, including
    /// soft wraps. Reading these fragments does not force offscreen editor layout.
    var visibleLines: ClosedRange<CGFloat> {
        guard let editor, let scroll else { return 0...CGFloat(lineCount) }
        let visible = scroll.documentVisibleRect
        var lo = CGFloat.greatestFiniteMagnitude, hi: CGFloat = 0
        if let manager = editor.textLayoutManager,
           let viewport = manager.textViewportLayoutController.viewportRange {
            manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedDescending else { return false }
                guard fragment.state == .layoutAvailable else { return true }
                let rect = fragment.layoutFragmentFrame.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                guard rect.minY <= visible.maxY else { return false }
                guard rect.maxY > visible.minY, rect.height > 0 else { return true }
                let offset = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
                for visual in fragment.textLineFragments {
                    let top = rect.minY + visual.typographicBounds.minY
                    let height = visual.typographicBounds.height
                    guard height > 0, top + height > visible.minY, top < visible.maxY else { continue }
                    let line = CGFloat(self.row(forOffset: offset + visual.characterRange.location))
                    lo = min(lo, line + max(0, min(1, (visible.minY - top) / height)))
                    hi = max(hi, line + max(0, min(1, (visible.maxY - top) / height)))
                }
                return true
            }
        }
        if lo == .greatestFiniteMagnitude {
            let height = max(visible.height, editor.bounds.height, 1)
            lo = max(0, visible.minY / height * CGFloat(lineCount))
            hi = min(CGFloat(lineCount), visible.maxY / height * CGFloat(lineCount))
        }
        if visible.maxY >= editor.bounds.maxY - 1 { hi = CGFloat(lineCount) }
        lo = min(CGFloat(lineCount), max(0, lo)); hi = min(CGFloat(lineCount), max(lo, hi))
        return lo...hi
    }

    var viewportRect: NSRect {
        let map = overviewRect, lines = visibleLines
        let pitch = map.height / CGFloat(lineCount)
        let height = min(map.height, max(8, (lines.upperBound - lines.lowerBound) * pitch))
        let top = min(map.maxY - height, map.minY + lines.lowerBound * pitch)
        return NSRect(x: 1, y: top, width: max(0, bounds.width - 2), height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { image = nil; scheduleRebuild() }
        super.setFrameSize(newSize)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        image = nil; needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        isHovered = window.map {
            !isHiddenOrHasHiddenAncestor && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func draw(_ dirtyRect: NSRect) {
        guard let editor else { return }
        editor.backgroundColor.setFill(); bounds.fill()
        if isHovered {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: 1 / (window?.backingScaleFactor ?? 2), height: bounds.height).fill()
        }
        let map = overviewRect
        if image == nil, map.width > 0, map.height > 0 {
            let snapshot = NSImage(size: map.size, flipped: true) { [strokes, lineCount] rect in
                let pitch = rect.height / CGFloat(lineCount)
                let unit: CGFloat = 1.15
                for stroke in strokes {
                    let x = CGFloat(stroke.column) * unit
                    guard x < rect.width else { continue }
                    stroke.color.withAlphaComponent(0.8).setFill()
                    NSRect(x: x, y: CGFloat(stroke.line) * pitch,
                        width: min(rect.width - x, CGFloat(stroke.length) * unit),
                        height: min(1.6, max(0.5, pitch * 0.65))).fill()
                }
                return true
            }
            image = snapshot
        }
        image?.draw(in: map, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let thumb = NSBezierPath(roundedRect: viewportRect, xRadius: 2, yRadius: 2)
        viewportFillColor.setFill(); thumb.fill()
        selectionAccentColor.withAlphaComponent(0.55).setStroke(); thumb.lineWidth = 0.5; thumb.stroke()
        setAccessibilityValue(Double(visibleLines.lowerBound / CGFloat(lineCount)) * 100)
    }

    /// Target the viewport's top without moving the insertion point or focus.
    func navigate(topLine: CGFloat) {
        guard let editor, !isHidden, editor.viewMode == .source, !editor.hasMarkedText() else { return }
        let line = Int(min(CGFloat(lineCount - 1), max(0, topLine)))
        revealSource?(NSRange(location: rowStarts[line], length: 0))
        editor.scrollCharacterToTop(rowStarts[line], preservingHorizontalPosition: true)
        needsDisplay = true
    }
    func beginNavigation(at point: NSPoint) {
        let thumb = viewportRect
        if thumb.contains(point) { dragAnchor = point.y - thumb.minY; return }
        dragAnchor = thumb.height / 2
        dragNavigation(to: point)
    }
    func dragNavigation(to point: NSPoint) {
        guard let dragAnchor, overviewRect.height > 0 else { return }
        navigate(topLine: (point.y - dragAnchor - overviewRect.minY) / overviewRect.height * CGFloat(lineCount))
    }
    override func mouseDown(with event: NSEvent) { beginNavigation(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { dragNavigation(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { dragAnchor = nil }
    override func scrollWheel(with event: NSEvent) { scroll?.scrollWheel(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformIncrement() -> Bool { navigate(topLine: visibleLines.lowerBound + 5); return true }
    override func accessibilityPerformDecrement() -> Bool { navigate(topLine: visibleLines.lowerBound - 5); return true }
    func detach() { detached = true; revealSource = nil; NotificationCenter.default.removeObserver(self) }
}
