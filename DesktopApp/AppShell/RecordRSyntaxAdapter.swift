import AppKit
import EdmundCore

@MainActor final class RecordRSyntaxAdapter: NSObject {
    static let scopeKey = NSAttributedString.Key("KailRecordPreview.rScope")
    private static let styleKey = NSAttributedString.Key("Rnotebook.syntaxStyle")
    private static let fontTraitKey = NSAttributedString.Key("Rnotebook.syntaxFontTrait")
    private static let blankSpacingKey = NSAttributedString.Key("Rnotebook.codeBlankSpacing")
    var preferences = RecordSyntaxPreferences() {
        didSet { if oldValue != preferences { sourcePresentation = nil } }
    }
    let editor: EditorTextView
    let lexer: RecordRTokenSource
    var applying = false
    var applyCount = 0
    var failures = 0
    var onApplyTiming: ((Double) -> Void)?
    private let fences = RecordFencePresentationCache()
    private struct CachedTokens {
        var tokens: [RecordRTokenSource.Token]
        var cost: Int
        var access: UInt64
    }
    private var tokenCache: [Data: CachedTokens] = [:]
    private var tokenCacheCost = 0
    private var tokenAccess: UInt64 = 0
    private var sourcePresentation: NSAttributedString?
    private var presentationSource: Data?
    private var presentationIsDark = false
    private var presentationAttributesKey = ""
    private var markdownSource: Data?
    private var markdownTokens: [RecordRTokenSource.Token] = []
    private var attributesKey = ""
    private var attributePalette: [String: [NSAttributedString.Key: Any]] = [:]
    private var attributeDark = false
    private var attributeFont: NSFont?
    init(editor: EditorTextView, lexer: RecordRTokenSource) {
        self.editor = editor; self.lexer = lexer
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(prepareSourceColors),
            name: NSTextStorage.willProcessEditingNotification, object: editor.textStorage)
    }
    @objc private func prepareSourceColors(_ notification: Notification) {
        // Finalize both Visual R tokens and source colors in the native
        // transaction, before TextKit can paint fallback colors or line gaps.
        guard let storage = editor.textStorage else { return }
        // Each progressive layout slice resets only a few blocks. Recolor
        // those attributes instead of rebuilding/comparing the whole document.
        // Character edits can change fence context, so retain full validation.
        apply(in: storage.editedMask.contains(.editedCharacters) ? nil : storage.editedRange)
    }

    func ranges() -> [NSRange] {
        // Presentation only. Execution eligibility still belongs to FenceScanner.
        fences.blocks(in: editor.rawSource).filter {
            return $0.language?.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .split(whereSeparator: { $0.isWhitespace || $0 == "," }).first?.lowercased() == "r"
        }.map(\.contentRange)
    }
    private var dark: Bool { editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private var syntaxFont: NSFont {
        editor.theme.monospaceFont(ofSize: editor.viewMode == .source ? editor.theme.fontSize : editor.theme.monospaceFontSize)
    }
    private func prepareAttributes() {
        let dark = self.dark
        let font = preferences.boldKeywords || preferences.italicComments ? syntaxFont : nil
        let fontKey = font.map { "\($0.fontName)|\($0.pointSize)" } ?? ""
        let key = "\(preferences.key)|\(dark)|\(fontKey)"
        if key != attributesKey {
            attributesKey = key; attributePalette.removeAll(keepingCapacity: true)
            attributeDark = dark; attributeFont = font
        }
    }
    func color(_ scope: String) -> NSColor { preferences.color(RecordSyntaxKind(rawValue: scope) ?? .plain, dark: dark) }
    private func attributes(_ scope: String) -> [NSAttributedString.Key: Any] {
        if let cached = attributePalette[scope] { return cached }
        var attrs: [NSAttributedString.Key: Any]
        if let attributeFont { attrs = preferences.attributes(scope, dark: attributeDark, font: attributeFont) }
        else { attrs = [.foregroundColor: preferences.color(RecordSyntaxKind(rawValue: scope) ?? .plain, dark: attributeDark)] }
        attrs[Self.scopeKey] = scope
        // Compare this marker, rather than fallback-font names that native
        // Unicode font fixing can legitimately substitute in a comment.
        attrs[Self.styleKey] = attributesKey
        if attrs[.font] != nil { attrs[Self.fontTraitKey] = true }
        attributePalette[scope] = attrs
        return attrs
    }
    private func tokens(for code: String) -> [RecordRTokenSource.Token]? {
        let key = Data(code.utf8)
        tokenAccess &+= 1
        if var hit = tokenCache[key] {
            hit.access = tokenAccess; tokenCache[key] = hit
            return hit.tokens
        }
        guard let parsed = lexer.tokens(code) else { failures += 1; return nil }
        let cost = key.count + parsed.count * MemoryLayout<RecordRTokenSource.Token>.stride
        let limit = 4 * 1024 * 1024
        if cost <= limit {
            while tokenCacheCost + cost > limit || tokenCache.count >= 1024 {
                guard let oldest = tokenCache.min(by: { $0.value.access < $1.value.access }) else { break }
                tokenCacheCost -= oldest.value.cost; tokenCache.removeValue(forKey: oldest.key)
            }
            tokenCache[key] = CachedTokens(tokens: parsed, cost: cost, access: tokenAccess)
            tokenCacheCost += cost
        }
        return parsed
    }

    func apply(in invalidatedRange: NSRange? = nil) {
        guard !applying, !editor.hasMarkedText(), let storage = editor.textStorage,
              Data(editor.string.utf8) == Data(editor.rawSource.utf8) else { return }
        let start = ProcessInfo.processInfo.systemUptime
        applying = true
        defer { applying = false; onApplyTiming?((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        prepareAttributes()
        applyCount += 1
        let full = NSRange(location: 0, length: storage.length)
        let affected = invalidatedRange.flatMap { $0.location == NSNotFound ? nil : NSIntersectionRange($0, full) } ?? full
        guard affected.length > 0 else { return }
        if sourcePresentation != nil, presentationSource != Data(editor.rawSource.utf8) {
            sourcePresentation = nil; presentationSource = nil
        }
        let source = editor.rawSource as NSString
        if editor.viewMode == .source {
            applySource(storage: storage, affected: affected)
            return
        }
        var paragraphs: [(NSRange, NSParagraphStyle, Double?)] = []
        for block in fences.blocks(in: editor.rawSource) {
            guard block.fullRange.upperBound <= storage.length, NSIntersectionRange(block.fullRange, affected).length > 0 else { continue }
            let intersection = NSIntersectionRange(block.fullRange, affected)
            var offset = max(block.fullRange.location, source.paragraphRange(for: NSRange(location: intersection.location, length: 0)).location)
            while offset < intersection.upperBound {
                let range = NSIntersectionRange(source.paragraphRange(for: NSRange(location: offset, length: 0)), block.fullRange)
                guard range.length > 0 else { break }
                defer { offset = range.upperBound }
                guard let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle else { continue }
                let blank = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let previous = (storage.attribute(Self.blankSpacingKey, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue
                let leading = editor.theme.monospaceFontSize * 0.5
                let lineSpacing: CGFloat = blank ? 0 : leading
                let paragraphSpacing = max(0, style.paragraphSpacing - CGFloat(previous ?? 0)) + (blank ? leading : 0)
                let marker: Double? = blank ? Double(leading) : nil
                guard abs(style.lineSpacing - lineSpacing) > 0.1 || abs(style.paragraphSpacing - paragraphSpacing) > 0.1 || previous != marker else { continue }
                let updated = style.mutableCopy() as! NSMutableParagraphStyle
                updated.lineSpacing = lineSpacing; updated.paragraphSpacing = paragraphSpacing
                paragraphs.append((range, updated, marker))
            }
        }
        var desired: [(NSRange, String)] = []
        for range in ranges() where range.length > 0 && range.upperBound <= storage.length && NSIntersectionRange(range, affected).length > 0 {
            let code = source.substring(with: range)
            guard let tokens = tokens(for: code) else { continue }
            // Fill unscoped gaps too, removing the component's C-family fallback.
            var position = 0
            for token in tokens {
                guard token.range.location >= position, token.range.upperBound <= range.length else { failures += 1; return }
                if token.range.location > position {
                    desired.append((NSRange(location: range.location + position, length: token.range.location - position), "plain"))
                }
                desired.append((NSRange(location: range.location + token.range.location, length: token.range.length), token.scope))
                position = token.range.upperBound
            }
            if position < range.length {
                desired.append((NSRange(location: range.location + position, length: range.length - position), "plain"))
            }
        }
        // Only write differences: independent result-spacing and syntax
        // observers must settle instead of waking one another indefinitely.
        var updates: [(NSRange, String, Bool)] = []
        for (candidate, scope) in desired {
            let range = NSIntersectionRange(candidate, affected)
            guard range.length > 0 else { continue }
            let expected = attributes(scope)
            var matches = true, resetFont = false
            storage.enumerateAttributes(in: range) { attrs, _, _ in
                matches = matches && (attrs[Self.scopeKey] as? String == scope)
                    && (attrs[.foregroundColor] as? NSColor == expected[.foregroundColor] as? NSColor)
                    && attrs[Self.styleKey] as? String == attributesKey
                resetFont = resetFont || attrs[Self.fontTraitKey] != nil && expected[.font] == nil
            }
            if !matches || resetFont { updates.append((range, scope, resetFont)) }
        }
        guard !updates.isEmpty || !paragraphs.isEmpty else { return }
        storage.beginEditing()
        for (range, style, marker) in paragraphs {
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            if let marker { storage.addAttribute(Self.blankSpacingKey, value: marker, range: range) }
            else { storage.removeAttribute(Self.blankSpacingKey, range: range) }
        }
        for (range, scope, resetFont) in updates {
            if resetFont {
                storage.removeAttribute(Self.fontTraitKey, range: range)
                storage.addAttribute(.font, value: syntaxFont, range: range)
            }
            storage.addAttributes(attributes(scope), range: range)
        }
        storage.endEditing()
    }

    /// Compose the final attributes before comparing, so R tokens overlaid on
    /// Markdown fences cannot repeatedly invalidate one another. Text is never replaced.
    private func applySource(storage: NSTextStorage, affected: NSRange) {
        let bytes = Data(editor.rawSource.utf8)
        if markdownSource != bytes {
            guard let tokens = sourceMarkdownTokens() else { failures += 1; return }
            markdownSource = bytes; markdownTokens = tokens
        }
        let dark = editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let desired: NSAttributedString
        if let cached = sourcePresentation, presentationSource == bytes, presentationIsDark == dark, presentationAttributesKey == attributesKey {
            desired = cached
        } else {
            let compiled = NSMutableAttributedString(string: editor.rawSource,
                attributes: attributes("plain"))
            var complete = true
            func add(_ tokens: [RecordRTokenSource.Token], offset: Int = 0) {
                for token in tokens {
                    let range = NSRange(location: offset + token.range.location, length: token.range.length)
                    guard range.upperBound <= compiled.length else { continue }
                    compiled.addAttributes(self.attributes(token.scope), range: range)
                }
            }
            add(markdownTokens)
            let source = editor.rawSource as NSString
            for range in ranges() where range.length > 0 && range.upperBound <= storage.length {
                guard let parsed = tokens(for: source.substring(with: range)) else { complete = false; continue }
                compiled.addAttributes(self.attributes("plain"), range: range)
                add(parsed, offset: range.location)
            }
            desired = compiled
            sourcePresentation = complete ? compiled : nil; presentationSource = bytes; presentationIsDark = dark; presentationAttributesKey = attributesKey
        }
        var updates: [(NSRange, [NSAttributedString.Key: Any], Bool)] = []
        desired.enumerateAttributes(in: affected) { attrs, range, _ in
            var matches = true, resetFont = false
            storage.enumerateAttributes(in: range) { existing, _, _ in
                matches = matches && existing[Self.scopeKey] as? String == attrs[Self.scopeKey] as? String
                    && existing[.foregroundColor] as? NSColor == attrs[.foregroundColor] as? NSColor
                    && existing[Self.styleKey] as? String == attrs[Self.styleKey] as? String
                resetFont = resetFont || existing[Self.fontTraitKey] != nil && attrs[.font] == nil
            }
            if !matches || resetFont { updates.append((range, attrs, resetFont)) }
        }
        guard !updates.isEmpty else { return }
        storage.beginEditing()
        for (range, attrs, resetFont) in updates {
            if resetFont {
                storage.removeAttribute(Self.fontTraitKey, range: range)
                storage.addAttribute(.font, value: syntaxFont, range: range)
            }
            storage.addAttributes(attrs, range: range)
        }
        storage.endEditing()
    }

    private func sourceMarkdownTokens() -> [RecordRTokenSource.Token]? {
        // Structural fence ranges isolate prose before Tree-sitter Markdown
        // parsing, so inline backticks cannot pair unrelated block delimiters
        // and spill prose colors into a later executable chunk.
        let source = editor.rawSource as NSString
        var result: [RecordRTokenSource.Token] = []
        var offset = 0
        func appendProse(until end: Int) -> Bool {
            guard end > offset else { return true }
            let range = NSRange(location: offset, length: end - offset)
            guard let tokens = lexer.tokens(source.substring(with: range), language: "markdown") else { return false }
            result += tokens.map { .init(range: NSRange(location: offset + $0.range.location, length: $0.range.length), kind: $0.kind) }
            return true
        }
        for fence in fences.blocks(in: editor.rawSource) {
            guard fence.fullRange.location >= offset, fence.fullRange.upperBound <= source.length,
                  appendProse(until: fence.fullRange.location) else { return nil }
            result.append(.init(range: fence.fullRange, kind: .code))
            offset = fence.fullRange.upperBound
        }
        guard appendProse(until: source.length) else { return nil }
        return result
    }
}
