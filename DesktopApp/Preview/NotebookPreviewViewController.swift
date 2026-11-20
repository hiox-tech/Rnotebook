import AppKit
import Quartz
import EdmundCore

private final class NotebookPreviewRootView: NSView {
    var appearanceChanged: (() -> Void)?
    /// The text page's top corners follow the container shape but never drop
    /// below a small readable radius; the window host owns the bottom corners.
    private func applyTopCorners(_ radius: CGFloat = 12) {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = max(12, radius)
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true
    }
    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformTopRadius(.containerConcentric(12), bottomLeftRadius: nil, bottomRightRadius: nil)
    }
    @available(macOS 27.0, *)
    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        let radii = effectiveCornerRadii
        applyTopCorners(max(radii?.topLeft ?? 0, radii?.topRight ?? 0))
    }
    override func layout() {
        super.layout()
        if layer?.cornerRadius == 0 { applyTopCorners() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

/// Deliberately independent of the app's document, execution, export and completion hosts.
@MainActor final class NotebookPreviewViewController: NSViewController, QLPreviewingController, NSTextViewDelegate {
    private(set) var editor: EditorTextView!
    private(set) var modeControl: NSSegmentedControl!
    private var syntax: RecordRSyntaxAdapter?
    private var loading: Task<NotebookPreviewContent, Error>?
    private var requestGeneration = 0
    private var fittedWidth: CGFloat = -1
    private var fittingDocument = false

    override func loadView() {
        let root = NotebookPreviewRootView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.wantsLayer = true
        root.layer?.cornerCurve = .continuous
        root.layer?.cornerRadius = 12
        root.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        root.layer?.masksToBounds = true
        view = root
        preferredContentSize = root.frame.size
        let bundle = Bundle(for: Self.self)
        modeControl = NSSegmentedControl(labels: [bundle.localizedString(forKey: "源代码", value: "Code", table: nil), bundle.localizedString(forKey: "可视化", value: "Visual", table: nil)],
            trackingMode: .selectOne, target: self, action: #selector(changeMode(_:)))
        modeControl.selectedSegment = 1
        modeControl.setAccessibilityIdentifier("notebook-preview-mode")
        modeControl.setAccessibilityLabel(bundle.localizedString(forKey: "预览视图", value: "Preview View", table: nil))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        editor = EditorTextView.makeTextKit2(frame: NSRect(x: 0, y: 0, width: 800, height: 550),
            containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.heightTracksTextView = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24, height: 16)
        editor.typewriterModeEnabled = false
        editor.allowRemoteImages = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.sourcePresentationAttributes = RecordSourceTypography.attributes(for:)
        editor.delegate = self
        editor.setAccessibilityIdentifier("notebook-preview-text")
        var theme = EditorTheme.quickLook
        theme.fontName = NSFont.systemFont(ofSize: 13).fontName
        theme.monospaceFontSize = 13
        theme.lineSpacing = 6.5
        editor.applyTheme(theme, persist: false)
        scroll.documentView = editor
        root.addSubview(modeControl); root.addSubview(scroll)
        for child in [modeControl!, scroll] { child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            modeControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        root.appearanceChanged = { [weak self] in self?.refreshPresentation() }
        editor.isEditable = false
    }

    func preparePreviewOfFile(at url: URL) async throws {
        loading?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        let task = Task.detached(priority: .userInitiated) { try NotebookPreviewContent.load(from: url) }
        loading = task
        let content = try await task.value
        guard !Task.isCancelled, !task.isCancelled, generation == requestGeneration else { throw CancellationError() }
        _ = view
        // A missing bundled parser is a packaging error, not a silent unhighlighted preview.
        if syntax == nil { syntax = try RecordRSyntaxAdapter(editor: editor, lexer: RecordRTokenSource()) }
        editor.loadContent(content.source, unwrapHardWrapping: false)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        refreshPresentation()
        editor.scrollToBeginningOfDocument(nil)
        loading = nil
    }

    @objc func changeMode(_ sender: Any?) { refreshPresentation() }

    private func refreshPresentation() {
        guard editor != nil else { return }
        editor.viewMode = modeControl.selectedSegment == 0 ? .source : .edit
        // Edmund's mode setter enables editing; always restore preview-only behavior.
        editor.isEditable = false
        editor.showLineNumbers = modeControl.selectedSegment == 0
        editor.rerenderStyles()
        // The mode switch shares the page surface instead of exposing the
        // Quick Look host's gray backdrop. The host supplies the corner shape.
        view.layer?.backgroundColor = editor.backgroundColor.cgColor
        editor.enclosingScrollView?.backgroundColor = editor.backgroundColor
        syntax?.apply()
        if editor.viewMode == .source { RecordSourceTypography.apply(to: editor) }
        fittedWidth = -1
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        fitDocument()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitDocument()
    }

    private func fitDocument() {
        guard !fittingDocument, let editor, let scroll = editor.enclosingScrollView,
              scroll.contentSize.width > 0, abs(fittedWidth - scroll.contentSize.width) > 0.5 else { return }
        fittingDocument = true
        defer { fittingDocument = false }
        fittedWidth = scroll.contentSize.width
        editor.setFrameSize(NSSize(width: fittedWidth, height: editor.frame.height))
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        editor.sizeToFit()
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        loading?.cancel()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool { false }
}
