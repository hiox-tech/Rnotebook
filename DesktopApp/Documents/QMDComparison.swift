import AppKit
import SwiftUI

struct QMDComparison {
    struct Line: Equatable { let number: Int; let text: String }
    struct Row: Equatable {
        let editor: Line?
        let external: Line?
        let changed: Bool
    }
    let rows: [Row]
    let changes: [Int]
    let simplified: Bool

    init(editor: String, external: String) {
        let left = editor.components(separatedBy: "\n"), right = external.components(separatedBy: "\n")
        var result: [Row] = []
        simplified = max(left.count, right.count) > 12_000 || left.count > 4_000_000 / max(1, right.count)
        if simplified {
            for index in 0..<max(left.count, right.count) {
                let a = index < left.count ? Line(number: index + 1, text: left[index]) : nil
                let b = index < right.count ? Line(number: index + 1, text: right[index]) : nil
                result.append(Row(editor: a, external: b, changed: !DocumentRevision.sameSource(a?.text, b?.text)))
            }
        } else {
            var i = 0, j = 0
            for edit in QMDMerge.edits(from: left, to: right) {
                while i < edit.range.lowerBound {
                    result.append(Row(editor: Line(number: i + 1, text: left[i]), external: Line(number: j + 1, text: right[j]), changed: false))
                    i += 1; j += 1
                }
                for offset in 0..<max(edit.range.count, edit.replacement.count) {
                    let a = offset < edit.range.count ? Line(number: i + offset + 1, text: left[i + offset]) : nil
                    let b = offset < edit.replacement.count ? Line(number: j + offset + 1, text: edit.replacement[offset]) : nil
                    result.append(Row(editor: a, external: b, changed: true))
                }
                i = edit.range.upperBound; j += edit.replacement.count
            }
            while i < left.count {
                result.append(Row(editor: Line(number: i + 1, text: left[i]), external: Line(number: j + 1, text: right[j]), changed: false))
                i += 1; j += 1
            }
        }
        rows = result
        changes = result.indices.filter { result[$0].changed && ($0 == 0 || !result[$0 - 1].changed) }
    }
}

/// Both panes use aligned, unwrapped native text with one common vertical offset.
@MainActor final class QMDComparisonScroll: ObservableObject {
    weak var editor: NSScrollView?
    weak var external: NSScrollView?
    var synchronized = true
    private var scrolling = false
    func moved(_ source: NSScrollView) {
        guard synchronized, !scrolling else { return }
        scrolling = true; defer { scrolling = false }
        let other = source === editor ? external : editor
        if let other {
            var origin = other.contentView.bounds.origin
            origin.y = source.contentView.bounds.origin.y
            other.contentView.scroll(to: origin); other.reflectScrolledClipView(other.contentView)
        }
    }
    func reveal(row: Int) {
        for scroll in [editor, external].compactMap({ $0 }) {
            guard let text = scroll.documentView as? QMDComparisonTextView, let range = text.rowRanges[safe: row],
                  let manager = text.layoutManager, let container = text.textContainer else { continue }
            manager.ensureLayout(for: container)
            let glyph = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = glyph.length == 0 ? manager.extraLineFragmentRect : manager.boundingRect(forGlyphRange: glyph, in: container)
            let rect = line.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            text.scrollToVisible(rect.insetBy(dx: 0, dy: -40))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension NSAttributedString.Key {
    static let comparisonPlaceholder = NSAttributedString.Key("RnotebookComparisonPlaceholder")
}

@MainActor final class QMDComparisonTextView: NSTextView {
    var rowRanges: [NSRange] = []
    var numbers: [Int?] = []
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let result = NSMutableAttributedString()
        for range in selectedRanges.compactMap({ $0.rangeValue }) where NSMaxRange(range) <= storage.length {
            storage.enumerateAttribute(.comparisonPlaceholder, in: range) { placeholder, part, _ in
                if placeholder == nil { result.append(storage.attributedSubstring(from: part)) }
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.string, forType: .string)
    }
}

private final class QMDComparisonRuler: NSRulerView {
    init(scroll: NSScrollView) {
        super.init(scrollView: scroll, orientation: .verticalRuler)
        ruleThickness = 48; clientView = scroll.documentView
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let scroll = scrollView, let text = scroll.documentView as? QMDComparisonTextView,
              let manager = text.layoutManager, let container = text.textContainer else { return }
        // NSRulerView owns its background. Its dirty rectangle can extend across
        // the scroll view; filling that rectangle would paint over the document.
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let visible = manager.glyphRange(forBoundingRect: text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y), in: container)
        let characters = manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        for (index, range) in text.rowRanges.enumerated() where range.location <= NSMaxRange(characters) && NSMaxRange(range) >= characters.location {
            guard let number = text.numbers[index] else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = glyphs.length == 0 ? manager.extraLineFragmentRect : manager.boundingRect(forGlyphRange: glyphs, in: container)
            let y = convert(NSPoint(x: 0, y: line.minY + text.textContainerOrigin.y), from: text).y
            let value = NSString(string: String(number))
            value.draw(at: NSPoint(x: ruleThickness - value.size(withAttributes: attributes).width - 8, y: y), withAttributes: attributes)
        }
    }
    override var isFlipped: Bool { true }
}

struct QMDComparisonPane: NSViewRepresentable {
    let comparison: QMDComparison
    let editorSide: Bool
    let scroll: QMDComparisonScroll

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var boundsObserver: NSObjectProtocol?
        var lastRows: [QMDComparison.Row]?
        deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    }
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSScrollView()
        view.wantsLayer = true; view.layer?.masksToBounds = true
        view.hasVerticalScroller = true; view.hasHorizontalScroller = true; view.borderType = .noBorder
        let text = QMDComparisonTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 8, height: 10)
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = []
        view.documentView = text
        view.verticalRulerView = QMDComparisonRuler(scroll: view)
        view.hasVerticalRuler = true; view.rulersVisible = true
        text.setAccessibilityIdentifier(editorSide ? "comparison-editor-text" : "comparison-external-text")
        text.setAccessibilityLabel(editorSide ? L10n.string("编辑器版本") : L10n.string("外部版本"))
        if editorSide { scroll.editor = view } else { scroll.external = view }
        view.contentView.postsBoundsChangedNotifications = true
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view.contentView, queue: .main) { [weak scroll, weak view] _ in
            MainActor.assumeIsolated {
                if let view { scroll?.moved(view); view.verticalRulerView?.needsDisplay = true }
            }
        }
        return view
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard context.coordinator.lastRows != comparison.rows, let text = view.documentView as? QMDComparisonTextView else { return }
        context.coordinator.lastRows = comparison.rows
        let value = NSMutableAttributedString()
        var ranges: [NSRange] = [], numbers: [Int?] = []
        let lines = comparison.rows.map { editorSide ? $0.editor : $0.external }
        let lastNumber = lines.compactMap { $0?.number }.max() ?? 0
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 18; paragraph.maximumLineHeight = 18
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .paragraphStyle: paragraph]
        for (index, row) in comparison.rows.enumerated() {
            let line = lines[index]
            let start = value.length
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if row.changed { attributes[.backgroundColor] = (editorSide ? NSColor.systemOrange : NSColor.systemGreen).withAlphaComponent(0.14) }
            if line == nil { attributes[.comparisonPlaceholder] = true }
            value.append(NSAttributedString(string: line?.text ?? "", attributes: attributes))
            if index < comparison.rows.count - 1 {
                if line == nil || line?.number == lastNumber { attributes[.comparisonPlaceholder] = true }
                value.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            ranges.append(NSRange(location: start, length: value.length - start)); numbers.append(line?.number)
        }
        let origin = view.contentView.bounds.origin
        // An infinite horizontal text container can produce unpaintable glyph
        // rectangles. Fit a finite unwrapped canvas, then measure vertically.
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let contentWidth = lines.compactMap { $0?.text }.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = max(view.contentSize.width, ceil(contentWidth) + 32)
        text.setFrameSize(NSSize(width: width, height: max(view.contentSize.height, CGFloat(comparison.rows.count) * 18 + 20)))
        text.textContainer?.containerSize = NSSize(width: max(1, width - 16), height: CGFloat.greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(value)
        text.rowRanges = ranges; text.numbers = numbers
        if let manager = text.layoutManager, let container = text.textContainer {
            manager.ensureLayout(for: container)
            text.needsDisplay = true
        }
        view.contentView.scroll(to: origin); view.reflectScrolledClipView(view.contentView)
        view.verticalRulerView?.needsDisplay = true
    }
}
