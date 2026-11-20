import AppKit
import EdmundCore

/// Presentation ranges always address the complete UTF-16 source. Folding never
/// substitutes text, changes the saved document, or changes executable cells.
struct RecordDocumentStructure {
    struct Region: Equatable {
        enum Kind { case heading, fence }
        let kind: Kind
        let title: String
        let header: NSRange
        let hidden: NSRange
        var key: Int { header.location }
    }
    let headings: [OutlineHeading]
    let regions: [Region]

    init(_ source: String) {
        let ns = source as NSString
        headings = BlockParser.parse(source).compactMap {
            guard case .heading(let level) = $0.kind else { return nil }
            return OutlineHeading(level: level, title: OutlineHeading.title(of: $0.content), range: $0.range)
        }
        var result: [Region] = []
        for (index, heading) in headings.enumerated() {
            let start = ns.lineRange(for: NSRange(location: max(heading.range.location, heading.range.upperBound - 1), length: 0)).upperBound
            let end = headings.dropFirst(index + 1).first { $0.level <= heading.level }?.range.location ?? ns.length
            if end > start {
                result.append(.init(kind: .heading, title: heading.title, header: heading.range,
                                    hidden: NSRange(location: start, length: end - start)))
            }
        }
        for fence in FenceScanner().scan(source).fences where fence.closed {
            let header = ns.lineRange(for: NSRange(location: fence.range.location, length: 0))
            if fence.range.upperBound > header.upperBound {
                result.append(.init(kind: .fence, title: ns.substring(with: header).trimmingCharacters(in: .whitespacesAndNewlines),
                    header: header, hidden: NSRange(location: header.upperBound, length: fence.range.upperBound - header.upperBound)))
            }
        }
        regions = result.sorted { $0.header.location < $1.header.location }
    }
}

/// TextKit's content enumeration filter removes complete paragraphs from layout
/// while keeping text storage, clipboard, undo, R and Quarto on the full source.
@MainActor final class RecordCodeFolding: NSObject, @preconcurrency NSTextContentStorageDelegate {
    private weak var editor: EditorTextView?
    private weak var content: NSTextContentStorage?
    private(set) var structure = RecordDocumentStructure("")
    private(set) var collapsed: Set<Int> = []
    private var source = ""
    private var sourceBytes = Data()
    private(set) var enabled = false
    var willChange: ((NSRange) -> Void)?
    var didChange: (() -> Void)?
    var onChange: (() -> Void)?
    private var layoutHidden: [NSRange] = []
    var hiddenRanges: [NSRange] { enabled ? layoutHidden : [] }


    init(editor: EditorTextView) {
        self.editor = editor
        content = editor.textLayoutManager?.textContentManager as? NSTextContentStorage
        super.init()
        content?.delegate = self
    }
    func update(source newSource: String, enabled: Bool) {
        let previouslyHidden = hiddenRanges
        var changed = self.enabled != enabled
        self.enabled = enabled
        let bytes = Data(newSource.utf8)
        if sourceBytes != bytes {
            // Retain folds whose header survives an edit, including edits before
            // a fold. Repeated identical headings remain distinct by location.
            let old = Array(source.utf16), new = Array(newSource.utf16)
            let prefix = zip(old, new).prefix { $0 == $1 }.count
            let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
            let oldEnd = old.count - suffix, delta = new.count - old.count
            let retained = structure.regions.filter { collapsed.contains($0.key) }.compactMap { region -> Int? in
                if region.header.upperBound <= prefix { return region.key }
                if region.header.location >= oldEnd { return region.key + delta }
                return nil
            }
            source = newSource
            sourceBytes = bytes
            structure = RecordDocumentStructure(newSource)
            collapsed = Set(retained).intersection(structure.regions.map(\.key))
            changed = true
        }
        if changed { invalidate(previouslyHidden: previouslyHidden) }
    }
    func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        guard enabled, let range = textElement.elementRange else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        var low = 0, high = layoutHidden.count
        while low < high {
            let mid = (low + high) / 2
            if layoutHidden[mid].location <= offset { low = mid + 1 } else { high = mid }
        }
        return low == 0 || !NSLocationInRange(offset, layoutHidden[low - 1])
    }
    func toggle(_ key: Int) {
        guard enabled, let editor, !editor.hasMarkedText(),
              let region = structure.regions.first(where: { $0.key == key }) else { return }
        willChange?(region.header)
        defer { didChange?() }
        if collapsed.contains(key) { collapsed.remove(key) }
        else {
            // Place an insertion point on the visible opener before hiding it.
            let selection = editor.selectedRange()
            if NSLocationInRange(selection.location, region.hidden) || NSIntersectionRange(selection, region.hidden).length > 0 {
                editor.setSelectedRange(NSRange(location: region.header.location, length: 0))
            }
            collapsed.insert(key)
        }
        invalidate()
    }
    func setAll(collapsed: Bool, kind: RecordDocumentStructure.Region.Kind? = nil) {
        guard enabled, editor?.hasMarkedText() == false else { return }
        willChange?(NSRange(location: 0, length: 0))
        defer { didChange?() }
        if collapsed { editor?.setSelectedRange(NSRange(location: 0, length: 0)) }
        for region in structure.regions where kind == nil || region.kind == kind {
            if collapsed { self.collapsed.insert(region.key) } else { self.collapsed.remove(region.key) }
        }
        invalidate()
    }
    func reveal(_ range: NSRange, touchingBoundary: Bool = false) {
        guard enabled else { return }
        let keys = structure.regions.filter {
            collapsed.contains($0.key) && (NSLocationInRange(range.location, $0.hidden)
                || NSIntersectionRange(range, $0.hidden).length > 0
                || (touchingBoundary && range.location == $0.hidden.upperBound))
        }.map(\.key)
        guard !keys.isEmpty else { return }
        collapsed.subtract(keys); invalidate()
    }
    private func invalidate(previouslyHidden: [NSRange]? = nil) {
        layoutHidden = []
        for range in structure.regions.filter({ collapsed.contains($0.key) }).map(\.hidden) {
            if let last = layoutHidden.last, range.location <= last.upperBound {
                layoutHidden[layoutHidden.count - 1].length = max(last.upperBound, range.upperBound) - last.location
            } else { layoutHidden.append(range) }
        }
        // Switching modes with no folds changes no content enumeration. Avoid
        // invalidating the whole layout a second time after theme presentation.
        if previouslyHidden == hiddenRanges { onChange?(); return }
        guard let editor, let manager = editor.textLayoutManager else { return }
        manager.invalidateLayout(for: manager.documentRange)
        editor.needsLayout = true; editor.needsDisplay = true
        manager.textViewportLayoutController.layoutViewport()
        onChange?()
    }
    func detach() { content?.delegate = nil; willChange = nil; didChange = nil; onChange = nil }
}

/// A small, fixed gutter beside the native line numbers. Only visible openers
/// become controls, so long documents do not allocate a button for every block.
@MainActor final class RecordFoldGutter: NSView {
    private weak var editor: EditorTextView?
    private let folding: RecordCodeFolding
    private var buttons: [Int: NSButton] = [:]
    override var isFlipped: Bool { true }
    init(editor: EditorTextView, folding: RecordCodeFolding) {
        self.editor = editor; self.folding = folding
        super.init(frame: .zero)
        setAccessibilityIdentifier("record-fold-gutter")
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        guard let editor, !isHidden, let manager = editor.textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange else {
            buttons.values.forEach { $0.isHidden = true }; return
        }
        var visible: Set<Int> = []
        let regions = Dictionary(uniqueKeysWithValues: folding.structure.regions.map { ($0.key, $0) })
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            // An unlaid fragment has a zero frame. Geometry alone cannot stop
            // this walk: it would vend the rest of the document mid-scroll.
            guard fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedDescending else { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let visibleBottom = editor.visibleRect.maxY - editor.textContainerOrigin.y
            guard fragment.layoutFragmentFrame.minY <= visibleBottom else { return false }
            let offset = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
            guard let region = regions[offset], let line = fragment.textLineFragments.first else { return true }
            let rect = self.convert(NSRect(x: 0,
                y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + editor.textContainerOrigin.y,
                width: 18, height: max(16, line.typographicBounds.height)), from: editor)
            guard rect.maxY > self.bounds.minY, rect.minY < self.bounds.maxY else { return true }
            visible.insert(offset)
            let button = self.buttons[offset] ?? NSButton(title: "", target: self, action: #selector(self.clicked(_:)))
            if button.superview == nil {
                button.isBordered = false; button.imagePosition = .imageOnly; button.tag = offset
                button.setAccessibilityIdentifier("record-fold-\(offset)")
                self.buttons[offset] = button; self.addSubview(button)
            }
            let collapsed = self.folding.collapsed.contains(offset)
            button.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            button.contentTintColor = .tertiaryLabelColor
            button.toolTip = (collapsed ? L10n.string("展开") : L10n.string("折叠")) + " · " + region.title
            button.setAccessibilityLabel(button.toolTip)
            button.frame = NSRect(x: 0, y: rect.midY - 9, width: 18, height: 18); button.isHidden = false
            return true
        }
        for key in Array(buttons.keys) where !visible.contains(key) { buttons.removeValue(forKey: key)?.removeFromSuperview() }
    }
    @objc private func clicked(_ sender: NSButton) { folding.toggle(sender.tag); editor?.window?.makeFirstResponder(editor) }
}
