import AppKit
import SwiftUI
import EdmundCore

struct RecordNativeEditor: NSViewRepresentable {
    @ObservedObject var model: RecordLayoutModel
    @EnvironmentObject private var sourceSettings: SourceEditorSettings
    @EnvironmentObject private var appearanceSettings: AppearanceSettings
    func makeNSView(context: Context) -> RecordNativeEditorHost {
        RecordNativeEditorHost(model: model, sourceSettings: sourceSettings, appearanceSettings: appearanceSettings)
    }
    func updateNSView(_ view: RecordNativeEditorHost, context: Context) { view.update() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordNativeEditorHost, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    static func dismantleNSView(_ view: RecordNativeEditorHost, coordinator: ()) { view.detach() }
}

/// Current native editor host. Notebook execution belongs to the model, not text layout.
@MainActor final class RecordNativeEditorHost: NSView, NSTextViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    let model: RecordLayoutModel
    private let scroll = RecordNotebookScrollView()
    let editor: EditorTextView
    private(set) var minimap: RecordSourceMinimap!
    private(set) var outline: RecordDocumentOutline!
    private(set) var folding: RecordCodeFolding!
    private(set) var foldGutter: RecordFoldGutter!
    private(set) var documentFinder: RecordEditorFinder!
    private let owner = NSDocument()
    private(set) var outputs: RecordOutputLayout!
    private var syntax: RecordRSyntaxAdapter?
    private(set) var completion: RCompletionController?
    private var monitor: Any?
    private var pending = false
    private var detached = false
    private var loadingDocumentSource = false
    private var lastModel: Data
    private var fontSize: Double = 0
    private var minimapTopInset: CGFloat = 0
    let sourceSettings: SourceEditorSettings
    let appearanceSettings: AppearanceSettings
    private var sourceStyle = ""
    private var notebookTheme: EditorTheme!
    private var notebookUsesFontLeading = true
    private var lastObservedSelection = NSRange(location: 0, length: 0)
    private var cursorLayoutBounds = NSRect.null
    private var cursorLayoutTopInset: CGFloat = -1
    private lazy var viewport = RecordEditorViewport(editor: editor)
    private var updatingPresentation = false
    private var hostLayoutDepth = 0

    private struct SavedMenu {
        let item: NSMenuItem
        let action: Selector?
        weak var target: AnyObject?
    }
    private var savedMenus: [SavedMenu] = []

    init(model: RecordLayoutModel, sourceSettings: SourceEditorSettings = SourceEditorSettings(),
         appearanceSettings: AppearanceSettings = AppearanceSettings()) {
        self.model = model
        self.sourceSettings = sourceSettings
        self.appearanceSettings = appearanceSettings
        lastModel = Data(model.source.utf8)
        editor = EditorTextView.makeTextKit2(frame: NSRect(x: 0, y: 0, width: 640, height: 600),
            containerSize: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("record-native-host")
        setAccessibilityLabel(L10n.string("记录编辑区"))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = true
        scroll.contentView = RecordNotebookClipView()
        scroll.backgroundColor = .textBackgroundColor
        // Keep scrolling result content inside the native editor viewport;
        // it must not draw into or invalidate the toolbar's backdrop band.
        scroll.clipsToBounds = true
        scroll.wantsLayer = true
        scroll.contentView.clipsToBounds = true
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.masksToBounds = true
        // Native window geometry supplies the toolbar inset; the Visual tools
        // float above the same viewport. Text may scroll beneath both materials.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]; editor.textContainerInset = NSSize(width: 24, height: 20)
        editor.typewriterModeEnabled = false; editor.allowRemoteImages = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.requestSaveForAttachment = { completion in completion(false) }
        let resourceBundle = Bundle(for: RecordNativeEditorHost.self)
        // Relative images and user-pasted preview assets belong in a scratch
        // directory, never in the signed application resource bundle.
        model.recordAssetsDirectory = model.documentURL?.deletingLastPathComponent()
        owner.fileURL = model.documentURL
        editor.document = owner
        // Isolated theme defaults: applying preview styling must not change global preferences.
        editor.themeDefaults = UserDefaults(suiteName: "org.hiox.Rnotebook.Editor")!
        editor.theme = .load(from: editor.themeDefaults)
        notebookTheme = editor.theme
        notebookUsesFontLeading = editor.textLayoutManager?.usesFontLeading ?? true
        editor.delegate = self
        editor.markdownPasteboardText = RecordResultClipboard.markdownText(from:)
        editor.sourcePresentationAttributes = RecordSourceTypography.attributes(for:)
        editor.setAccessibilityIdentifier("record-native-editor")
        scroll.setAccessibilityIdentifier("record-notebook")
        scroll.documentView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        minimap = RecordSourceMinimap(editor: editor, scroll: scroll)
        minimap.isHidden = true
        addSubview(minimap)
        folding = RecordCodeFolding(editor: editor)
        minimap.revealSource = { [weak self] range in self?.folding.reveal(range) }
        foldGutter = RecordFoldGutter(editor: editor, folding: folding)
        addSubview(foldGutter)
        outline = RecordDocumentOutline(frame: .zero)
        outline.editor = editor
        addSubview(outline)
        outline.navigate = { [weak self] range in
            self?.navigateSource(range, moveInsertionPoint: false)
        }
        folding.willChange = { [weak self] range in self?.viewport.willFold(range) }
        folding.didChange = { [weak self] in self?.viewport.didFold() }
        folding.onChange = { [weak self] in
            self?.foldGutter.refresh()
            self?.minimap.needsDisplay = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !self.detached else { return }
                self.foldGutter.refresh()
            }
        }
        documentFinder = RecordEditorFinder(editor: editor, folding: folding)
        documentFinder.revealMatch = { [weak self] range in
            self?.viewport.navigate(to: range, moveInsertionPoint: false, centered: true)
        }
        addSubview(documentFinder.bar)
        documentFinder.layoutChanged = { [weak self] in
            guard let self, !self.detached else { return }
            self.needsLayout = true; self.layoutSubtreeIfNeeded()
            self.documentFinder.refreshPresentation()
        }
        RecordMermaidRuntime.prepare(bundle: resourceBundle)
        editor.loadContent(model.source, unwrapHardWrapping: false)
        if !ProcessInfo.processInfo.arguments.contains("--record-no-results") { outputs = RecordOutputLayout(editor: editor, model: model) }
        if let outputs {
            outputs.editorChromeCursor = { [weak self] point in self?.toolbarCursor(at: point) }
            outputs.editorChromeRects = { [weak self] in self?.toolbarCursorRects ?? [] }
        } else {
            editor.embeddedViewCursor = { [weak self] point in self?.toolbarCursor(at: point) }
            editor.embeddedViewRects = { [weak self] in self?.toolbarCursorRects ?? [] }
        }
        if !ProcessInfo.processInfo.arguments.contains("--record-no-syntax"),
           let lexer = try? RecordRTokenSource(bundle: resourceBundle) {
            syntax = RecordRSyntaxAdapter(editor: editor, lexer: lexer)
        }
        editor.viewportLayoutDidComplete = { [weak self] in
            guard let self else { return }
            self.viewport.layoutDidComplete()
            self.foldGutter?.refresh()
            if !self.model.sourceOnly { self.outputs?.layoutViewportDidComplete() }
            self.trackVisibleSource()
        }
        editor.explicitNavigationWillBegin = { [weak self] in
            guard let self, !viewport.isAdjusting else { return }
            cancelModeViewportAnchor()
        }
        editor.viewportDelegate = viewport
        NotificationCenter.default.addObserver(self, selector: #selector(userScrollWillBegin), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        model.activeEditor = editor
        completion = RCompletionController(editor: editor, model: model, settings: sourceSettings)
        model.requestRCompletion = { [weak self] in self?.completion?.schedule(manual: true) }
        for name in [NSText.didChangeNotification, NSTextStorage.didProcessEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name,
                object: name == NSText.didChangeNotification ? editor : editor.textStorage)
        }
        if !ProcessInfo.processInfo.arguments.contains("--record-no-menu-gate") {
            NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: nil)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown {
                self.completion?.pointerEvent(event)
                if event.window === self.window {
                    if event.type == .scrollWheel { self.cancelModeViewportAnchor() }
                    else if let root = self.window?.contentView,
                            let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                            hit.isDescendant(of: self) { self.cancelModeViewportAnchor() }
                }
                return event
            }
            guard self.hasEditorFocus else { return event }
            let modeShortcut = event.modifierFlags.intersection([.command, .control, .shift, .option]) == [.command, .control]
                && ["1", "2"].contains(event.charactersIgnoringModifiers ?? "")
            if !modeShortcut { self.cancelModeViewportAnchor() }
            if self.completion?.handle(event) == true { return nil }
            self.updateHistoryMenus()
            if self.handleNotebookShortcut(event) { return nil }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
                if self.editor.hasMarkedText() { return event }
                if event.modifierFlags.contains(.shift) { self.redoSource(nil) } else { self.undoSource(nil) }
                return nil
            }
            if !self.model.sourceOnly, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               let key = event.charactersIgnoringModifiers?.lowercased(), ["b", "i", "k"].contains(key) {
                self.model.format(key == "b" ? .bold : key == "i" ? .italic : .link)
                return nil
            }
            return event
        }
        update()
    }
    required init?(coder: NSCoder) { nil }
    var toolbarCursorRects: [NSRect] {
        guard let window, !detached else { return [] }
        var rects: [NSRect] = []
        if model.windowTopInset > 0 {
            let header = NSRect(x: bounds.minX, y: bounds.maxY - model.windowTopInset,
                                width: bounds.width, height: model.windowTopInset)
            rects.append(editor.convert(header, from: self))
        }
        if !model.sourceOnly, let toolbar = model.visualToolbarCursorView, toolbar.window === window, !toolbar.isHidden {
            rects.append(editor.convert(toolbar.bounds, from: toolbar))
        }
        return rects.filter { !$0.isEmpty }
    }
    func toolbarCursor(at point: NSPoint) -> NSCursor? {
        toolbarCursorRects.contains { $0.contains(point) } ? .arrow : nil
    }
    override func viewWillStartLiveResize() {
        viewport.beginPresentation(intent: .resize)
        super.viewWillStartLiveResize()
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        let generation = viewport.generation
        // AppKit notifies the NSTextView descendant after this host. Finish the
        // same transaction once that native callback has returned, without timers.
        RunLoop.main.perform { [weak self] in
            guard let self, !detached, viewport.generation == generation else { return }
            viewport.endPresentation()
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if let window {
            model.notebook.window = window; schedule()
            if let state = model.pendingViewState {
                model.pendingViewState = nil
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !detached else { return }
                    viewport.cancel()
                    layoutSubtreeIfNeeded()
                    let location = min(max(0, state.location), editor.string.utf16.count)
                    let length = min(max(0, state.length), editor.string.utf16.count - location)
                    editor.setSelectedRange(NSRange(location: location, length: length))
                    let top = minimumScrollY
                    let bottom = max(top, editor.frame.height - scroll.contentSize.height + scroll.contentInsets.bottom)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(top, CGFloat(state.scrollY)), bottom)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }
    override func layout() {
        hostLayoutDepth += 1
        defer { hostLayoutDepth -= 1 }
        super.layout()
        // Both children stay inside the editor's existing finite middle-column bounds.
        let width = RecordNavigationGeometry.width(for: bounds.width)
        // Keep one full-width scroll surface under the native toolbar so its
        // system edge continues across the fixed minimap as well.
        scroll.overviewWidth = width
        scroll.foldGutterWidth = model.sourceOnly ? 18 : 0
        scroll.frame = bounds
        // The editor scrolls beneath the native toolbar; the overview starts
        // at its lower edge instead of drawing into the titlebar backdrop.
        // Keep the minimap's opaque fill below the native separator's backing
        // pixel; otherwise its top row covers that pixel at the toolbar edge.
        let separatorPixel = 1 / (window?.backingScaleFactor ?? 2)
        minimap.frame = NSRect(x: max(0, bounds.width - width), y: 0, width: width,
            height: max(0, bounds.height - minimapTopInset - separatorPixel))
        outline.frame = minimap.frame
        let search = documentFinder.bar
        let searchWidth = min(560, max(0, bounds.width - width - 32))
        search.frame = NSRect(x: max(0, (bounds.width - width - searchWidth) / 2), y: 12,
            width: searchWidth, height: search.preferredHeight)
        let bottom = documentFinder.isPresented ? search.preferredHeight + 24 : 0
        if scroll.contentInsets.bottom != bottom { scroll.contentInsets.bottom = bottom }
        foldGutter.frame = NSRect(x: 0, y: 0, width: 18,
            height: max(0, bounds.height - minimapTopInset))
        foldGutter.refresh()
        minimap.needsDisplay = true
        if cursorLayoutBounds != bounds || cursorLayoutTopInset != model.windowTopInset {
            cursorLayoutBounds = bounds; cursorLayoutTopInset = model.windowTopInset
            window?.invalidateCursorRects(for: editor)
        }
        // Removing the Code fold gutter changes the clip width after theme
        // presentation. Consume that resize now, before the first wheel event.
        outputs?.viewportChanged(Notification(name: NSView.frameDidChangeNotification, object: editor))
    }
    private var readingTopInset: CGFloat { scroll.contentInsets.top }
    private var minimumScrollY: CGFloat {
        let clip = scroll.contentView
        return clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: -scroll.contentInsets.top), size: clip.bounds.size)).minY
    }
    private var lastOutputRevision: UInt64 = .max
    func navigateSource(_ range: NSRange, moveInsertionPoint: Bool = true) {
        guard !editor.hasMarkedText() else { return }
        folding.reveal(range)
        viewport.navigate(to: range, moveInsertionPoint: moveInsertionPoint)
        outline.track(offset: range.location)
        outputs?.settleViewport()
        if moveInsertionPoint { window?.makeFirstResponder(editor) }
    }
    var onUpdateTiming: ((String, Double) -> Void)?
    @objc private func userScrollWillBegin() { viewport.cancel() }
    @objc private func scrolled() {
        if !updatingPresentation, hostLayoutDepth == 0 { viewport.didScroll() }
        updateTitlebarSeparator(); completion?.updatePosition()
        foldGutter?.refresh()
        trackVisibleSource()
    }
    private func trackVisibleSource() {
        guard !model.sourceOnly, !viewport.isNavigating else { return }
        viewport.refreshSnapshot()
        guard let snapshot = viewport.snapshot else { return }
        let height = max(0, snapshot.viewport.height - scroll.contentInsets.top - scroll.contentInsets.bottom)
        let y = snapshot.viewport.minY + scroll.contentInsets.top + height / 3
        if let block = outputs?.blockAtResultPoint(NSPoint(x: editor.textContainerOrigin.x + 2, y: y)) {
            outline?.track(offset: block.range.location)
        } else if let offset = snapshot.readingOffset(at: y) { outline?.track(offset: offset) }
    }
    private func updateTitlebarSeparator() {
        guard let window, !detached else { return }
        // AppKit's automatic scroll-edge decoration stops at the text viewport
        // when a fixed minimap sits beside it. Use the window's native separator
        // across the unified toolbar and derive its visibility from the real
        // inset-adjusted scroll origin, including wheel and minimap navigation.
        let style: NSTitlebarSeparatorStyle
        if model.sourceOnly {
            let offset = scroll.contentView.bounds.minY - minimumScrollY
            style = offset > 1 / window.backingScaleFactor ? .line : .none
        } else {
            style = .automatic
        }
        if window.titlebarSeparatorStyle != style { window.titlebarSeparatorStyle = style }
    }
    func handleNotebookShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard [36,76].contains(event.keyCode), flags.contains(.command), !flags.contains(.control) else { return false }
        if flags.contains(.shift) { model.runAllNotebookCells() }
        else if flags.contains(.option) { model.runNotebookSelection() }
        else { model.runCurrentNotebookCell() }
        return true
    }
    private func cancelModeViewportAnchor() { viewport.cancel() }
    var hasEditorFocus: Bool { window?.isKeyWindow == true && window?.firstResponder === editor }
    func update() {
        let timingStart = ProcessInfo.processInfo.systemUptime
        func timing(_ stage: String) { onUpdateTiming?(stage, ProcessInfo.processInfo.systemUptime - timingStart) }
        owner.fileURL = model.documentURL
        model.recordAssetsDirectory = model.documentURL?.deletingLastPathComponent()
        guard !detached, !editor.hasMarkedText(), Data(editor.rawSource.utf8) == Data(editor.string.utf8) else { return }
        let targetMode: EditorTextView.ViewMode = model.sourceOnly ? .source : .edit
        let changingMode = editor.viewMode != targetMode
        let changingResults = !model.sourceOnly && lastOutputRevision != .max && lastOutputRevision != model.outputRevision
        let syntaxPreferences = RecordSyntaxPreferences(sourceSettings)
        let syntaxKey = syntaxPreferences == RecordSyntaxPreferences() ? "" : syntaxPreferences.key
        let changingSyntax = editor.codeSyntaxPresentationKey != syntaxKey
        let preservingPresentation = changingMode || changingResults || changingSyntax
        if preservingPresentation { viewport.beginPresentation(mode: targetMode) }
        syntax?.preferences = syntaxPreferences
        editor.codeSyntaxPresentationKey = syntaxKey
        editor.codeSyntaxAttributes = syntaxKey.isEmpty ? nil : { type, dark, font in
            var attributes = syntaxPreferences.attributes(RecordSyntaxPreferences.nativeScope(type), dark: dark, font: font)
            if syntaxPreferences.enabled && syntaxPreferences.palette == "default" {
                attributes.removeValue(forKey: .foregroundColor)
            }
            return attributes
        }
        timing("capture")
        updatingPresentation = true
        defer {
            updatingPresentation = false
            if preservingPresentation { viewport.endPresentation() }
            timing("complete")
        }
        let top = model.windowTopInset + (model.sourceOnly ? 0 : RecordVisualToolbarGeometry.contentInset)
        if minimapTopInset != model.windowTopInset {
            minimapTopInset = model.windowTopInset
            needsLayout = true
        }
        editor.additionalTopInset = top
        updateTitlebarSeparator()
        var presentationChanged = false
        var visibleSelectionToPreserve: NSRange?
        let incoming = Data(model.source.utf8)
        let sourceChanged = incoming != lastModel
        if sourceChanged {
            if !pending, incoming != Data(editor.rawSource.utf8) {
                editor.loadContent(model.source, unwrapHardWrapping: false); presentationChanged = true
            }
            lastModel = incoming
        }
        let mode: EditorTextView.ViewMode = model.sourceOnly ? .source : .edit
        let style = (model.sourceOnly
            ? "\(sourceSettings.fontName)|\(sourceSettings.fontSize)"
            : "visual|\(model.visualFontName)|\(model.visualCodeFontName)|\(model.visualCodeFontSize)") + "|" + syntaxPreferences.key
        if editor.viewMode != mode || sourceStyle != style || fontSize != model.fontSize {
            let range = editor.selectedRange()
            let caret = editor.firstRect(forCharacterRange: range, actualRange: nil)
            if let window, range.length == 0, caret.height > 0 {
                var visible = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                visible.size.height = max(0, visible.height - readingTopInset)
                if caret.minY >= visible.minY - 1, caret.maxY <= visible.maxY + 1 {
                    visibleSelectionToPreserve = range
                }
            }
            let selection = editor.selectedRanges
            let scrollPosition = scroll.contentView.bounds.origin
            notebookTheme.fontSize = model.fontSize
            notebookTheme.fontName = model.visualFontName == "system" ? NSFont.systemFont(ofSize: model.fontSize).fontName : model.visualFontName
            notebookTheme.monospaceFontName = ["system", "SF Mono"].contains(model.visualCodeFontName) ? "" : model.visualCodeFontName
            notebookTheme.monospaceFontSize = model.visualCodeFontSize
            notebookTheme.lineSpacing = model.fontSize * 0.5
            notebookTheme.paragraphSpacingBefore = 6
            var theme = notebookTheme!
            if model.sourceOnly {
                theme.fontSize = sourceSettings.fontSize
                theme.monospaceFontName = ["system", "SF Mono"].contains(sourceSettings.fontName) ? "" : sourceSettings.fontName
                theme.monospaceFontSize = sourceSettings.fontSize
            }
            editor.appearance = nil
            editor.textLayoutManager?.usesFontLeading = model.sourceOnly ? false : notebookUsesFontLeading
            editor.applyTheme(theme, persist: false, viewMode: mode)
            timing("theme")
            editor.showLineNumbers = model.sourceOnly
            // Keep the component's extra scrolling room below the document,
            // while giving source a smaller top margin than notebook prose.
            editor.selectedRanges = selection
            if !viewport.isPreservingViewport { scroll.contentView.scroll(to: scrollPosition) }
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                scroll.backgroundColor = .textBackgroundColor
            }
            fontSize = model.fontSize; sourceStyle = style
            presentationChanged = true
        }
        let topPadding: CGFloat = model.sourceOnly ? 8 : 20
        let paddingChange = topPadding - editor.textContainerOrigin.y
        if abs(paddingChange) > 0.5 {
            editor.textContainerInset.height += paddingChange
            editor.sizeToFit()
        }
        folding.update(source: editor.rawSource, enabled: model.sourceOnly)
        timing("folding")
        outline.update(folding.structure.headings)
        outline.isHidden = model.sourceOnly
        foldGutter.isHidden = !model.sourceOnly
        outputs?.hidesForSource = model.sourceOnly
        // Results are measured against the final mode's text width, including
        // the native ruler and Code fold slot, before reserving their heights.
        let foldWidth: CGFloat = model.sourceOnly ? 18 : 0
        if presentationChanged || scroll.foldGutterWidth != foldWidth {
            scroll.foldGutterWidth = foldWidth
            scroll.tile()
        }
        if minimap.isHidden == model.sourceOnly {
            minimap.isHidden = !model.sourceOnly
            needsLayout = true
        }
        minimap.appearance = editor.appearance
        editor.selectionAccentColor = appearanceSettings.accent.color
        editor.findHighlightColor = appearanceSettings.accent.color
        minimap.selectionAccentColor = appearanceSettings.accent.color
        outline.selectionAccentColor = appearanceSettings.accent.color
        outline.refreshBackground()
        if presentationChanged {
            syntax?.apply(); outputs?.apply()

        }
        timing("outputs")
        if model.sourceOnly {
            // Full Code presentation already installs these exact base
            // attributes. Only local source changes need the repair scan.
            if sourceChanged && !presentationChanged { RecordSourceTypography.apply(to: editor) }
            if presentationChanged { minimap.rebuild() }
        }
        if lastOutputRevision != model.outputRevision { lastOutputRevision = model.outputRevision; outputs?.apply() }
        outputs?.refreshExecutionControls()
        foldGutter.refresh()
        documentFinder.sourceChanged()
        updateHistoryMenus()
        timing("end")
        if !viewport.isPreservingViewport, let selection = visibleSelectionToPreserve { scheduleSelectionReveal(selection) }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        completion?.selectionChanged()
        schedule()
        let selection = editor.selectedRange()
        if !updatingPresentation { viewport.selectionChanged() }
        if selection.length == 0 { folding?.reveal(selection) }
        guard selection != lastObservedSelection else { return }
        lastObservedSelection = selection
        // NSTextView posts selection changes before didChangeText commits and
        // restyles the new source. Do not queue navigation on provisional rows.
        guard Data(editor.rawSource.utf8) == Data(editor.string.utf8) else { return }
        scheduleSelectionReveal(selection)
    }
    private func scheduleSelectionReveal(_ selection: NSRange) {
        guard !loadingDocumentSource, !detached, !inLiveResize else { return }
        viewport.requestCaretReveal(selection)
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        documentFinder.willChange()
        folding.reveal(affectedCharRange, touchingBoundary: true)
        return true
    }
    @objc private func changed(_ notification: Notification) {
        // Syntax and deferred Visual styling edit attributes while scrolling.
        // Only source edits require a model/editor update.
        if let storage = notification.object as? NSTextStorage, !storage.editedMask.contains(.editedCharacters) { return }
        schedule()
    }
    private func schedule() {
        guard !pending, !detached, !loadingDocumentSource else { return }
        pending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.detached else { return }
            self.pending = false
            self.publishCommittedText()
        }
    }
    func publishCommittedText() {
        guard !editor.hasMarkedText(), Data(editor.rawSource.utf8) == Data(editor.string.utf8) else { return }
        var committedEdit = false
        if !editor.rawSource.utf8.elementsEqual(model.source.utf8) {
            committedEdit = true
            lastModel = Data(editor.rawSource.utf8)
            model.source = editor.rawSource
            completion?.sourceChanged()
        }
        update()
        model.refreshVisualContext()
        // Native selection notifications during typing were provisional. Once
        // source and rows agree, allow the bounded missing-caret check again
        // (notably when a long paste moves the caret outside the old viewport).
        if committedEdit { scheduleSelectionReveal(editor.selectedRange()) }
    }
    func loadSynchronizedSource(_ text: String) {
        guard !detached, !editor.hasMarkedText() else { return }
        completion?.cancel()
        loadingDocumentSource = true
        defer { loadingDocumentSource = false }
        let selection = editor.selectedRange(), origin = scroll.contentView.bounds.origin
        pending = false
        editor.loadContent(text, unwrapHardWrapping: false)
        lastModel = Data(text.utf8)
        let location = min(selection.location, editor.string.utf16.count)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, editor.string.utf16.count - location)))
        scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
        syntax?.apply(); outputs?.apply(); minimap.rebuild(); update()
    }
    func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        // AppKit's rich-text font, spelling and substitution commands bypass
        // the Markdown source and the application's presentation settings.
        let editing = NSMenu()
        editing.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { editing.automaticallyInsertsWritingToolsItems = false }
        editing.delegate = self
        for (title, action, key) in [
            (L10n.string("剪切"), #selector(NSText.cut(_:)), "x"),
            (L10n.string("拷贝"), #selector(NSText.copy(_:)), "c"),
            (L10n.string("粘贴"), #selector(NSText.paste(_:)), "v"),
            (L10n.string("全选"), #selector(NSText.selectAll(_:)), "a")
        ] {
            if action == #selector(NSText.selectAll(_:)) { editing.addItem(.separator()) }
            let item = editing.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = textView
        }
        return editing
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard model.sourceOnly else { return }
        // The component appends rendered-table commands after the text-view
        // delegate returns. They apply only to notebook cells, never source.
        let actions: Set<Selector> = [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
            #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))]
        for item in menu.items where !item.isSeparatorItem && item.action.map(actions.contains) != true {
            menu.removeItem(item)
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }
    private func isHistoryItem(_ item: NSMenuItem) -> Bool {
        let action = item.action.map(NSStringFromSelector) ?? ""
        return action == "undo:" || action == "redo:"
            || (item.keyEquivalent.lowercased() == "z" && item.keyEquivalentModifierMask.contains(.command))
    }
    @objc private func windowUpdated(_ notification: Notification) {
        updateHistoryMenus(); completion?.updatePosition(); documentFinder.sourceChanged()
    }
    @objc func undoSource(_ sender: Any?) { guard !editor.hasMarkedText() else { return }; editor.undo(sender); publishCommittedText() }
    @objc func redoSource(_ sender: Any?) { guard !editor.hasMarkedText() else { return }; editor.redo(sender); publishCommittedText() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !editor.hasMarkedText() else { return false }
        if menuItem.action == #selector(undoSource(_:)) { return editor.canUndoSource }
        if menuItem.action == #selector(redoSource(_:)) { return editor.canRedoSource }
        return false
    }
    func updateHistoryMenus() {
        guard !ProcessInfo.processInfo.arguments.contains("--record-no-menu-gate") else { return }
        guard hasEditorFocus, !detached else { restoreHistoryMenus(); return }
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { visit(submenu) }
                guard isHistoryItem(item) else { continue }
                let redo = item.action.map(NSStringFromSelector) == "redo:" || item.action == #selector(redoSource(_:)) || item.keyEquivalentModifierMask.contains(.shift)
                if item.target !== self { savedMenus.append(SavedMenu(item: item, action: item.action, target: item.target)) }
                item.target = self; item.action = redo ? #selector(redoSource(_:)) : #selector(undoSource(_:))
                item.isEnabled = validateMenuItem(item)
            }
        }
        if let menu = NSApp.mainMenu { visit(menu) }
    }
    private func restoreHistoryMenus() {
        for saved in savedMenus where saved.item.target === self {
            saved.item.action = saved.action; saved.item.target = saved.target
        }
        savedMenus.removeAll()
    }
    func detach() {
        guard !detached else { return }
        detached = true; cancelModeViewportAnchor(); completion?.detach(); completion = nil; restoreHistoryMenus()
        minimap.detach()
        folding.detach(); documentFinder.detach()
        outline.navigate = nil
        outputs?.detach()
        editor.embeddedViewCursor = nil; editor.embeddedViewRects = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        NotificationCenter.default.removeObserver(self)
        if model.activeEditor === editor { model.activeEditor = nil; model.requestRCompletion = nil }
        editor.viewportDelegate = nil
        editor.codeSyntaxAttributes = nil
        editor.viewportLayoutDidComplete = nil; editor.explicitNavigationWillBegin = nil
        editor.delegate = nil
    }
}

/// Keep one scroll surface across the whole editor column so AppKit's native
/// toolbar backdrop and scroll edge cover the overview too. Only the text
/// viewport and its scroller reserve space for the fixed minimap overlay.
@MainActor private final class RecordNotebookClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.x = 0
        return constrained
    }
}

@MainActor private final class RecordNotebookScrollView: NSScrollView {
    var overviewWidth: CGFloat = 0 {
        didSet { if oldValue != overviewWidth { tile() } }
    }
    var foldGutterWidth: CGFloat = 0 {
        didSet { if oldValue != foldGutterWidth { tile() } }
    }
    override func tile() {
        super.tile()
        guard overviewWidth > 0 || foldGutterWidth > 0 else { return }
        var viewport = contentView.frame
        let right = viewport.maxX - overviewWidth
        let rulerRight = rulersVisible ? verticalRulerView?.frame.maxX ?? viewport.minX : viewport.minX
        viewport.origin.x = max(viewport.minX, rulerRight) + foldGutterWidth
        viewport.size.width = max(0, right - viewport.minX)
        contentView.frame = viewport
        // Installing a native ruler can leave the clip temporarily wider than
        // its document and center the document at a negative horizontal origin.
        // This editor wraps to the viewport and has no horizontal scroll range.
        if let document = documentView {
            var frame = document.frame
            frame.origin.x = 0
            frame.size.width = viewport.width
            if document.frame != frame { document.frame = frame }
        }
        if contentView.bounds.minX != 0 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.minY))
        }
        if let ruler = verticalRulerView, rulersVisible {
            var frame = ruler.frame; frame.origin.x += foldGutterWidth; ruler.frame = frame
        }
        if let scroller = verticalScroller {
            var frame = scroller.frame
            frame.origin.x -= overviewWidth
            scroller.frame = frame
        }
    }
}

/// Source rows use one grid, including separators that the component resets to
/// body attributes. Keep this in the host so notebook typography stays untouched.
@MainActor enum RecordMermaidRuntime {
    private(set) static var ready = false
    static func prepare(bundle: Bundle) {
        guard !ready else { return }
        guard let script = bundle.url(forResource: "beautiful-mermaid", withExtension: "js", subdirectory: "RecordPreviewAssets/Mermaid"),
              MermaidRenderer.shared.loadBundled(from: script.deletingLastPathComponent(),
                scriptSHA256: "135071f07173aba0473343630291d93d0b065e76a3db4619937b8d87cf4fb86c") else {
            NSLog("Record Mermaid: bundled runtime could not be loaded")
            return
        }
        MermaidRenderer.shared.isEnabled = true
        ready = true
    }
}
