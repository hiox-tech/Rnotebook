import AppKit

@MainActor final class RecordResultImageView: NSImageView {
    var originalPNG: Data?
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyDown
        imageAlignment = .alignCenter
        isEditable = false
        allowsCutCopyPaste = true
        setAccessibilityLabel(L10n.string("R 输出图像"))
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    @discardableResult func copyImage(to pasteboard: NSPasteboard) -> Bool {
        guard let image, let tiff = image.tiffRepresentation else { return false }
        let png: Data?
        if let original = originalPNG { png = original }
        else if let bitmap = NSBitmapImageRep(data: tiff) {
            bitmap.size = image.size
            png = bitmap.representation(using: .png, properties: [:])
        } else { png = nil }
        guard let png else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png) && pasteboard.setData(tiff, forType: .tiff)
    }
    @objc func copy(_ sender: Any?) { _ = copyImage(to: .general) }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = menu.addItem(withTitle: L10n.string("拷贝图形"), action: #selector(copy(_:)), keyEquivalent: "c")
        item.target = self; item.isEnabled = image != nil
        return menu
    }
}
