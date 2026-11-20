import AppKit
import Combine

struct NotebookWindowState: Codable {
    var frame: NSRect
    var inspectorWidth: CGFloat?

    /// A removed monitor or changed display arrangement must not strand a window.
    static func visibleFrame(_ frame: NSRect, screens: [NSRect], minimum: NSSize) -> NSRect? {
        guard !screens.isEmpty, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return nil }
        let screen = screens.max { a, b in
            let left = a.intersection(frame), right = b.intersection(frame)
            return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
        } ?? screens[0]
        let width = min(screen.width, max(minimum.width, frame.width))
        let height = min(screen.height, max(minimum.height, frame.height))
        return NSRect(x: min(max(screen.minX, frame.minX), screen.maxX - width),
                      y: min(max(screen.minY, frame.minY), screen.maxY - height), width: width, height: height)
    }
    static func documentKey(_ url: URL?) -> String {
        url.map { "window.document." + DocumentRevision(text: $0.standardizedFileURL.path).rawValue } ?? "window.lastDocument"
    }
    static func load(key: String, defaults: UserDefaults) -> Self? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    func save(key: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

@MainActor final class NotebookWindowPlacement {
    private weak var window: NSWindow?
    private weak var split: NotebookSplitController?
    private let behavior: DocumentBehaviorSettings
    private let key: () -> String
    private let remembersSize: Bool
    private var observations: [AnyCancellable] = []
    private var restoring = false
    private var fullscreenTransition = false
    private var initialState: NotebookWindowState?
    private var firstPresentation = false

    init(window: NSWindow, split: NotebookSplitController? = nil, behavior: DocumentBehaviorSettings,
         remembersSize: Bool = true, key: @escaping () -> String) {
        self.window = window; self.split = split; self.behavior = behavior; self.key = key; self.remembersSize = remembersSize
        restore()
        if initialState == nil, behavior.rememberWindows {
            initialState = NotebookWindowState(frame: window.frame, inspectorWidth: split?.inspectorWidth)
        }
        observations.append(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window).sink { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.firstPresentation else { return }
                // The window server can apply initial placement at first ordering,
                // after AppKit has already accepted the saved pre-display frame.
                if let initial = self.initialState, self.behavior.rememberWindows {
                    self.apply(initial)
                    self.window?.contentView?.superview?.layoutSubtreeIfNeeded()
                    if let width = initial.inspectorWidth { self.split?.setInspectorWidth(width) }
                }
                self.firstPresentation = true; self.initialState = nil
                self.save()
            }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification] {
            observations.append(NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observations.append(NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.fullscreenTransition = true }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observations.append(NotificationCenter.default.publisher(for: name, object: window).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.fullscreenTransition = false; self?.save() }
            })
        }
        if let split {
            observations.append(NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.save() } })
        }
    }
    func restore() {
        guard behavior.rememberWindows, let window else { return }
        let saved = NotebookWindowState.load(key: key(), defaults: behavior.defaults)
            ?? (split == nil ? nil : NotebookWindowState.load(key: "window.lastDocument", defaults: behavior.defaults))
        guard let saved else { return }
        initialState = saved
        apply(saved)
    }
    private func apply(_ saved: NotebookWindowState) {
        guard let window else { return }
        restoring = true
        defer { restoring = false }
        var desired = saved.frame
        if !remembersSize { desired = NSRect(x: desired.minX, y: desired.maxY - window.frame.height, width: window.frame.width, height: window.frame.height) }
        if let frame = NotebookWindowState.visibleFrame(desired, screens: NSScreen.screens.map(\.visibleFrame), minimum: window.minSize) {
            window.setFrame(frame, display: false)
        }
        if let width = saved.inspectorWidth, width.isFinite { split?.setInspectorWidth(width) }
    }
    func save() {
        guard !restoring, !fullscreenTransition, behavior.rememberWindows, let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        guard firstPresentation else { return }
        // Full-screen transition notifications can describe temporary display-sized frames.
        guard !window.inLiveResize else { return }
        let saved = NotebookWindowState(frame: window.frame, inspectorWidth: split?.inspectorWidth)
        saved.save(key: key(), defaults: behavior.defaults)
        if split != nil { saved.save(key: "window.lastDocument", defaults: behavior.defaults) }
    }
    func reset() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        restoring = true
        window.setContentSize(NSSize(width: 1160, height: 760)); window.center()
        if let frame = NotebookWindowState.visibleFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame), minimum: window.minSize) {
            window.setFrame(frame, display: true)
        }
        split?.setInspectorWidth(280)
        restoring = false; save()
    }
}
