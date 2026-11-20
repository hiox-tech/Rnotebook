import AppKit

/// Native, paired light/dark palettes. Only the default retains the original
/// Tomorrow/One Dark colors; the other three are locally authored adaptations.
struct RecordSyntaxPreferences: Equatable {
    static let palettes = ["default", "ocean", "forest", "warm"]
    var enabled = true
    var palette = "default"
    var italicComments = false
    var boldKeywords = false
    var key: String { "\(enabled)|\(palette)|\(italicComments)|\(boldKeywords)" }
    init() {}
    @MainActor func attributes(_ scope: String, dark: Bool, font: NSFont) -> [NSAttributedString.Key: Any] {
        let kind = RecordSyntaxKind(rawValue: scope) ?? .plain
        var traits: NSFontTraitMask = []
        if enabled, italicComments, kind == .comment { traits.insert(.italicFontMask) }
        if enabled, boldKeywords, kind == .keyword { traits.insert(.boldFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(kind, dark: dark)]
        if !traits.isEmpty { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        return attributes
    }
    func color(_ kind: RecordSyntaxKind, dark: Bool) -> NSColor {
        let token = enabled ? kind : .plain
        let colors: [UInt32]
        switch palette {
        // plain, comment, string, number, keyword, literal, heading, link/function
        case "ocean": colors = dark
            ? [0xd7e3f4, 0x93a5bd, 0x8dd4ca, 0xffc58d, 0xc5a6ff, 0xffc58d, 0x91caff, 0x78c7ff]
            : [0x243b53, 0x586f88, 0x176b5b, 0xa24d0c, 0x6741a5, 0x9c4c00, 0x175b91, 0x006cad]
        case "forest": colors = dark
            ? [0xd9e5d5, 0x9cafa0, 0xa7d98b, 0xf2c17d, 0xd5b4f3, 0xf2c17d, 0x9ed8b4, 0x8bcfc5]
            : [0x2c3e32, 0x617364, 0x376b21, 0x98500d, 0x754394, 0x98500d, 0x25633e, 0x16695e]
        case "warm": colors = dark
            ? [0xe9ddd2, 0xb6a194, 0xb5d499, 0xf0bd85, 0xe9a0b6, 0xf0bd85, 0xf5c38f, 0x9dc9e6]
            : [0x46372e, 0x77675b, 0x596f28, 0xa24e14, 0x96435c, 0xa24e14, 0x8b4726, 0x326d8b]
        default: colors = dark
            ? [0xabb2bf, 0x5c6370, 0x98c379, 0xd19a66, 0xc678dd, 0xd19a66, 0xe06c75, 0x61afef]
            : [0x4d4d4c, 0x8e908c, 0x718c00, 0xf5871f, 0x8959a8, 0x986801, 0xc82829, 0x4271ae]
        }
        let index: Int = switch token {
        case .comment: 1
        case .string, .code: 2
        case .number: 3
        case .keyword, .quote, .emphasis: 4
        case .literal: 5
        case .heading, .strong: 6
        case .link, .bullet, .function, .builtin: 7
        default: 0
        }
        let rgb = colors[index]
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func nativeScope(_ type: String?) -> String {
        switch type {
        case "command", "type", "attribute": "function"
        case "value": "literal"
        case "variable": "plain"
        default: type ?? "plain"
        }
    }
}

