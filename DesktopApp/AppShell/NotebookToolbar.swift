import AppKit
import Combine
import SwiftUI

@MainActor final class NotebookSplitController: NSSplitViewController, NSToolbarDelegate, NSMenuItemValidation {
    // AppKit may perform a final layout after the owning document closes.
    private weak var document: QMDDocument?
    private let model: RecordLayoutModel
    private var changes: AnyCancellable?
    private var languageChanges: AnyCancellable?

    init(document: QMDDocument, source: SourceEditorSettings, visual: VisualEditorSettings, appearance: AppearanceSettings) {
        self.document = document; model = document.model
        super.init(nibName: nil, bundle: nil)
        let content = NSHostingController(rootView:
            RecordEditorLayoutPreview(model: model)
                .environmentObject(source).environmentObject(visual).appAppearance(appearance))
        content.safeAreaRegions = []
        let center = NSSplitViewItem(viewController: content); center.minimumThickness = 440
        let inspector = NSViewController()
        let material = NSVisualEffectView()
        material.material = .sidebar; material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        inspector.view = material
        let inspectorContent = NSHostingController(rootView: InspectorHost(model: model).appAppearance(appearance))
        inspector.addChild(inspectorContent)
        inspectorContent.view.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(inspectorContent.view)
        NSLayoutConstraint.activate([
            inspectorContent.view.leadingAnchor.constraint(equalTo: material.safeAreaLayoutGuide.leadingAnchor),
            inspectorContent.view.trailingAnchor.constraint(equalTo: material.safeAreaLayoutGuide.trailingAnchor),
            inspectorContent.view.topAnchor.constraint(equalTo: material.safeAreaLayoutGuide.topAnchor),
            inspectorContent.view.bottomAnchor.constraint(equalTo: material.safeAreaLayoutGuide.bottomAnchor)
        ])
        let right = NSSplitViewItem(inspectorWithViewController: inspector)
        right.canCollapse = false; right.minimumThickness = 260; right.maximumThickness = 340
        addSplitViewItem(center); addSplitViewItem(right)
        changes = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refreshToolbar() }
        }
        languageChanges = NotificationCenter.default.publisher(for: .notebookLanguageChanged).sink { [weak self] _ in
            Task { @MainActor in
                guard let self, let toolbar = self.view.window?.toolbar else { return }
                let identifiers = toolbar.items.map(\.itemIdentifier)
                for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
                for (index, identifier) in identifiers.enumerated() { toolbar.insertItem(withItemIdentifier: identifier, at: index) }
                self.refreshToolbar()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var editorHost: RecordNativeEditorHost? { model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost }
    private var canRun: Bool { !model.notebook.isBusy && !model.notebook.needsRestart && !model.notebook.hasPendingRSelection }
    var inspectorWidth: CGFloat { splitViewItems.last?.viewController.view.frame.width ?? 280 }
    func setInspectorWidth(_ width: CGFloat) {
        view.layoutSubtreeIfNeeded()
        splitView.setPosition(max(440, splitView.bounds.width - splitView.dividerThickness - min(340, max(260, width))), ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
    }
    func refreshToolbar() {
        if let window = view.window { updateDocumentTitle(on: window) }
        for item in view.window?.toolbar?.items ?? [] {
            switch item.itemIdentifier.rawValue {
            case "mode": (item.view as? NSSegmentedControl)?.selectedSegment = model.sourceOnly ? 0 : 1
            case "history":
                let group = item as? NSToolbarItemGroup
                group?.subitems.first?.isEnabled = editorHost?.editor.canUndoSource == true && model.activeEditor?.hasMarkedText() != true
                group?.subitems.last?.isEnabled = editorHost?.editor.canRedoSource == true && model.activeEditor?.hasMarkedText() != true
            case "run":
                item.image = NSImage(systemSymbolName: model.notebook.isBusy ? "stop.fill" : "play.fill",
                    accessibilityDescription: model.notebook.isBusy ? L10n.string("停止运行") : L10n.string("运行全部"))
                item.label = model.notebook.isBusy ? L10n.string("停止运行") : L10n.string("运行全部")
                item.toolTip = model.notebook.isBusy ? L10n.string("停止 R") : L10n.string("批量运行遵守 eval；单块和选区为手动执行。")
                item.isEnabled = model.notebook.isBusy || canRun
            case "render": item.isEnabled = !model.exporter.isRunning
            case "find": item.isEnabled = model.activeEditor != nil
            case "r-session":
                let group = item as? NSToolbarItemGroup
                let notebook = model.notebook
                let starts = notebook.state == .notStarted && !notebook.isStopping
                let title = notebook.isStopping ? L10n.string("正在停止 R…") : notebook.state == .starting ? L10n.string("正在启动 R…") : starts ? L10n.string("启动 R") : L10n.string("停止 R")
                group?.subitems.first?.image = NSImage(systemSymbolName: "power", accessibilityDescription: title)
                group?.subitems.first?.label = title
                group?.subitems.first?.toolTip = title
                group?.subitems.first?.isEnabled = notebook.canStart || notebook.canStop
                group?.subitems.last?.isEnabled = !notebook.isBusy && notebook.state != .notStarted
            case "save-r": item.isEnabled = model.notebook.canSaveWorkspace
            default: break
            }
        }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window else { return }
        let layout = view.convert(window.contentLayoutRect, from: nil)
        let inset = max(0, view.bounds.maxY - layout.maxY)
        if abs(model.windowTopInset - inset) > 0.5 { model.windowTopInset = inset }
        refreshToolbar()
    }
    func prepareWindowTitle(on window: NSWindow) {
        updateDocumentTitle(on: window)
    }
    private func updateDocumentTitle(on window: NSWindow) {
        guard let document else { return }
        if window.representedURL != document.fileURL { window.representedURL = document.fileURL }
        if window.titleVisibility != .visible { window.titleVisibility = .visible }
        window.standardWindowButton(.documentVersionsButton)?.setAccessibilityIdentifier("notebook-document-title")
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("find"), .init("mode"), .init("history"), .init("run"), .init("render"),
         .inspectorTrackingSeparator, .flexibleSpace, .init("r-session"), .init("save-r")]
    }
    private func button(_ id: String, _ title: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init(id))
        item.label = title; item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self; item.action = action; item.autovalidates = false
        return item
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .inspectorTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0)
        }
        switch id.rawValue {
        case "find": return button("find", L10n.string("查找…"), "magnifyingglass", #selector(find(_:)))
        case "mode":
            let item = NSToolbarItem(itemIdentifier: id)
            let control = NSSegmentedControl(labels: ["Code", "Visual"], trackingMode: .selectOne, target: self, action: #selector(mode(_:)))
            control.selectedSegment = model.sourceOnly ? 0 : 1
            control.setAccessibilityIdentifier("notebook-view-mode")
            item.view = control; item.label = L10n.string("编辑视图"); item.visibilityPriority = .high
            return item
        case "history":
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.label = L10n.string("撤销与重做")
            group.isBordered = true
            group.subitems = [button("undo", L10n.string("撤销"), "arrow.uturn.backward", #selector(undo(_:))),
                              button("redo", L10n.string("重做"), "arrow.uturn.forward", #selector(redo(_:)))]
            group.subitems.forEach { $0.isEnabled = false }
            group.controlRepresentation = .expanded
            return group
        case "run":
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.isBordered = true
            item.label = L10n.string("运行全部"); item.toolTip = L10n.string("运行全部代码块")
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L10n.string("运行全部"))
            item.target = self; item.action = #selector(run(_:)); item.showsIndicator = true; item.autovalidates = false
            let menu = NSMenu()
            for (title, action) in [(L10n.string("运行当前块"), #selector(runCurrent(_:))), (L10n.string("运行选中代码"), #selector(runSelection(_:))),
                                    (L10n.string("运行以上"), #selector(runAbove(_:))), (L10n.string("运行以下"), #selector(runBelow(_:)))] {
                let option = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                option.target = self
            }
            item.menu = menu; item.visibilityPriority = .high
            return item
        case "render": return button("render", L10n.string("Quarto 渲染导出"), "doc.richtext", #selector(render(_:)))
        case "r-session":
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.label = L10n.string("R 会话")
            group.isBordered = true
            group.subitems = [button("r-power", L10n.string("启动 R"), "power", #selector(toggleR(_:))),
                              button("restart-r", L10n.string("重启 R"), "arrow.clockwise", #selector(restartR(_:)))]
            group.controlRepresentation = .expanded
            return group
        case "save-r": return button("save-r", L10n.string("保存 R 工作区"), "externaldrive.badge.plus", #selector(saveR(_:)))
        default: return nil
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { canRun }
    @objc private func mode(_ sender: NSSegmentedControl) { model.sourceOnly = sender.selectedSegment == 0 }
    @objc private func find(_ sender: Any?) { model.findInDocument() }
    @objc private func undo(_ sender: Any?) { editorHost?.undoSource(sender); refreshToolbar() }
    @objc private func redo(_ sender: Any?) { editorHost?.redoSource(sender); refreshToolbar() }
    @objc private func run(_ sender: Any?) {
        if model.notebook.isBusy { model.notebook.interrupt() }
        else { model.runAllNotebookCells() }
    }
    @objc private func runCurrent(_ sender: Any?) { model.runCurrentNotebookCell() }
    @objc private func runSelection(_ sender: Any?) { model.runNotebookSelection() }
    @objc private func runAbove(_ sender: Any?) { model.runNotebookCellsAbove() }
    @objc private func runBelow(_ sender: Any?) { model.runNotebookCellsBelow() }
    @objc private func render(_ sender: Any?) { document?.ensureSaved { [model] in _ = model.exporter.present(window: model.notebook.window) } }
    @objc private func toggleR(_ sender: Any?) { model.toggleRSession() }
    @objc private func restartR(_ sender: Any?) { model.requestRestartR() }
    @objc private func saveR(_ sender: Any?) { model.requestWorkspaceSave() }
}

private struct InspectorHost: View {
    @ObservedObject var model: RecordLayoutModel
    var body: some View {
        RecordStatusLayoutPreview(model: model)
            .sheet(isPresented: $model.showingExport) { RecordExportSheet(model: model, exporter: model.exporter) }
    }
}
