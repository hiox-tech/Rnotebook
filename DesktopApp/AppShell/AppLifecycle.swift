import AppKit

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(configureToolbar(_:)), name: name, object: nil)
        }
        for window in NSApp.windows { configureToolbar(in: window) }
    }

    @objc private func configureToolbar(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureToolbar(in: window)
    }

    private func configureToolbar(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        if toolbar.allowsUserCustomization { toolbar.allowsUserCustomization = false }
        if #available(macOS 15.0, *), toolbar.allowsDisplayModeCustomization {
            toolbar.allowsDisplayModeCustomization = false
        }
        if toolbar.displayMode != .iconOnly { toolbar.displayMode = .iconOnly }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard NotebookSessions.hasStarted || QuartoExports.hasRunning else { return .terminateNow }
        Task { @MainActor in
            await QuartoExports.shutdownAll()
            await NotebookSessions.shutdownAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
