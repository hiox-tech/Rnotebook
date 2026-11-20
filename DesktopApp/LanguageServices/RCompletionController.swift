import AppKit
import Combine

/// Screen coordinates, with positive Y pointing up. Keep a gap around the real
/// insertion line; constrain the panel to the editor pane and visible display.
enum RCompletionPopupLayout {
    static func frame(caret: NSRect, viewport: NSRect, preferred: NSSize) -> NSRect? {
        let area = viewport.insetBy(dx: 4, dy: 4)
        guard caret.minX.isFinite, caret.minY.isFinite, caret.height > 0,
              area.width >= 140, caret.maxY > area.minY, caret.minY < area.maxY,
              caret.minX >= area.minX - 4, caret.minX <= area.maxX + 4 else { return nil }
        let below = max(0, caret.minY - area.minY - 6)
        let above = max(0, area.maxY - caret.maxY - 6)
        let useBelow = below >= preferred.height || below >= above
        let height = min(preferred.height, useBelow ? below : above)
        guard height >= 38 else { return nil }
        let width = min(preferred.width, area.width)
        return NSRect(x: min(max(caret.minX - 8, area.minX), area.maxX - width),
                      y: useBelow ? caret.minY - 6 - height : caret.maxY + 6,
                      width: width, height: height)
    }
}

@MainActor private final class RCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class RCompletionTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

@MainActor final class RCompletionController: NSObject {
    private weak var editor: NSTextView?
    private weak var model: RecordLayoutModel?
    private let settings: SourceEditorSettings
    let session = RavenSession()
    private var pending: Task<Void, Never>?
    private var changes: AnyCancellable?
    private var generation = 0
    private var acceptedSource = ""
    private var acceptedSelection = NSRange(location: 0, length: 0)
    private var replacement = NSRange(location: 0, length: 0)
    private(set) var candidates: [RCompletionCandidate] = []
    private(set) var signature: String?
    private let panel = RCompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private weak var popupParent: NSWindow?
    private let content = RCompletionList()
    var isPresented: Bool { panel.isVisible }
    var presentationFrame: NSRect? { isPresented ? panel.frame : nil }
    private var detached = false
    init(editor: NSTextView, model: RecordLayoutModel, settings: SourceEditorSettings) {
        self.editor = editor; self.model = model; self.settings = settings
        super.init()
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.level = .floating
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = content
        panel.setAccessibilityIdentifier("r-completion-panel")
        content.accept = { [weak self] in self?.acceptSelection() }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
        changes = settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.cancel()
                if !self.settings.completionEnabled { await self.session.stop() }
            }
        }
    }
    func sourceChanged() {
        guard let editor, editor.window?.isKeyWindow == true, editor.window?.firstResponder === editor else { return }
        schedule(manual: false)
    }
    func selectionChanged() {
        if editor?.selectedRange() != acceptedSelection { cancel() }
    }
    func schedule(manual: Bool) {
        cancel()
        guard !detached, settings.completionEnabled, let editor, !editor.hasMarkedText(), editor.isEditable,
              editor.selectedRange().length == 0 else { return }
        let source = editor.string, selection = editor.selectedRange()
        let map = RCodeDocument(source)
        guard map.block(at: selection.location) != nil, source.utf8.count < 1_048_576 else { return }
        let (prefix, range) = map.prefix(at: selection.location)
        let before = (source as NSString).substring(to: selection.location)
        let preferences = RCompletionPreferences(settings)
        guard preferences.shouldTrigger(manual: manual, prefix: prefix, preceding: String(before.last ?? " ")) else { return }
        guard let model else { return }
        let defaults = model.visualDefaults
        let rscript = NotebookRExecutable.locate(selected: defaults.string(forKey: "notebook.rscript"))
        let sibling = rscript?.deletingLastPathComponent().appendingPathComponent("R")
        let r = sibling.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0.path : nil } ?? "R"
        var libraries = model.notebook.inspectorSnapshot?.libraryPaths ?? []
        libraries.insert(NotebookLibrary.selected(defaults: defaults).path, at: 0)
        libraries = Array(NSOrderedSet(array: libraries)) as? [String] ?? libraries
        let environment = model.notebook.inspectorSnapshot?.packages.map { $0.name+"="+$0.version+"@"+$0.library }.joined(separator: "\n") ?? ""
        let worker = model.notebook.runtime
        let runtimeReady = !model.notebook.isBusy && model.notebook.state == .ready
        let version = generation
        pending = Task { @MainActor [weak self, weak editor] in
            if !manual { try? await Task.sleep(for: .milliseconds(preferences.delay)) }
            guard let self, !Task.isCancelled, settings.completionEnabled, generation == version,
                  let editor, DocumentRevision.sameSource(editor.string, source), !editor.hasMarkedText() else { return }
            var runtime: [RCompletionCandidate] = []
            let context = (before as NSString).range(of: #"[\p{L}\p{N}._$]*$"#, options: .regularExpression)
            if preferences.runtime, runtimeReady, context.location != NSNotFound {
                runtime = await worker.completionItems((before as NSString).substring(with: context))
            }
            let result = try? await session.complete(source, offset: selection.location, rExecutable: r,
                libraries: libraries, environmentKey: environment)
            guard !Task.isCancelled, !detached, settings.completionEnabled, generation == version,
                  DocumentRevision.sameSource(editor.string, source), editor.selectedRange() == selection, !editor.hasMarkedText() else { return }
            var merged: [RCompletionCandidate] = []
            var seen = Set<String>()
            let items = (result?.0 ?? []) + runtime
            for item in items.sorted(by: { ($0.isParameter ? 0 : 1, $0.label) < ($1.isParameter ? 0 : 1, $1.label) }) {
                guard preferences.parameters || !item.isParameter,
                      prefix.isEmpty || item.label.lowercased().hasPrefix(prefix.lowercased()),
                      !item.insertion.isEmpty, !item.insertion.contains("\n"), seen.insert(item.insertion).inserted else { continue }
                if let edit = item.range {
                    guard let block = map.block(at: edit.location), edit.upperBound <= block.bodyRange.upperBound else { continue }
                }
                merged.append(item)
                if merged.count == preferences.limit { break }
            }
            candidates = merged; signature = preferences.signature ? result?.1 : nil; replacement = range
            acceptedSource = source; acceptedSelection = selection
            guard !candidates.isEmpty || signature != nil else { return }
            present()
        }
    }
    private func present() {
        guard let editor, let window = editor.window, window.isKeyWindow, window.firstResponder === editor else { return }
        content.items = candidates; content.signature = signature; content.refresh()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        positionPanel()
    }
    func updatePosition() {
        guard isPresented else { return }
        positionPanel()
    }
    private func positionPanel() {
        guard let editor, let window = editor.window, window.isKeyWindow, window.firstResponder === editor,
              DocumentRevision.sameSource(editor.string, acceptedSource), editor.selectedRange() == acceptedSelection,
              !editor.hasMarkedText(), let display = window.screen else { cancel(); return }
        let caret = editor.firstRect(forCharacterRange: acceptedSelection, actualRange: nil)
        let visible = window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
            .intersection(window.convertToScreen(window.contentLayoutRect)).intersection(display.visibleFrame)
        guard let frame = RCompletionPopupLayout.frame(caret: caret, viewport: visible, preferred: content.preferredSize) else {
            cancel(); return
        }
        if popupParent !== window {
            popupParent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above); popupParent = window
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        content.layoutContent()
        if !panel.isVisible { panel.orderFront(nil) }
    }
    @objc private func windowChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === editor?.window else { return }
        if notification.name == NSWindow.didResignKeyNotification || notification.name == NSWindow.willCloseNotification { cancel() }
        else { updatePosition() }
    }
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
        if event.keyCode == 53 { let shown = isPresented; cancel(); return shown }
        if event.keyCode == 49 && flags == .control { schedule(manual: true); return true }
        guard isPresented else { return false }
        if flags.isEmpty, event.keyCode == 125 { content.move(1); return true }
        if flags.isEmpty, event.keyCode == 126 { content.move(-1); return true }
        if flags.isEmpty, [36,76,48].contains(event.keyCode), !candidates.isEmpty {
            if event.keyCode == 48 || settings.completionReturn { acceptSelection(); return true }
            cancel(); return false
        }
        if !flags.isEmpty { cancel() }
        return false
    }
    func pointerEvent(_ event: NSEvent) {
        // Candidate clicks and scrolling must reach the table before dismissal.
        if isPresented, event.window === panel { return }
        cancel()
    }
    func acceptSelection() {
        guard settings.completionEnabled, let editor, DocumentRevision.sameSource(editor.string, acceptedSource),
              editor.selectedRange() == acceptedSelection, !editor.hasMarkedText(),
              candidates.indices.contains(content.selected) else { cancel(); return }
        let item = candidates[content.selected], range = item.range ?? replacement
        guard let block = RCodeDocument(editor.string).block(at: range.location), range.upperBound <= block.bodyRange.upperBound else { cancel(); return }
        cancel()
        editor.insertText(item.insertion, replacementRange: range)
        editor.undoManager?.setActionName(L10n.string("代码补全"))
    }
    func cancel() {
        generation += 1; pending?.cancel(); pending = nil; candidates = []; signature = nil
        popupParent?.removeChildWindow(panel); popupParent = nil; panel.orderOut(nil)
    }
    func detach() {
        detached = true; cancel(); changes = nil; NotificationCenter.default.removeObserver(self)
        let service = session; Task { await service.stop() }
    }
}

@MainActor private final class RCompletionList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var items: [RCompletionCandidate] = []
    var signature: String?
    var accept: (() -> Void)?
    private let table = RCompletionTable()
    private let label = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let rowFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var preferredSize: NSSize {
        let longest = items.map { (($0.isParameter ? $0.insertion : $0.label) as NSString).size(withAttributes: [.font: rowFont]).width }.max() ?? 140
        let width = min(360, max(180, longest + 40, signature == nil ? 0 : 300))
        return NSSize(width: width, height: 16 + (items.isEmpty ? 0 : CGFloat(min(8, items.count)) * 22)
                      + (signature == nil ? 0 : 36))
    }
    var selected: Int { max(0, table.selectedRow) }
    override func loadView() {
        let column = NSTableColumn(identifier: .init("candidate")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 20; table.intercellSpacing = NSSize(width: 0, height: 2); table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        table.setAccessibilityIdentifier("r-completion-list")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false; scroll.drawsBackground = false; table.backgroundColor = .clear
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("r-signature-help")
        let surface = NSVisualEffectView(); surface.material = .popover; surface.blendingMode = .withinWindow
        surface.wantsLayer = true; surface.layer?.cornerRadius = 8; surface.layer?.masksToBounds = true
        surface.addSubview(label); surface.addSubview(scroll); view = surface
    }
    func layoutContent() {
        let width = max(0, view.bounds.width - 16)
        let candidateRoom: CGFloat = items.isEmpty ? 0 : 26
        let signatureHeight: CGFloat = signature == nil ? 0 : min(32, max(0, view.bounds.height - 16 - candidateRoom))
        label.frame = NSRect(x: 8, y: view.bounds.height - 8 - signatureHeight, width: width, height: signatureHeight)
        scroll.isHidden = items.isEmpty
        scroll.frame = NSRect(x: 8, y: 8, width: width, height: max(0, view.bounds.height - 16 - (signatureHeight > 0 ? signatureHeight + 4 : 0)))
        table.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }
    override func viewDidLayout() { super.viewDidLayout(); layoutContent() }
    func refresh() {
        loadViewIfNeeded(); label.stringValue = signature ?? ""; label.toolTip = signature; label.isHidden = signature == nil
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer:0), byExtendingSelection:false) }
    }
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(0,selected+delta),items.count-1)
        table.selectRowIndexes(IndexSet(integer:row), byExtendingSelection:false); table.scrollRowToVisible(row)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let text = NSTextField(labelWithString: item.isParameter ? item.insertion : item.label)
        text.font = rowFont; text.maximumNumberOfLines = 1; text.lineBreakMode = .byTruncatingTail
        text.toolTip = text.stringValue + (item.detail.isEmpty ? "" : "\n" + item.detail); text.setAccessibilityLabel(text.stringValue)
        return text
    }
    @objc private func clicked() { if table.selectedRow >= 0 { accept?() } }
}
