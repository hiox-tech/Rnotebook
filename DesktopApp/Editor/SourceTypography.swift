import AppKit
import EdmundCore

@MainActor enum RecordSourceTypography {
    private static let fontKey = NSAttributedString.Key("KailRecordSource.font")
    static func attributes(for font: NSFont) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        let height = ceil(max(font.ascender - font.descender + font.leading, font.pointSize * 1.5))
        style.minimumLineHeight = height; style.maximumLineHeight = height
        style.lineSpacing = 0; style.paragraphSpacing = 0; style.paragraphSpacingBefore = 0
        return [.font: font, fontKey: "\(font.fontName)|\(font.pointSize)", .paragraphStyle: style.copy() as! NSParagraphStyle]
    }
    static func apply(to editor: EditorTextView) {
        guard editor.viewMode == .source, !editor.hasMarkedText(), let storage = editor.textStorage,
              Data(editor.rawSource.utf8) == Data(editor.string.utf8) else { return }
        let font = editor.theme.monospaceFont(ofSize: editor.theme.fontSize)
        let stamp = "\(font.fontName)|\(font.pointSize)"
        let style = attributes(for: font)[.paragraphStyle] as! NSParagraphStyle
        var updates: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            var desired: [NSAttributedString.Key: Any] = [:]
            // Font fixing may substitute CJK/emoji faces. The marker survives
            // that pass, avoiding an endless reset/substitution notification loop.
            if attrs[fontKey] as? String != stamp || (attrs[.font] as? NSFont)?.pointSize != font.pointSize {
                desired[.font] = font; desired[fontKey] = stamp
            }
            if attrs[.paragraphStyle] as? NSParagraphStyle != style { desired[.paragraphStyle] = style }
            if !desired.isEmpty { updates.append((range, desired)) }
        }
        if !updates.isEmpty {
            storage.beginEditing()
            for (range, attrs) in updates { storage.addAttributes(attrs, range: range) }
            storage.endEditing()
        }
        var typing = editor.typingAttributes
        if typing[.font] as? NSFont != font || typing[.paragraphStyle] as? NSParagraphStyle != style {
            typing[.font] = font; typing[.paragraphStyle] = style; typing[fontKey] = stamp
            editor.typingAttributes = typing
        }
    }
}

