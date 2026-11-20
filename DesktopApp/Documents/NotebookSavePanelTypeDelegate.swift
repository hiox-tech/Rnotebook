import AppKit
import UniformTypeIdentifiers

/// Modern NSSavePanel obtains each format label from its own delegate. Keep
/// AppKit's existing validation/selection delegate and forward other callbacks.
final class NotebookSavePanelTypeDelegate: NSObject, NSOpenSavePanelDelegate {
    private weak var original: (any NSOpenSavePanelDelegate)?
    init(original: (any NSOpenSavePanelDelegate)?) { self.original = original; super.init() }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
    @available(macOS 15.0, *) @MainActor
    func panel(_ sender: Any, displayNameFor type: UTType) -> String? {
        NotebookDocumentType.displayName(for: type.identifier, extension: type.preferredFilenameExtension)
            ?? original?.panel?(sender, displayNameFor: type)
    }
}
