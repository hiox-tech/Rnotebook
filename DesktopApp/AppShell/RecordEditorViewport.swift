import AppKit
import EdmundCore

/// One completed native viewport, shared by reading/navigation consumers.
/// Enumerating this snapshot never asks TextKit to realize offscreen content.
struct RecordEditorLayoutSnapshot {
    struct Line {
        let range: NSRange
        let frame: NSRect
    }
    let sourceLength: Int
    let lines: [Line]
    let viewport: NSRect
    let mode: EditorTextView.ViewMode
    func line(at offset: Int) -> Line? {
        lines.first { NSLocationInRange(offset, $0.range) || $0.range.length == 0 && $0.range.location == offset }
            ?? (offset == sourceLength ? lines.last : nil)
    }
    func readingOffset(at y: CGFloat) -> Int? {
        lines.last { $0.frame.minY <= y }?.range.location ?? lines.first?.range.location
    }
    @MainActor static func read(_ editor: EditorTextView) -> Self? {
        guard let scroll = editor.enclosingScrollView, let manager = editor.textLayoutManager,
              let range = manager.textViewportLayoutController.viewportRange else { return nil }
        var lines: [Line] = []
        let origin = editor.textContainerOrigin
        let sourceLength = editor.string.utf16.count
        manager.enumerateTextLayoutFragments(from: range.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(range.endLocation) != .orderedDescending else { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let paragraph = manager.offset(from: manager.documentRange.location, to: fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let offset = min(sourceLength, paragraph + line.characterRange.location)
                let length = min(line.characterRange.length, sourceLength - offset)
                let frame = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x,
                                                             dy: fragment.layoutFragmentFrame.minY + origin.y)
                guard frame.height > 0 else { continue }
                lines.append(.init(range: NSRange(location: offset, length: length), frame: frame))
            }
            return true
        }
        return .init(sourceLength: sourceLength, lines: lines, viewport: scroll.contentView.bounds, mode: editor.viewMode)
    }
}

/// Host scroll corrections have one owner. Native editing/restyling delegates
/// here; a new gesture invalidates the old transaction instead of racing a timer.
@MainActor final class RecordEditorViewport: EditorViewportDelegate {
    enum Intent { case edit, presentation, navigation, folding, resize, restyle }
    private struct Anchor {
        var offset: Int
        var relativeTop: CGFloat
        var source: String
        var layoutRange: NSRange
        var mode: EditorTextView.ViewMode
        var glyphBottom: Bool
        let intent: Intent
        let atTop: Bool
    }
    private unowned let editor: EditorTextView
    private var anchor: Anchor?
    private var presentationDepth = 0
    private var editing = false
    private var restoring = false
    private var expectedSelection: NSRange?
    private var pendingReveal: NSRange?
    private var ownedScrollY: CGFloat?
    private(set) var generation: UInt64 = 0
    private(set) var snapshot: RecordEditorLayoutSnapshot?
    var isPreservingViewport: Bool { anchor != nil }
    var isApplyingViewport: Bool { restoring }
    var isAdjusting: Bool { restoring || editing || presentationDepth > 0 }
    var isNavigating: Bool { anchor?.intent == .navigation }
    init(editor: EditorTextView) { self.editor = editor }
    func cancel() {
        guard !restoring else { return }
        anchor = nil; pendingReveal = nil; expectedSelection = nil; ownedScrollY = nil
        presentationDepth = 0; generation &+= 1
    }
    func refreshSnapshot() { snapshot = RecordEditorLayoutSnapshot.read(editor) }
    private var scroll: NSScrollView? { editor.enclosingScrollView }
    private var minimumY: CGFloat { -(scroll?.contentInsets.top ?? 0) }
    private var effectiveViewport: NSRect {
        guard let scroll else { return .zero }
        var rect = scroll.contentView.bounds
        rect.origin.y += scroll.contentInsets.top
        rect.size.height = max(0, rect.height - scroll.contentInsets.top - scroll.contentInsets.bottom)
        return rect
    }
    func capture(_ intent: Intent, mode: EditorTextView.ViewMode? = nil, offset preferred: Int? = nil) {
        guard !restoring, let scroll, !editor.hasMarkedText() else { return }
        refreshSnapshot()
        guard let snapshot else { return }
        generation &+= 1; pendingReveal = nil
        let visible = effectiveViewport
        let selection = editor.selectedRange()
        let chosen: RecordEditorLayoutSnapshot.Line?
        var glyphBottom = false
        if let preferred { chosen = snapshot.line(at: preferred) }
        else if let caret = snapshot.line(at: selection.location), caret.frame.minY >= visible.minY,
                caret.frame.maxY < visible.maxY, intent == .presentation {
            chosen = caret; glyphBottom = true
        } else if intent == .resize {
            let ns = editor.string as NSString
            chosen = snapshot.lines.first {
                $0.frame.minY >= visible.minY - 0.5 && $0.frame.maxY <= visible.maxY
                    && ns.paragraphRange(for: NSRange(location: $0.range.location, length: 0)).location == $0.range.location
            } ?? snapshot.lines.first { $0.frame.maxY > visible.minY }
        } else {
            chosen = snapshot.lines.first { $0.frame.minY >= visible.minY - 0.5 && $0.frame.maxY <= visible.maxY }
                ?? snapshot.lines.first { $0.frame.maxY > visible.minY }
        }
        guard let chosen else { anchor = nil; return }
        let offset = preferred ?? (glyphBottom ? selection.location : chosen.range.location)
        let rect = (glyphBottom ? caretRect(at: offset) : nativeLineRect(at: offset)) ?? chosen.frame
        anchor = .init(offset: offset,
                       relativeTop: (glyphBottom ? rect.maxY : rect.minY) - scroll.contentView.bounds.minY,
                       source: editor.string,
                       layoutRange: NSRange(location: snapshot.lines.first?.range.location ?? offset,
                           length: max(0, (snapshot.lines.last?.range.upperBound ?? offset) - (snapshot.lines.first?.range.location ?? offset))),
                       mode: mode ?? editor.viewMode, glyphBottom: glyphBottom, intent: intent,
                       atTop: intent != .navigation && (scroll.contentView.bounds.minY <= minimumY + 1
                           || offset == 0 && scroll.contentView.bounds.minY <= editor.textContainerOrigin.y))
        expectedSelection = intent == .edit ? nil : selection
    }
    func editorWillEdit(range: NSRange, replacement: String?) {
        cancel(); editing = true
        guard !editor.hasMarkedText(), let replacement, range.length <= 256,
              replacement.utf16.count <= 256, replacement.filter({ $0 == "\n" }).count <= 1 else { return }
        refreshSnapshot()
        guard let snapshot, let caret = snapshot.line(at: editor.selectedRange().location),
              caret.frame.minY >= effectiveViewport.minY,
              caret.frame.maxY + caret.frame.height < effectiveViewport.maxY else { return }
        let ns = editor.string as NSString
        var offset = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0)).location
        if offset == range.location, offset > 0 { offset = ns.lineRange(for: NSRange(location: offset - 1, length: 0)).location }
        capture(.edit, offset: offset)
        guard var anchor else { return }
        if anchor.offset < range.location { }
        else if anchor.offset >= range.upperBound { anchor.offset += replacement.utf16.count - range.length }
        else { self.anchor = nil; return }
        anchor.layoutRange.length = max(0, anchor.layoutRange.length + replacement.utf16.count - range.length)
        anchor.source = (editor.string as NSString).replacingCharacters(in: range, with: replacement)
        self.anchor = anchor
    }
    func editorDidEdit() {
        if var anchor {
            guard anchor.source.utf8.elementsEqual(editor.string.utf8) else { editing = false; cancel(); return }
            anchor.source = editor.string; self.anchor = anchor; expectedSelection = editor.selectedRange()
        }
        editing = false
        if let anchor, let manager = editor.textLayoutManager {
            // Lay out the affected visible paragraphs together. Measuring only
            // an invalidated deep row can stack it after a distant valid row.
            let end = min(editor.string.utf16.count, anchor.layoutRange.upperBound)
            if let start = manager.location(manager.documentRange.location, offsetBy: anchor.layoutRange.location),
               let finish = manager.location(manager.documentRange.location, offsetBy: end),
               let range = NSTextRange(location: start, end: finish) { manager.ensureLayout(for: range) }
            // Correct before requesting a viewport pass: otherwise a shortened
            // estimate can leave the old clip beyond the new document extent.
            restore()
            manager.textViewportLayoutController.layoutViewport()
        } else { editor.textLayoutManager?.textViewportLayoutController.layoutViewport() }
        layoutDidComplete()
    }
    func editorWillRestyle() {
        if presentationDepth == 0, !editing, anchor == nil { capture(.restyle) }
        presentationDepth += 1
    }
    func editorDidRestyle() {
        presentationDepth = max(0, presentationDepth - 1)
        guard presentationDepth == 0, !editing else { return }
        refreshSnapshot(); restore()
    }
    func beginPresentation(mode: EditorTextView.ViewMode? = nil, intent: Intent = .presentation) {
        if !editing {
            if intent == .presentation, var saved = anchor, saved.intent == .presentation,
               saved.source.utf8.elementsEqual(editor.string.utf8), expectedSelection == editor.selectedRange() {
                saved.mode = mode ?? editor.viewMode; anchor = saved; generation &+= 1
            } else { capture(intent, mode: mode) }
        }
        presentationDepth += 1
    }
    func endPresentation() {
        presentationDepth = max(0, presentationDepth - 1)
        if let anchor, anchor.intent == .presentation {
            restoring = true
            // Native theme changes can move the retained source location outside
            // the estimated viewport. Realize that bounded source neighborhood
            // before restoring the original reading/caret metric.
            if let manager = editor.textLayoutManager,
               let location = manager.location(manager.documentRange.location, offsetBy: anchor.offset) {
                let y = manager.textViewportLayoutController.relocateViewport(to: location)
                scroll?.contentView.scroll(to: NSPoint(x: 0, y: y + editor.textContainerOrigin.y - (scroll?.contentInsets.top ?? 0)))
                manager.textViewportLayoutController.layoutViewport()
            }
            editor.scrollCharacterToTop(anchor.offset, preservingHorizontalPosition: true)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            restoring = false
        }
        refreshSnapshot(); restore()
    }
    func navigate(to range: NSRange, moveInsertionPoint: Bool, centered: Bool = false) {
        cancel(); restoring = true
        if moveInsertionPoint { editor.setSelectedRange(range) }
        if let manager = editor.textLayoutManager,
           let location = manager.location(manager.documentRange.location, offsetBy: range.location) {
            let y = manager.textViewportLayoutController.relocateViewport(to: location)
            scroll?.contentView.scroll(to: NSPoint(x: 0, y: y + editor.textContainerOrigin.y - (scroll?.contentInsets.top ?? 0)))
        }
        editor.scrollCharacterToTop(range.location)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        restoring = false
        generation &+= 1
        let inset = scroll?.contentInsets.top ?? 0
        let relativeTop = centered ? inset + effectiveViewport.height / 2 + (caretRect(at: range.location)?.height ?? 0) / 2 : inset + 24
        anchor = .init(offset: range.location, relativeTop: relativeTop,
                       source: editor.string, layoutRange: range, mode: editor.viewMode,
                       glyphBottom: centered, intent: .navigation, atTop: false)
        expectedSelection = editor.selectedRange()
        refreshSnapshot(); restore()
    }
    func willFold(_ range: NSRange) { cancel(); capture(.folding, offset: range.location); presentationDepth += 1 }
    func didFold() {
        expectedSelection = editor.selectedRange()
        // Native end-of-document clamping can post bounds while re-laying the
        // shortened document. That belongs to the fold, not a new user scroll.
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        presentationDepth = max(0, presentationDepth - 1)
        refreshSnapshot(); restore()
    }
    func didScroll() {
        guard !isAdjusting, !editor.isAdjustingPresentation else { return }
        // NSClipView may post its pixel-rounded bounds after scroll(to:) has
        // returned. That is completion of our write, not a new navigation.
        if let ownedScrollY, let scroll, abs(scroll.contentView.bounds.minY - ownedScrollY) <= 1 {
            refreshSnapshot(); return
        }
        if anchor?.intent == .presentation || anchor?.intent == .resize || anchor?.intent == .navigation || anchor?.intent == .folding {
            restore(); refreshSnapshot()
        } else { cancel(); refreshSnapshot() }
    }
    func selectionChanged() {
        if let expectedSelection, expectedSelection != editor.selectedRange(), !isAdjusting { cancel() }
    }
    func requestCaretReveal(_ range: NSRange) {
        guard !isPreservingViewport, !isAdjusting, !editor.hasMarkedText() else { return }
        pendingReveal = range
    }
    func layoutDidComplete() {
        refreshSnapshot()
        guard !editing, presentationDepth == 0 else { return }
        restore()
        if let reveal = pendingReveal, !isPreservingViewport {
            pendingReveal = nil
            guard reveal == editor.selectedRange(), !editor.hasMarkedText() else { return }
            // Only repair a missing native caret, not an intentionally offscreen
            // insertion point while the user reads another part of the document.
            if editor.firstRect(forCharacterRange: reveal, actualRange: nil).height <= 0 {
                restoring = true; editor.scrollRangeToVisible(reveal); restoring = false
            }
        }
    }
    private func caretRect(at offset: Int) -> NSRect? {
        guard let window = editor.window else { return nil }
        let rect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        guard rect.height > 0 else { return nil }
        return editor.convert(window.convertFromScreen(rect), from: nil)
    }
    private func nativeLineRect(at offset: Int) -> NSRect? {
        guard let manager = editor.textLayoutManager,
              let location = manager.location(manager.documentRange.location, offsetBy: offset),
              let fragment = manager.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let start = fragment.textElement?.elementRange?.location else { return nil }
        let relative = manager.offset(from: start, to: location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(relative, $0.characterRange) })
                ?? fragment.textLineFragments.last else { return nil }
        return line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + editor.textContainerOrigin.x,
                                                dy: fragment.layoutFragmentFrame.minY + editor.textContainerOrigin.y)
    }
    private func restore() {
        guard !restoring, !editing, presentationDepth == 0, let anchor, let scroll,
              !editor.hasMarkedText() else { return }
        guard editor.viewMode == anchor.mode, anchor.source.utf8.elementsEqual(editor.string.utf8) else { cancel(); return }
        restoring = true
        defer { restoring = false }
        if anchor.atTop {
            ownedScrollY = minimumY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: minimumY))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        // A scroll changes the native viewport as well as the clip origin.
        // Complete that viewport before a caret query or a paint sees the new
        // bounds. Nested completion callbacks may read but cannot restore again.
        for _ in 0..<3 {
            var metric = anchor.glyphBottom ? caretRect(at: anchor.offset) : nativeLineRect(at: anchor.offset)
            if metric == nil, anchor.intent == .presentation || anchor.intent == .navigation || anchor.intent == .resize || anchor.intent == .folding {
                editor.scrollCharacterToTop(anchor.offset, preservingHorizontalPosition: true)
                editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                metric = anchor.glyphBottom ? caretRect(at: anchor.offset) : nativeLineRect(at: anchor.offset)
            }
            guard let rect = metric else { return }
            let desired = anchor.atTop ? minimumY : (anchor.glyphBottom ? rect.maxY : rect.minY) - anchor.relativeTop
            guard abs(scroll.contentView.bounds.minY - desired) > 0.5 else { return }
            ownedScrollY = max(minimumY, desired)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: ownedScrollY!))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }
}
