import AppKit
import SwiftUI

/// A non-interactive background: native buttons keep all hit-testing and hover.
struct RecordToolbarCursorRegion: NSViewRepresentable {
    let model: RecordLayoutModel
    func makeNSView(context: Context) -> RecordToolbarCursorView { RecordToolbarCursorView(model: model) }
    func updateNSView(_ view: RecordToolbarCursorView, context: Context) { view.registerRegion() }
    static func dismantleNSView(_ view: RecordToolbarCursorView, coordinator: ()) { view.unregisterRegion() }
}

/// Native menus can consume SwiftUI's hover events. Observe their bounds with
/// passive AppKit tracking, leaving menu hit-testing and presentation native.
struct RecordToolbarHoverRegion: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> RecordToolbarHoverView { RecordToolbarHoverView() }
    func updateNSView(_ view: RecordToolbarHoverView, context: Context) { view.onChange = onChange }
}

@MainActor final class RecordToolbarHoverView: NSView {
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); self.area = area
    }
    override func mouseEntered(with event: NSEvent) { report(true) }
    override func mouseExited(with event: NSEvent) { report(false) }
    private func report(_ entered: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(entered) }
    }
}

@MainActor final class RecordToolbarCursorView: NSView {
    private weak var model: RecordLayoutModel?
    private var lastRegion: NSRect?
    private var lastWindowNumber: Int?
    init(model: RecordLayoutModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerRegion() }
    override func layout() { super.layout(); registerRegion() }
    override func resetCursorRects() {
        let rect = visibleRect.intersection(bounds)
        if !rect.isEmpty { addCursorRect(rect, cursor: .arrow) }
    }
    func registerRegion() {
        guard let model, window != nil else { return }
        model.visualToolbarCursorView = self
        let region = convert(bounds, to: nil)
        guard region != lastRegion || window?.windowNumber != lastWindowNumber else { return }
        lastRegion = region; lastWindowNumber = window?.windowNumber
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.model?.activeEditor else { return }
            editor.window?.invalidateCursorRects(for: editor)
        }
    }
    func unregisterRegion() {
        guard let model, model.visualToolbarCursorView === self else { return }
        model.visualToolbarCursorView = nil
        DispatchQueue.main.async { [weak model] in
            if let editor = model?.activeEditor { editor.window?.invalidateCursorRects(for: editor) }
        }
    }
}
