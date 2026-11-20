import AppKit
import Combine
import Foundation

@MainActor final class VisualEditorSettings: ObservableObject {
    static var bodyFonts: [String] { NotebookFontCatalog.families }
    static var codeFonts: [String] { NotebookFontCatalog.families }
    let defaults: UserDefaults
    @Published var bodyFont: String { didSet { defaults.set(bodyFont, forKey: "visualEditor.bodyFont") } }
    @Published var bodySize: Double { didSet { defaults.set(bodySize, forKey: "visualEditor.bodySize") } }
    @Published var codeFont: String { didSet { defaults.set(codeFont, forKey: "visualEditor.codeFont") } }
    @Published var codeSize: Double { didSet { defaults.set(codeSize, forKey: "visualEditor.codeSize") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let body = defaults.string(forKey: "visualEditor.bodyFont") ?? "system"
        bodyFont = NotebookFontCatalog.isValid(body) ? body : "system"
        let code = defaults.string(forKey: "visualEditor.codeFont") ?? "system"
        codeFont = NotebookFontCatalog.isValid(code) ? code : "system"
        let size = defaults.double(forKey: "visualEditor.bodySize")
        bodySize = size.isFinite && (10...28).contains(size) ? size : 12
        let monoSize = defaults.double(forKey: "visualEditor.codeSize")
        codeSize = monoSize.isFinite && (10...24).contains(monoSize) ? monoSize : 12
    }
}

/// Independent of notebook typography and the legacy document editor settings.
@MainActor final class SourceEditorSettings: ObservableObject {
    static var fonts: [String] { NotebookFontCatalog.families }
    let defaults: UserDefaults
    @Published var fontName: String { didSet { defaults.set(fontName, forKey: "sourceEditor.font") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "sourceEditor.size") } }
    @Published var completionEnabled: Bool { didSet { defaults.set(completionEnabled, forKey: "sourceEditor.completionEnabled") } }
    @Published var completionAutomatic: Bool { didSet { defaults.set(completionAutomatic, forKey: "completion.automatic") } }
    @Published var completionDelay: Int { didSet { defaults.set(completionDelay, forKey: "completion.delay") } }
    @Published var completionMinimum: Int { didSet { defaults.set(completionMinimum, forKey: "completion.minimum") } }
    @Published var completionLimit: Int { didSet { defaults.set(completionLimit, forKey: "completion.limit") } }
    @Published var completionSignature: Bool { didSet { defaults.set(completionSignature, forKey: "completion.signature") } }
    @Published var completionParameters: Bool { didSet { defaults.set(completionParameters, forKey: "completion.parameters") } }
    @Published var completionRuntime: Bool { didSet { defaults.set(completionRuntime, forKey: "completion.runtime") } }
    @Published var completionReturn: Bool { didSet { defaults.set(completionReturn, forKey: "completion.return") } }
    @Published var syntaxEnabled: Bool { didSet { defaults.set(syntaxEnabled, forKey: "syntax.enabled") } }
    @Published var syntaxPalette: String { didSet { defaults.set(syntaxPalette, forKey: "syntax.palette") } }
    @Published var syntaxItalicComments: Bool { didSet { defaults.set(syntaxItalicComments, forKey: "syntax.italicComments") } }
    @Published var syntaxBoldKeywords: Bool { didSet { defaults.set(syntaxBoldKeywords, forKey: "syntax.boldKeywords") } }
    @Published var formatMode: String { didSet { defaults.set(formatMode, forKey: "rFormat.mode") } }
    @Published var formatLineWidth: Int { didSet { defaults.set(formatLineWidth, forKey: "rFormat.lineWidth") } }
    @Published var formatIndentWidth: Int { didSet { defaults.set(formatIndentWidth, forKey: "rFormat.indentWidth") } }
    @Published var formatPersistentBreaks: Bool { didSet { defaults.set(formatPersistentBreaks, forKey: "rFormat.persistentBreaks") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let formatting = RFormatPreferences(defaults: defaults)
        formatMode = formatting.custom ? "custom" : "document"
        formatLineWidth = formatting.lineWidth
        formatIndentWidth = formatting.indentWidth
        formatPersistentBreaks = formatting.persistentBreaks
        completionEnabled = defaults.object(forKey: "sourceEditor.completionEnabled") == nil ? true : defaults.bool(forKey: "sourceEditor.completionEnabled")
        func enabled(_ key: String) -> Bool { defaults.object(forKey: key) == nil || defaults.bool(forKey: key) }
        completionAutomatic = enabled("completion.automatic")
        let delay = defaults.integer(forKey: "completion.delay")
        completionDelay = [100, 220, 400, 600].contains(delay) ? delay : 220
        let minimum = defaults.integer(forKey: "completion.minimum")
        completionMinimum = (1...3).contains(minimum) ? minimum : 1
        let limit = defaults.integer(forKey: "completion.limit")
        completionLimit = [20, 40, 80].contains(limit) ? limit : 80
        completionSignature = enabled("completion.signature")
        completionParameters = enabled("completion.parameters")
        completionRuntime = enabled("completion.runtime")
        completionReturn = enabled("completion.return")
        syntaxEnabled = enabled("syntax.enabled")
        let palette = defaults.string(forKey: "syntax.palette") ?? "default"
        syntaxPalette = RecordSyntaxPreferences.palettes.contains(palette) ? palette : "default"
        syntaxItalicComments = defaults.bool(forKey: "syntax.italicComments")
        syntaxBoldKeywords = defaults.bool(forKey: "syntax.boldKeywords")
        let name = defaults.string(forKey: "sourceEditor.font") ?? "system"
        fontName = NotebookFontCatalog.isValid(name) ? name : "system"
        let size = defaults.double(forKey: "sourceEditor.size")
        fontSize = (10...32).contains(size) ? size : 12
    }
}


/// Font families are read from the current Mac; persisted PostScript names remain valid.
@MainActor enum NotebookFontCatalog {
    static let families: [String] = ["system", "SF Mono"] + NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") && $0 != "SF Mono" && $0 != "system" }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    static func options(including selected: String) -> [String] {
        families.contains(selected) ? families : families + [selected]
    }
    static func isValid(_ name: String) -> Bool {
        families.contains(name) || NSFont(name: name, size: 12) != nil
    }
    static func font(_ name: String, size: Double, code: Bool) -> NSFont {
        if name == "system" { return code ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size) }
        if name == "SF Mono" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }
}
