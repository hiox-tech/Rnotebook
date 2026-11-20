import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main @MainActor enum RnotebookApp {
    static var delegate: RnotebookDelegate?
    private static let documents = QMDDocumentController()
    static func main() {
        let app = NSApplication.shared
        // Documents may open in separate windows, never in native tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        app.setActivationPolicy(.regular)
        _ = documents
        let value = RnotebookDelegate(); delegate = value; app.delegate = value
        _ = NotebookPreferences.language
        app.mainMenu = makeMenu()
        app.run()
    }

}

@MainActor final class RnotebookDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) lazy var helpCenter = NotebookHelpCenter()
    private(set) lazy var aboutController = NotebookAboutController()
    @objc func showAbout(_ sender: Any?) { aboutController.show() }
    private var settingsWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var receivedOpenRequest = false
    private var languageChanges: AnyCancellable?
    private var cacheMaintenance: Task<Void, Never>?
    override init() {
        super.init()
        languageChanges = NotificationCenter.default.publisher(for: .notebookLanguageChanged).sink { _ in
            Task { @MainActor in NSApp.mainMenu = RnotebookApp.makeMenu() }
        }
    }
    @objc func completeRCode(_ sender: Any?) { NotebookCommandContext.shared.target?.requestRCompletion?() }
    @objc func formatRBlock(_ sender: Any?) { NotebookCommandContext.shared.target?.formatCurrentRBlock() }
    @objc func runCurrent(_ sender: Any?) { NotebookCommandContext.shared.target?.runCurrentNotebookCell() }
    @objc func runAll(_ sender: Any?) { NotebookCommandContext.shared.target?.runAllNotebookCells() }
    @objc func restartAndRunAll(_ sender: Any?) { NotebookCommandContext.shared.target?.requestRestartAndRunAll() }
    @objc func runAbove(_ sender: Any?) { NotebookCommandContext.shared.target?.runNotebookCellsAbove() }
    @objc func runBelow(_ sender: Any?) { NotebookCommandContext.shared.target?.runNotebookCellsBelow() }
    @objc func runSelection(_ sender: Any?) { NotebookCommandContext.shared.target?.runNotebookSelection() }
    @objc func interruptR(_ sender: Any?) { NotebookCommandContext.shared.target?.notebook.interrupt() }
    @objc func startR(_ sender: Any?) { NotebookCommandContext.shared.target?.notebook.start() }
    @objc func stopR(_ sender: Any?) { NotebookCommandContext.shared.target?.requestStopR() }
    @objc func render(_ sender: Any?) {
        guard let model = NotebookCommandContext.shared.target else { return }
        if let document = model.document {
            document.ensureSaved { _ = model.exporter.present(window: model.notebook.window) }
        } else { _ = model.exporter.present(window: model.notebook.window) }
    }
    @objc func restartR(_ sender: Any?) {
        NotebookCommandContext.shared.target?.requestRestartR()
    }
    @objc func saveR(_ sender: Any?) { NotebookCommandContext.shared.target?.requestWorkspaceSave() }
    @objc func recoverDocuments(_ sender: Any?) { showRecovery(onlyIfNeeded: false) }
    @discardableResult private func showRecovery(onlyIfNeeded: Bool) -> Bool {
        do {
            let store = DocumentRecoveryStore.shared
            let drafts = try store.drafts()
            guard !drafts.isEmpty else {
                recoveryWindow?.close()
                if !onlyIfNeeded {
                    let alert = NSAlert(); alert.messageText = L10n.string("没有待恢复的未保存文档"); alert.runModal()
                }
                return false
            }
            recoveryWindow?.close()
            let view = DocumentRecoveryView(drafts: drafts, restore: { [weak self] selected in
                guard let self else { return }
                recoveryWindow?.close()
                restoreDrafts(selected)
            }, discard: { [weak self] selected in
                for draft in selected { store.remove(id: draft.id) }
                if self?.showRecovery(onlyIfNeeded: true) == false { self?.showStartWindow() }
            }, later: { [weak self] in
                self?.recoveryWindow?.close(); self?.showStartWindow()
            })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L10n.string("恢复未保存文档"); window.isReleasedWhenClosed = false
            window.styleMask.remove(.resizable); window.center(); window.makeKeyAndOrderFront(nil)
            recoveryWindow = window
            return true
        } catch { NSApp.presentError(error); return false }
    }
    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let document = controller.currentDocument as? QMDDocument
        let settings = NotebookSettingsController(
            source: document?.sourceSettings ?? NotebookPreferences.source,
            visual: document?.visual ?? NotebookPreferences.visual,
            appearance: document?.appearance ?? NotebookPreferences.appearance,
            behavior: document?.behavior ?? NotebookPreferences.documents)
        let window = settings.makeWindow()
        window.makeKeyAndOrderFront(nil); settingsWindow = window
    }
    @objc func showDocumentSettings(_ sender: Any?) {
        showSettings(sender)
        if let settings = settingsWindow?.contentViewController as? NotebookSettingsController,
           let index = NotebookSettingsPane.allCases.firstIndex(of: .documents) { settings.selectedTabViewItemIndex = index }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "recent-documents" else { return }
        menu.removeAllItems()
        let names = Dictionary(grouping: controller.recentDocumentURLs, by: \.lastPathComponent)
        for url in controller.recentDocumentURLs {
            let title = (names[url.lastPathComponent]?.count ?? 0) > 1
                ? url.lastPathComponent + " — " + url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url; item.target = self; item.toolTip = url.path; menu.addItem(item)
        }
        if !controller.recentDocumentURLs.isEmpty {
            menu.addItem(.separator())
            let clear = menu.addItem(withTitle: L10n.string("清除最近文档"), action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
            clear.target = controller
        } else {
            let empty = NSMenuItem(title: L10n.string("无最近文档"), action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
    }
    private let controller = NSDocumentController.shared
    func showStartWindow() {
        guard controller.documents.isEmpty else { return }
        openExistingDocument(nil)
    }
    @objc func openExistingDocument(_ sender: Any?) {
        controller.openDocument(sender)
    }
    private func restoreDrafts(_ drafts: [DocumentRecoveryStore.Draft]) {
        (controller as? QMDDocumentController)?.dismissOpenPanel()
        for draft in drafts {
            do {
                guard let document = try controller.openUntitledDocumentAndDisplay(false) as? QMDDocument else {
                    throw CocoaError(.fileReadUnknown)
                }
                document.restore(draft)
                document.makeWindowControllers(); document.showWindows()
            } catch { NSApp.presentError(error) }
        }
    }
    @objc func openRecent(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        controller.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening an existing file is asynchronous; an empty document list at
        // launch does not mean the user requested a new Untitled document.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            cacheMaintenance = Task {
                while !Task.isCancelled {
                    await Task.detached(priority: .background) { _ = try? NotebookCacheStore().sweep() }.value
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                }
            }
            let hasRecovery = showRecovery(onlyIfNeeded: true)
            if !receivedOpenRequest && controller.documents.isEmpty && !hasRecovery { showStartWindow() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if controller.documents.isEmpty { showStartWindow() }
            else { controller.documents.forEach { $0.showWindows() } }
        }
        return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        receivedOpenRequest = true
        Task { @MainActor in
            var succeeded = true
            for path in filenames {
                do { _ = try await controller.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) }
                catch { succeeded = false; sender.presentError(error); showStartWindow() }
            }
            sender.reply(toOpenOrPrint: succeeded ? .success : .failure)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // NSDocument's normal close review handles unsaved text before termination.
        controller.reviewUnsavedDocuments(withAlertTitle: L10n.string("退出 Rnotebook"), cancellable: true, delegate: self, didReviewAllSelector: #selector(reviewed(_:didReviewAll:contextInfo:)), contextInfo: nil)
        return .terminateLater
    }
    @objc private func reviewed(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didReviewAll else { NSApp.reply(toApplicationShouldTerminate: false); return }
        for document in controller.documents.compactMap({ $0 as? QMDDocument }) { document.discardRecovery() }
        Task { await EnvironmentDependencies.shared.shutdown(); await QuartoExports.shutdownAll(); await NotebookSessions.shutdownAll(); NSApp.reply(toApplicationShouldTerminate: true) }
    }
}

/// AppKit owns the browser, document creation, file type selection and errors.
/// The only addition to its open panel is a standard native New button, so a
/// user can start writing without cancelling the browser or naming a file.
@MainActor final class QMDDocumentController: NSDocumentController {
    override func displayName(forType typeName: String) -> String? {
        NotebookDocumentType.displayName(for: typeName) ?? super.displayName(forType: typeName)
    }
    override func typeForContents(of url: URL) throws -> String {
        if ["qmd", "rmd"].contains(url.pathExtension.lowercased()) {
            return NotebookDocumentType.identifier(for: url)
        }
        return try super.typeForContents(of: url)
    }
    private(set) var activeOpenPanel: NSOpenPanel?
    override func openDocument(_ sender: Any?) {
        if let activeOpenPanel { activeOpenPanel.makeKeyAndOrderFront(sender) }
        else { super.openDocument(sender) }
    }
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void) {
        activeOpenPanel = openPanel
        openPanel.allowedContentTypes = (inTypes ?? []).compactMap { UTType($0) ?? UTType(filenameExtension: $0) }
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.accessoryView = nil
        // AppKit's own New Document action occupies the bottom-left action
        // slot without introducing an empty, collapsible Options section.
        // Its visibility hook is not public; keep a standard accessory action
        // as a compatibility fallback on systems that don't expose it.
        let showNew = NSSelectorFromString("_setShowNewDocumentButton:")
        if openPanel.responds(to: showNew) {
            typealias SetNewVisible = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(openPanel.method(for: showNew), to: SetNewVisible.self)(openPanel, showNew, true)
        } else {
            let create = NSButton(title: L10n.string("新建文档…"), target: self, action: #selector(newDocument(_:)))
            create.bezelStyle = .rounded
            create.setAccessibilityIdentifier("qmd-new-document")
            create.sizeToFit()
            openPanel.accessoryView = create
            openPanel.isAccessoryViewDisclosed = true
        }
        // The default presenter clears the native New flag. Present the same
        // controller-provided panel directly and return its normal response.
        openPanel.begin { [weak self] result in
            self?.activeOpenPanel = nil
            completionHandler(result.rawValue)
        }
    }
    func dismissOpenPanel() { activeOpenPanel?.cancel(nil) }
    override func newDocument(_ sender: Any?) {
        dismissOpenPanel()
        super.newDocument(sender)
    }
}
