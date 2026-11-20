import AppKit
import Combine
import SwiftUI
import EdmundCore

@MainActor final class QMDDocument: NSDocument {
    let model = RecordLayoutModel(initialSource: "", usesProcessArguments: false)
    private var changes: AnyCancellable?
    private var savePanelTypeDelegate: NotebookSavePanelTypeDelegate?
    private var reading = false
    var sourceSettings = NotebookPreferences.source
    var appearance = NotebookPreferences.appearance
    var visual = NotebookPreferences.visual
    private let recoveryStore: DocumentRecoveryStore
    private let recoveryID: UUID
    let behavior: DocumentBehaviorSettings
    private let autosaveDelay: TimeInterval?
    private let maximumAutosaveDelay: TimeInterval?
    private(set) var windowPlacement: NotebookWindowPlacement?
    lazy var synchronization = QMDFileSynchronization(document: self, idleDelay: autosaveDelay, maximumDelay: maximumAutosaveDelay)
    private var cleanSourceHash = DocumentRevision(text: "").rawValue
    private(set) var sourceIsModified = false
    private(set) var recoveredFromURL: URL?
    private var recoveredDraftID: String?
    private var restoredUnsavedCopy = false
    private var initialSaveRequest: InitialSaveRequest?
    private(set) var recoveryAvailable = false
    override class var autosavesInPlace: Bool { true }
    override convenience init() { self.init(recoveryStore: .shared) }
    init(recoveryStore: DocumentRecoveryStore, recoveryID: UUID = UUID(), autosaveDelay: TimeInterval? = nil, maximumAutosaveDelay: TimeInterval? = nil,
         behavior: DocumentBehaviorSettings = NotebookPreferences.documents) {
        self.behavior = behavior
        self.autosaveDelay = autosaveDelay; self.maximumAutosaveDelay = maximumAutosaveDelay
        self.recoveryStore = recoveryStore
        self.recoveryID = recoveryID
        super.init()
        fileType = NotebookDocumentType.quarto
        model.document = self
        changes = model.$source.dropFirst().sink { [weak self] text in
            guard let self, !reading, !DocumentRevision.sameSource(text, model.source) else { return }
            sourceIsModified = restoredUnsavedCopy || DocumentRevision(text: text).rawValue != cleanSourceHash
            if !sourceIsModified { updateChangeCount(.changeCleared) }
            else { updateChangeCount(.changeDone); persistRecovery(source: text); synchronization.sourceChanged() }
        }
    }
    private func persistRecovery(source: String) {
        do {
            try recoveryStore.write(id: recoveryID, source: source, originalURL: fileURL ?? recoveredFromURL)
            recoveryAvailable = true
        } catch { recoveryAvailable = false; model.notice = L10n.string("自动恢复暂存不可用：") + error.localizedDescription }
    }
    func discardRecovery() {
        recoveryStore.remove(id: recoveryID.uuidString)
        if let recoveredDraftID { recoveryStore.remove(id: recoveredDraftID) }
        recoveredDraftID = nil; recoveryAvailable = false
    }
    func restore(_ draft: DocumentRecoveryStore.Draft) {
        restoredUnsavedCopy = true
        sourceIsModified = true
        recoveredFromURL = draft.originalURL
        if let originalURL = draft.originalURL { fileType = NotebookDocumentType.identifier(for: originalURL) }
        displayName = L10n.string("恢复的 ") + draft.title
        model.source = draft.source
        // Empty source is also a valid unsaved edit (e.g. deleting all text).
        updateChangeCount(.changeDone); persistRecovery(source: draft.source)
        recoveredDraftID = draft.id
        // Transfer ownership only after another durable snapshot exists. If
        // staging fails (e.g. full disk), keep the original until save/discard.
        if recoveryAvailable { recoveryStore.remove(id: draft.id) }
    }
    override func read(from url: URL, ofType typeName: String) throws {
        try super.read(from: url, ofType: typeName)
        MainActor.assumeIsolated { synchronization.received(model.source, at: url) }
    }
    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Rnotebook", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.string("QMD/RMD 必须为 UTF-8 文本，原文件未更改。")])
        }
        MainActor.assumeIsolated {
            reading = true; model.source = text; reading = false
            if [NotebookDocumentType.quarto, NotebookDocumentType.rMarkdown].contains(typeName) { fileType = typeName }
            cleanSourceHash = DocumentRevision(text: text).rawValue
            sourceIsModified = false
            if let fileURL { synchronization.received(text, at: fileURL) }
        }
    }
    override func data(ofType typeName: String) throws -> Data { Data(model.source.utf8) }
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        guard super.prepareSavePanel(savePanel) else { return false }
        if #available(macOS 15.0, *) {
            let delegate = NotebookSavePanelTypeDelegate(original: savePanel.delegate)
            savePanelTypeDelegate = delegate
            savePanel.delegate = delegate
        }
        return true
    }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try MainActor.assumeIsolated { try writeOnMain(to: url, ofType: typeName, for: saveOperation) }
    }
    private func writeOnMain(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        (model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)?.publishCommittedText()
        guard model.activeEditor?.hasMarkedText() != true,
              model.activeEditor.map({ $0.string.utf8.elementsEqual(model.source.utf8) }) ?? true else {
            throw NSError(domain: "Rnotebook", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.string("请先完成当前输入，再保存文档。")])
        }
        let updatesCurrentFile = [.saveOperation, .saveAsOperation, .autosaveInPlaceOperation, .autosaveAsOperation].contains(saveOperation)
        if updatesCurrentFile { try synchronization.prepareWrite(to: url) }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if updatesCurrentFile {
            synchronization.received(model.source, at: url)
            cleanSourceHash = DocumentRevision(text: model.source).rawValue
            sourceIsModified = false
            restoredUnsavedCopy = false
            discardRecovery()
        }
    }
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if change == .changeCleared { discardRecovery() }
    }
    override var isDocumentEdited: Bool { sourceIsModified || super.isDocumentEdited }
    // Host timing uses normal NSDocument safe saves. Private recovery remains
    // available while a write is pending or paused by a conflict.
    override func scheduleAutosaving() {
        if !reading { synchronization.sourceChanged() }
    }
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        guard behavior.autosaveEnabled else { completionHandler(nil); return }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
    }
    var committedEditorIsReady: Bool {
        guard let editor = model.activeEditor else { return true }
        guard !editor.hasMarkedText() else { return false }
        if let editor = editor as? EditorTextView { return editor.rawSource.utf8.elementsEqual(editor.string.utf8) }
        return editor.string.utf8.elementsEqual(model.source.utf8)
    }
    func commitEditor() {
        (model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)?.publishCommittedText()
    }
    func acceptedExternalRevision(at url: URL) {
        guard fileURL?.standardizedFileURL == url.standardizedFileURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return }
        // The three-way reconciliation has accepted these disk bytes. Keep
        // AppKit's own save-safety baseline aligned with that same revision.
        fileModificationDate = date
    }
    func replaceSynchronizedSource(_ text: String, clean: Bool) {
        reading = true
        model.source = text
        (model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)?.loadSynchronizedSource(text)
        reading = false
        if clean {
            cleanSourceHash = DocumentRevision(text: text).rawValue
            sourceIsModified = false
            updateChangeCount(.changeCleared)
        } else {
            sourceIsModified = true
            updateChangeCount(.changeDone); persistRecovery(source: text)
        }
    }
    override func save(_ sender: Any?) {
        guard fileURL != nil else { super.save(sender); return }
        Task { await synchronization.saveNow(manual: true) }
    }
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        commitEditor()
        if !behavior.autosaveEnabled, fileURL != nil, sourceIsModified {
            let alert = NSAlert()
            alert.messageText = String(format: L10n.string("要保存对“%@”的更改吗？"), displayName)
            alert.informativeText = L10n.string("如果不保存，这些更改将会丢失。")
            alert.addButton(withTitle: L10n.string("保存"))
            alert.addButton(withTitle: L10n.string("不保存"))
            alert.addButton(withTitle: L10n.string("取消"))
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                Task { @MainActor in
                    var close = response == .alertSecondButtonReturn
                    if response == .alertFirstButtonReturn {
                        await synchronization.saveNow(manual: true)
                        close = !sourceIsModified && synchronization.conflict == nil
                    }
                    if let receiver = delegate as? NSObject, let selector = shouldCloseSelector {
                        typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
                        let callback = unsafeBitCast(receiver.method(for: selector), to: Callback.self)
                        callback(receiver, selector, self, close, contextInfo)
                    }
                }
            }
            if let window = windowControllers.first?.window { alert.beginSheetModal(for: window, completionHandler: respond) }
            else { respond(alert.runModal()) }
            return
        }
        guard fileURL != nil, !synchronization.paused else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo); return
        }
        Task { @MainActor in
            await synchronization.saveNow()
            finishClose(delegate, shouldCloseSelector, contextInfo)
        }
    }
    private func finishClose(_ delegate: Any, _ selector: Selector?, _ context: UnsafeMutableRawPointer?) {
        super.canClose(withDelegate: delegate, shouldClose: selector, contextInfo: context)
    }
    override var fileURL: URL? {
        didSet { MainActor.assumeIsolated {
            model.documentURL = fileURL
            synchronization.relocated(to: fileURL)
            if sourceIsModified { persistRecovery(source: model.source) }
            if let previous = oldValue ?? recoveredFromURL, let fileURL,
               previous.deletingLastPathComponent().standardizedFileURL != fileURL.deletingLastPathComponent().standardizedFileURL {
                model.notice = L10n.string("文档位置已改变。图片和数据仍按原文引用，相关文件需自行放到新位置；R 会话的工作目录保持不变，可在右侧检查或切换。")
            }
            if recoveredDraftID != nil, let fileURL { displayName = fileURL.lastPathComponent; recoveredFromURL = nil }
            model.objectWillChange.send()
        } }
    }
    override func makeWindowControllers() {
        if let fileURL, let viewState = DocumentViewState.load(for: fileURL) {
            model.sourceOnly = viewState.sourceOnly; model.pendingViewState = viewState
        }
        let split = NotebookSplitController(document: self, source: sourceSettings, visual: visual, appearance: appearance)
        let window = NSWindow(contentViewController: split)
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1160, height: 760))
        window.minSize = NSSize(width: 960, height: 640)
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        // Use AppKit’s default toolbar backdrop and scroll-edge treatment.
        window.titlebarAppearsTransparent = false
        let toolbar = NSToolbar(identifier: "Rnotebook.Main")
        toolbar.delegate = split; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = false
        addWindowController(controller)
        split.prepareWindowTitle(on: window)
        model.notebook.window = window; model.exporter.window = window
        NotebookCommandContext.shared.set(model)
        window.center()
        windowPlacement = NotebookWindowPlacement(window: window, split: split, behavior: behavior) { [weak self] in
            NotebookWindowState.documentKey(self?.fileURL)
        }
    }
    func ensureSaved(_ action: @escaping @MainActor () -> Void) {
        commitEditor()
        guard model.activeEditor?.hasMarkedText() != true else { model.notice = L10n.string("请先完成当前输入。"); return }
        if fileURL != nil { action(); return }
        guard initialSaveRequest == nil, let window = windowControllers.first?.window, window.attachedSheet == nil else { return }
        let request = InitialSaveRequest(document: self, action: action)
        initialSaveRequest = request
        save(withDelegate: request, didSave: #selector(InitialSaveRequest.finished(_:didSave:contextInfo:)), contextInfo: nil)
    }
    @MainActor private final class InitialSaveRequest: NSObject {
        weak var document: QMDDocument?
        let action: @MainActor () -> Void
        init(document: QMDDocument, action: @escaping @MainActor () -> Void) {
            self.document = document; self.action = action
        }
        @objc func finished(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
            guard let owner = self.document, owner.initialSaveRequest === self else { return }
            let continuation = action
            owner.initialSaveRequest = nil
            if didSave, owner.fileURL != nil { continuation() }
        }
    }
    override func close() {
        windowPlacement?.save(); windowPlacement = nil
        synchronization.stop()
        if let fileURL { DocumentViewState.capture(model).save(for: fileURL) }
        discardRecovery()
        Task { await model.exporter.shutdown(); await model.notebook.shutdown() }
        super.close()
    }
}
