import AppKit
import EdmundCore

/// A document-scoped floating Find surface. Matching uses complete source;
/// draw-only TextKit highlights leave syntax and undo untouched.
@MainActor final class RecordEditorFinder: NSObject, EditorFindHandling {
    let bar = RecordFindBar(frame: .zero)
    private weak var editor: EditorTextView?
    private weak var folding: RecordCodeFolding?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var indexedSource = ""
    private var indexedQuery = ""
    private var searching = false
    private(set) var currentMatch: NSRange?
    private(set) var matches: [NSRange] = []
    private(set) var highlightedIndex: Int?
    var isPresented: Bool { !bar.isHidden }
    var string: String { editor?.string ?? "" }
    var layoutChanged: (() -> Void)?
    var revealMatch: ((NSRange) -> Void)?

    init(editor: EditorTextView, folding: RecordCodeFolding) {
        self.editor = editor; self.folding = folding
        super.init()
        bar.isHidden = true
        editor.findHandler = self
        bar.queryChanged = { [weak self] query in
            self?.saveQuery(query); self?.rebuild()
        }
        bar.optionsChanged = { [weak self] in self?.rebuild() }
        bar.navigate = { [weak self] forward in self?.navigate(forward: forward) }
        bar.replace = { [weak self] all in self?.replaceMatches(all: all) }
        bar.dismiss = { [weak self] in self?.hide() }
        bar.visibilityChanged = { [weak self] in self?.layoutChanged?() }
    }
    func perform(_ action: NSTextFinder.Action) {
        guard let editor else { return }
        switch action {
        case .showFindInterface, .showReplaceInterface:
            bar.isHidden = false
            bar.setReplacement(action == .showReplaceInterface)
            if bar.query.stringValue.isEmpty, let text = NSPasteboard(name: .find).string(forType: .string) { bar.query.stringValue = text }
            rebuild()
            layoutChanged?()
            bar.query.selectText(nil)
        case .hideFindInterface: hide()
        case .hideReplaceInterface: bar.setReplacement(false)
        case .nextMatch: navigate(forward: true)
        case .previousMatch: navigate(forward: false)
        case .setSearchString:
            let range = editor.selectedRange()
            guard range.length > 0, range.upperBound <= string.utf16.count else { return }
            bar.query.stringValue = (string as NSString).substring(with: range)
            saveQuery(bar.query.stringValue); rebuild(reveal: false)
        case .replace: replaceMatches(all: false)
        case .replaceAll: replaceMatches(all: true)
        case .replaceAndFind: replaceMatches(all: false)
        case .selectAll:
            matches.forEach { folding?.reveal($0) }
            editor.selectedRanges = matches.map(NSValue.init(range:))
        default: break
        }
    }
    private func saveQuery(_ query: String) {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents(); pasteboard.setString(query, forType: .string)
    }
    private func hide() {
        bar.isHidden = true; clearHighlights(); layoutChanged?()
        invalidateVisibleHighlights()
        if let currentMatch, currentMatch.upperBound <= string.utf16.count {
            folding?.reveal(currentMatch); editor?.setSelectedRange(currentMatch)
        }
        editor?.window?.makeFirstResponder(editor)
    }
    func editorToggleFind(replace: Bool) { perform(replace ? .showReplaceInterface : .showFindInterface) }
    func editorFindNext() { perform(.nextMatch) }
    func editorFindPrevious() { perform(.previousMatch) }
    func editorHideFind() { hide() }
    func willChange() {
        generation &+= 1; task?.cancel(); task = nil
        clearHighlights(); matches = []; currentMatch = nil; highlightedIndex = nil
    }
    func sourceChanged() {
        guard !DocumentRevision.sameSource(indexedSource, string) else { return }
        if isPresented { rebuild(reveal: false) }
        else { indexedSource = string; matches = []; currentMatch = nil; highlightedIndex = nil }
    }
    private func rebuild(reveal: Bool = true, navigation: Bool? = nil) {
        generation &+= 1; task?.cancel()
        let generation = generation, source = string, query = bar.query.stringValue
        let anchor = currentMatch?.location ?? editor?.selectedRange().location ?? 0
        clearHighlights(); matches = []; highlightedIndex = nil
        indexedSource = source; indexedQuery = query
        guard !query.isEmpty else {
            searching = false; currentMatch = nil; bar.updateCount(current: nil, total: 0); return
        }
        searching = true; bar.updateCount(current: nil, total: 0, searching: true)
        let sensitive = bar.caseSensitive, wholeWord = bar.wholeWord
        task = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let escaped = NSRegularExpression.escapedPattern(for: query)
                let pattern = wholeWord ? "(?<![\\p{L}\\p{N}_])(?:" + escaped + ")(?![\\p{L}\\p{N}_])" : escaped
                guard let regex = try? NSRegularExpression(pattern: pattern, options: sensitive ? [] : [.caseInsensitive]) else { return [NSRange]() }
                return regex.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)).map(\.range)
            }.value
            guard let self, !Task.isCancelled, self.generation == generation, DocumentRevision.sameSource(self.string, source),
                  DocumentRevision.sameSource(self.bar.query.stringValue, query) else { return }
            self.searching = false; self.matches = result
            if let navigation { self.navigate(forward: navigation); return }
            self.highlightedIndex = result.firstIndex { $0.location >= anchor } ?? (result.isEmpty ? nil : 0)
            self.currentMatch = self.highlightedIndex.map { result[$0] }
            self.refresh(reveal: reveal && self.isPresented)
        }
    }
    private func navigate(forward: Bool) {
        guard !bar.query.stringValue.isEmpty else { return }
        if searching || !DocumentRevision.sameSource(indexedSource, string) || !DocumentRevision.sameSource(indexedQuery, bar.query.stringValue) {
            rebuild(navigation: forward); return
        }
        guard !matches.isEmpty else { NSSound.beep(); return }
        clearHighlights()
        if isPresented, let current = highlightedIndex {
            highlightedIndex = (current + (forward ? 1 : matches.count - 1)) % matches.count
        } else {
            let selection = editor?.selectedRange() ?? NSRange(location: 0, length: 0)
            highlightedIndex = forward
                ? matches.firstIndex { $0.location >= selection.upperBound } ?? 0
                : matches.lastIndex { $0.upperBound <= selection.location } ?? matches.count - 1
        }
        currentMatch = highlightedIndex.map { matches[$0] }
        if !isPresented, let currentMatch { folding?.reveal(currentMatch); editor?.setSelectedRange(currentMatch) }
        refresh(reveal: true)
    }
    private func refresh(reveal: Bool) {
        bar.updateCount(current: highlightedIndex, total: matches.count)
        if reveal, let currentMatch {
            folding?.reveal(currentMatch)
            if let revealMatch { revealMatch(currentMatch) }
            else { editor?.scrollRangeToVisible(currentMatch) }
        }
        invalidateVisibleHighlights()
        editor?.needsDisplay = true
    }
    func refreshPresentation() { if isPresented { refresh(reveal: false) } }
    private func invalidateVisibleHighlights() {
        if isPresented { editor?.setFindMatches(matches, current: highlightedIndex) }
        else { editor?.clearFindMatches() }
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            for child in view.subviews where !child.isHidden { redraw(child) }
        }
        if let editor { redraw(editor) }
    }
    private func replaceMatches(all: Bool) {
        guard let editor, !editor.hasMarkedText(), !matches.isEmpty, DocumentRevision.sameSource(indexedSource, string) else { return }
        let replacement = bar.replacement.stringValue
        if all {
            let text = NSMutableString(string: string)
            for range in matches.reversed() { text.replaceCharacters(in: range, with: replacement) }
            folding?.reveal(NSRange(location: 0, length: string.utf16.count))
            editor.insertText(text as String, replacementRange: NSRange(location: 0, length: string.utf16.count))
        } else if let currentMatch {
            folding?.reveal(currentMatch); editor.insertText(replacement, replacementRange: currentMatch)
        }
        rebuild()
    }
    private func clearHighlights() { editor?.clearFindMatches() }
    func detach() {
        generation &+= 1; task?.cancel(); task = nil; clearHighlights()
        editor?.findHandler = nil
        bar.queryChanged = nil; bar.navigate = nil; bar.replace = nil; bar.dismiss = nil
        bar.visibilityChanged = nil; bar.optionsChanged = nil; layoutChanged = nil; revealMatch = nil
    }
}
