import AppKit
import SwiftUI

extension RecordSyntaxPreferences {
    @MainActor init(_ settings: SourceEditorSettings) {
        enabled = settings.syntaxEnabled; palette = settings.syntaxPalette
        italicComments = settings.syntaxItalicComments; boldKeywords = settings.syntaxBoldKeywords
    }
}

struct RCompletionPreferences: Equatable {
    let automatic: Bool
    let delay: Int
    let minimum: Int
    let limit: Int
    let signature: Bool
    let parameters: Bool
    let runtime: Bool
    let acceptReturn: Bool
    @MainActor init(_ settings: SourceEditorSettings) {
        automatic = settings.completionAutomatic
        delay = min(1000, max(0, settings.completionDelay))
        minimum = min(3, max(1, settings.completionMinimum))
        limit = min(80, max(1, settings.completionLimit))
        signature = settings.completionSignature; parameters = settings.completionParameters
        runtime = settings.completionRuntime; acceptReturn = settings.completionReturn
    }
    func shouldTrigger(manual: Bool, prefix: String, preceding: String) -> Bool {
        manual || automatic && (prefix.count >= minimum || ["$", "@", ":", "(", ","].contains(preceding))
    }
}

struct RecordSyntaxPreview: NSViewRepresentable {
    let preferences: RecordSyntaxPreferences
    func makeNSView(context: Context) -> SyntaxPreviewSurface { SyntaxPreviewSurface() }
    func updateNSView(_ view: SyntaxPreviewSurface, context: Context) {
        view.preferences = preferences; view.refresh()
    }
}

/// Shared settings preview surface: the rounded inset panel used by both the
/// syntax sample and the font samples, so their visual weight stays identical.
@MainActor class SettingsPreviewSurface: NSView {
    let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        addSubview(label)
        refreshBackground()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 12, dy: 10) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshBackground() }
    func refreshBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }
    }
}

@MainActor final class SyntaxPreviewSurface: SettingsPreviewSurface {
    var preferences = RecordSyntaxPreferences()
    private let lexer = try? RecordRTokenSource(bundle: Bundle(for: RecordRTokenSource.self))
    private let sample = "# R code\nif (TRUE) {\n  mean(c(12, 18, 24))\n}"
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    func refresh() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var base = preferences.attributes("plain", dark: dark, font: font)
        base[.font] = font
        let value = NSMutableAttributedString(string: sample, attributes: base)
        for token in lexer?.tokens(sample) ?? [] {
            value.addAttributes(preferences.attributes(token.scope, dark: dark, font: font), range: token.range)
        }
        label.attributedStringValue = value
        refreshBackground()
    }
}

/// Font samples use the same rounded panel/corners/inset as the syntax
/// preview; only the sample text and its actual fonts differ.
struct RecordFontPreview: NSViewRepresentable {
    let lines: [(String, NSFont)]
    func makeNSView(context: Context) -> SettingsPreviewSurface { SettingsPreviewSurface() }
    func updateNSView(_ view: SettingsPreviewSurface, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let text = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: line.1])) }
            text.append(NSAttributedString(string: line.0, attributes: [
                .font: line.1,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        view.label.attributedStringValue = text
        view.refreshBackground()
    }
}
