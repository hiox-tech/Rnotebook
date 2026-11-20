import AppKit

/// MIME representations of one already-computed output; independent of R classes.
struct RecordRichOutput: Codable, Sendable {
    struct Representation: Codable, Sendable {
        let mime: String
        let data: Data
        init(mime: String, text: String) { self.mime = mime; data = Data(text.utf8) }
        init(mime: String, data: Data) { self.mime = mime; self.data = data }
    }
    let title: String
    let representations: [Representation]
    var styles: [String] = []
    var plainText: String? {
        representations.first { $0.mime.lowercased() == "text/plain" }.flatMap { String(data: $0.data, encoding: .utf8) }
    }
}

private struct RecordStaticCell {
    let row: Int, column: Int, rowSpan: Int, columnSpan: Int
    let text: NSAttributedString
    let style: [String: String]
    let header: Bool
}
private struct RecordStaticTable {
    let cells: [RecordStaticCell]
    let rows: Int, columns: Int
}
private enum RecordStaticBlock {
    case text(NSAttributedString), table(RecordStaticTable), image(NSImage)
}

/// Foundation's native tidy parser plus a bounded static HTML/CSS subset.
/// Does not invoke the HTML attributed-string importer or a browser engine.
@MainActor private final class RecordStaticHTML {
    private static let borderTokens = try! NSRegularExpression(pattern: #"rgba?\([^)]*\)|[^\s]+"#, options: .caseInsensitive)
    private var rules: [(String, [String: String])] = []
    private let font: NSFont
    private var blocks: [RecordStaticBlock] = []
    private var text = NSMutableAttributedString(string: "")
    private var visited = 0
    private var requiresAlternative = false
    init(font: NSFont) { self.font = font }
    func parse(_ html: String, styles: [String]) -> [RecordStaticBlock]? {
        // Preserve source whitespace for well-formed static fragments. HTML
        // tidy is a fallback: it expands tabs, even inside preformatted cells.
        let exact = try? XMLDocument(xmlString: html, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever])
        guard let document = exact ?? (try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])),
              let root = document.rootElement() else { return nil }
        let embedded = (try? root.nodes(forXPath: ".//*[local-name()='style']"))?.compactMap(\.stringValue) ?? []
        for css in styles + embedded {
            for match in matches("([^{}]+)\\{([^{}]*)\\}", css) {
                let declarations = declarations(match[2])
                for selector in match[1].components(separatedBy: ",") { rules.append((selector.trimmingCharacters(in: .whitespacesAndNewlines), declarations)) }
            }
        }
        walk(root, inherited: [:]); flush()
        return blocks.isEmpty || visited > 30_000 || requiresAlternative ? nil : blocks
    }
    private func matches(_ pattern: String, _ source: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
        }
    }
    private func declarations(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in source.components(separatedBy: ";") {
            guard let colon = item.firstIndex(of: ":") else { continue }
            result[item[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = item[item.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    private func name(_ element: XMLElement) -> String { (element.localName ?? element.name ?? "").lowercased() }
    private func style(_ element: XMLElement, inherited: [String: String]) -> [String: String] {
        let inheritable: Set<String> = ["font-family", "font-size", "font-weight", "font-style", "color", "text-align", "white-space", "text-decoration"]
        var result = inherited.filter { inheritable.contains($0.key) }
        let tag = name(element), classes = Set((element.attribute(forName: "class")?.stringValue ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        for (selector, values) in rules {
            // Simple tag/class selectors used by kable/flextable static exports.
            // Complex layout selectors are intentionally not guessed.
            let parts = selector.components(separatedBy: ".")
            let matches = selector == tag || (parts.count > 1 && (parts[0].isEmpty || parts[0] == tag) && parts.dropFirst().allSatisfy(classes.contains))
                || (selector.hasPrefix("#") && String(selector.dropFirst()) == element.attribute(forName: "id")?.stringValue)
            if matches { result.merge(values) { _, new in new } }
        }
        result.merge(declarations(element.attribute(forName: "style")?.stringValue ?? "")) { _, new in new }
        if ["b", "strong", "th"].contains(tag) { result["font-weight"] = "bold" }
        if ["i", "em"].contains(tag) { result["font-style"] = "italic" }
        if tag == "pre" || tag == "code" { result["font-family"] = "monospace" }
        if tag == "pre" { result["white-space"] = "pre" }
        if tag == "u" { result["text-decoration"] = "underline" }
        if tag.count == 2, tag.first == "h", let level = Int(tag.dropFirst()), (1...6).contains(level) {
            result["font-weight"] = "bold"; result["font-size"] = "\(max(13, 25 - level * 2))pt"
        }
        if result["text-align"] == nil, let align = element.attribute(forName: "align")?.stringValue { result["text-align"] = align }
        return result
    }
    static func length(_ value: String?) -> CGFloat? {
        guard let value, let number = Double(value.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })), number.isFinite else { return nil }
        return CGFloat(number) * (value.hasSuffix("px") ? 0.75 : 1)
    }
    static func color(_ value: String?) -> NSColor? {
        guard let value else { return nil }
        let source = value.trimmingCharacters(in: .whitespaces).lowercased()
        let named: [String: NSColor] = ["black": .black, "white": .white, "red": .systemRed, "blue": .systemBlue, "gray": .gray, "grey": .gray, "transparent": .clear]
        if let color = named[source] { return color }
        if source.hasPrefix("#") {
            var hex = String(source.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6, let n = UInt32(hex, radix: 16) {
                return NSColor(srgbRed: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255, blue: CGFloat(n & 255) / 255, alpha: 1)
            }
        }
        if source.hasPrefix("rgb"), let open = source.firstIndex(of: "("), let close = source.lastIndex(of: ")") {
            let values = source[source.index(after: open)..<close].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if values.count >= 3 { return NSColor(srgbRed: CGFloat(values[0] / 255), green: CGFloat(values[1] / 255), blue: CGFloat(values[2] / 255), alpha: values.count == 4 ? CGFloat(values[3]) : 1) }
        }
        return nil
    }
    static func border(_ value: String?) -> (width: CGFloat, color: NSColor) {
        guard let value else { return (0.5, .separatorColor) }
        // rgba()/rgb() may contain spaces. A whitespace split loses the color
        // and used to turn flextable's authored borders into faint separators.
        let ns = value as NSString
        let parts = borderTokens.matches(in: value, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        if parts.contains(where: { ["none", "hidden"].contains($0.lowercased()) }) { return (0, .clear) }
        let named: [String: CGFloat] = ["thin": 0.75, "medium": 2.25, "thick": 3.75]
        let width = parts.compactMap { named[$0.lowercased()] ?? length($0) }.first ?? 0.5
        return (max(0, width), parts.compactMap(color).first ?? .separatorColor)
    }
    private func attributes(_ style: [String: String]) -> [NSAttributedString.Key: Any] {
        // A Notebook result follows the page typography. Preserve semantic
        // emphasis, color and table layout, not a package's fixed HTML font.
        let size = font.pointSize
        var face = font
        if style["font-family"] == "monospace" { face = .monospacedSystemFont(ofSize: size, weight: .regular) }
        if style["font-weight"] == "bold" || (Int(style["font-weight"] ?? "") ?? 0) >= 600 { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
        if style["font-style"] == "italic" { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = ["center": .center, "right": .right, "justify": .justified][style["text-align"] ?? ""] ?? .left
        var attrs: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: Self.color(style["color"]) ?? NSColor.labelColor, .paragraphStyle: paragraph]
        if style["text-decoration"]?.contains("underline") == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }
    private func trimmed(_ value: NSAttributedString) -> NSAttributedString {
        let ns = value.string as NSString
        let first = ns.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound else { return NSAttributedString(string: "") }
        let last = ns.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        return value.attributedSubstring(from: NSRange(location: first.location, length: NSMaxRange(last) - first.location))
    }
    private func flush() {
        let value = trimmed(text)
        if value.length > 0 { blocks.append(.text(value)) }
        text = NSMutableAttributedString(string: "")
    }
    private func newline() { if text.length > 0, !text.string.hasSuffix("\n") { text.append(NSAttributedString(string: "\n")) } }
    private func walk(_ node: XMLNode, inherited: [String: String]) {
        visited += 1; guard visited <= 30_000 else { return }
        guard let element = node as? XMLElement else {
            if node.kind == .text, let value = node.stringValue {
                let content = inherited["white-space"] == "pre" ? value : value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                text.append(NSAttributedString(string: content, attributes: attributes(inherited)))
            }
            return
        }
        let tag = name(element)
        guard !["head", "script", "style", "link", "iframe", "object", "embed"].contains(tag) else { return }
        let css = style(element, inherited: inherited)
        if css["display"] == "none" { return }
        // Foundation tidy represents a <br> with a synthetic newline child.
        // Emit the break once rather than also walking that generated child.
        if tag == "br" { newline(); return }
        if tag == "table" { flush(); if let table = table(element, inherited: css) { blocks.append(.table(table)) }; return }
        if tag == "img" {
            flush()
            if let src = element.attribute(forName: "src")?.stringValue, src.hasPrefix("data:image/"), let comma = src.firstIndex(of: ","), src[..<comma].hasSuffix(";base64"),
               let data = Data(base64Encoded: String(src[src.index(after: comma)...])), let image = NSImage(data: data) { blocks.append(.image(image)) }
            else { blocks.append(.text(NSAttributedString(string: element.attribute(forName: "alt")?.stringValue ?? L10n.string("图像未嵌入结果中。"), attributes: attributes(css)))) }
            return
        }
        let isBlock = ["p", "div", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "li"].contains(tag)
        if isBlock { newline() }
        if tag == "li" { text.append(NSAttributedString(string: "• ", attributes: attributes(css))) }
        for child in element.children ?? [] { walk(child, inherited: css) }
        if isBlock { newline() }
    }
    private func table(_ element: XMLElement, inherited: [String: String]) -> RecordStaticTable? {
        let rows = ((try? element.nodes(forXPath: ".//*[local-name()='tr']")) ?? []).compactMap { $0 as? XMLElement }.filter { row in
            var parent = row.parent
            while let p = parent as? XMLElement { if name(p) == "table" { return p === element }; parent = p.parent }
            return false
        }
        guard rows.count <= 1000 else { requiresAlternative = true; return nil }
        var cells: [RecordStaticCell] = [], occupied = Set<String>(), columns = 0
        for (r, row) in rows.prefix(1000).enumerated() {
            var c = 0
            let rowStyle = style(row, inherited: inherited)
            let rowCells = (row.children ?? []).compactMap({ $0 as? XMLElement }).filter({ ["td", "th"].contains(name($0)) })
            guard rowCells.count <= 100 else { requiresAlternative = true; return nil }
            for cell in rowCells {
                while occupied.contains("\(r):\(c)") { c += 1 }
                guard c < 100 else { requiresAlternative = true; return nil }
                let colspan = min(100 - c, max(1, Int(cell.attribute(forName: "colspan")?.stringValue ?? "") ?? 1))
                let rowspan = min(min(1000, rows.count) - r, max(1, Int(cell.attribute(forName: "rowspan")?.stringValue ?? "") ?? 1))
                let css = style(cell, inherited: rowStyle)
                let saved = text; text = NSMutableAttributedString(string: "")
                for child in cell.children ?? [] { walk(child, inherited: css) }
                let value = trimmed(text); text = saved
                cells.append(RecordStaticCell(row: r, column: c, rowSpan: rowspan, columnSpan: colspan, text: value, style: css, header: name(cell) == "th"))
                for rr in r..<(r + rowspan) { for cc in c..<(c + colspan) { occupied.insert("\(rr):\(cc)") } }
                c += colspan; columns = max(columns, c)
            }
        }
        guard columns > 0 else { return nil }
        return RecordStaticTable(cells: cells, rows: min(1000, rows.count), columns: columns)
    }
}

fileprivate struct RecordRichTableCell {
    let range: NSRange
    let row: Int, column: Int, rowSpan: Int, columnSpan: Int
}
fileprivate struct RecordRichTableRange {
    let range: NSRange
    let cells: [RecordRichTableCell]
}
@MainActor fileprivate struct RecordNativeRichDocument {
    let text: NSAttributedString
    let tables: [RecordRichTableRange]
    init(blocks: [RecordStaticBlock], font: NSFont) {
        let result = NSMutableAttributedString(string: "")
        var tables: [RecordRichTableRange] = []
        for block in blocks {
            switch block {
            case .text(let value): result.append(value); result.append(NSAttributedString(string: "\n\n", attributes: [.font: font]))
            case .image(let image):
                let attachment = NSTextAttachment(); attachment.image = image
                attachment.bounds = NSRect(origin: .zero, size: image.size)
                result.append(NSAttributedString(attachment: attachment)); result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            case .table(let value):
                let table = NSTextTable(); table.numberOfColumns = value.columns
                table.layoutAlgorithm = .fixedLayoutAlgorithm; table.collapsesBorders = true
                table.setContentWidth(100, type: .percentageValueType)
                let start = result.length
                var cells: [RecordRichTableCell] = []
                for cell in value.cells {
                    let native = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: cell.rowSpan,
                                                  startingColumn: cell.column, columnSpan: cell.columnSpan)
                    native.setWidth(6, type: .absoluteValueType, for: .padding)
                    native.backgroundColor = RecordStaticHTML.color(cell.style["background-color"] ?? cell.style["background"])
                        ?? (cell.header ? .controlBackgroundColor : .textBackgroundColor)
                    native.verticalAlignment = cell.style["vertical-align"] == "middle" ? .middle : .top
                    for (name, edge) in [("top", NSRectEdge.minY), ("bottom", .maxY), ("left", .minX), ("right", .maxX)] {
                        let css = cell.style["border-" + name] ?? cell.style["border"]
                        let border = RecordStaticHTML.border(css)
                        native.setWidth(border.width, type: .absoluteValueType, for: .border, edge: edge)
                        native.setBorderColor(border.color, for: edge)
                    }
                    let content = NSMutableAttributedString(attributedString: cell.text)
                    content.append(NSAttributedString(string: "\n", attributes: cell.text.length > 0 ? cell.text.attributes(at: cell.text.length - 1, effectiveRange: nil) : [.font: NSFont.systemFont(ofSize: 13)]))
                    var paragraphs: [(NSRange, NSParagraphStyle)] = []
                    content.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: content.length)) { style, range, _ in
                        let paragraph = ((style as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                        paragraph.textBlocks = [native]
                        paragraphs.append((range, paragraph))
                    }
                    for (range, paragraph) in paragraphs { content.addAttribute(.paragraphStyle, value: paragraph, range: range) }
                    let range = NSRange(location: result.length, length: content.length)
                    cells.append(RecordRichTableCell(range: range, row: cell.row, column: cell.column, rowSpan: cell.rowSpan, columnSpan: cell.columnSpan))
                    result.append(content)
                }
                tables.append(RecordRichTableRange(range: NSRange(location: start, length: result.length - start), cells: cells))
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        text = result; self.tables = tables
    }
}

@MainActor enum RecordResultClipboard {
    static var markdownType: NSPasteboard.PasteboardType { .init("com.kailivd.notebook-result.markdown") }
    static func markdownText(from pasteboard: NSPasteboard) -> String? {
        if let own = pasteboard.string(forType: markdownType) { return own }
        // Also accept an older copied table still on the system clipboard.
        // Read RTF independently; never insert NSTextTable into the editor.
        guard let data = pasteboard.data(forType: .rtf), data.count <= 4 * 1024 * 1024,
              let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { return nil }
        var hasTable = false
        rich.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rich.length)) { value, _, stop in
            if (value as? NSParagraphStyle)?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true { hasTable = true; stop.pointee = true }
        }
        guard hasTable else { return nil }
        let plain = pasteboard.string(forType: .string) ?? rich.string
        return markdown(plain, tableSelection: plain.contains("\t"))
    }
    static func markdown(_ plain: String, tableSelection: Bool) -> String {
        guard tableSelection, let rows = RecordTableClipboard.parse(plain.trimmingCharacters(in: .newlines)),
              let first = rows.first, !first.isEmpty else { return plain }
        func row(_ cells: [String]) -> String {
            "| " + cells.map { value in
                value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "\r", with: "<br>")
            }.joined(separator: " | ") + " |"
        }
        return "\n\n" + ([row(first), row(first.map { _ in "---" })] + rows.dropFirst().map(row)).joined(separator: "\n") + "\n\n"
    }
}

/// A single independent, read-only TextKit 1 surface supports native text and
/// merged-table selection. Its NSTextTable attributes never enter the editor.
@MainActor final class RecordNativeRichTextView: NSTextView {
    private let tables: [RecordRichTableRange]
    private var cellBounds: [NSRect] = []
    private var cellBoundsWidth: CGFloat?
    private var tableContainerWidth: CGFloat?
    fileprivate init(document: RecordNativeRichDocument) {
        tables = document.tables
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; isRichText = true; allowsUndo = false
        drawsBackground = false; textContainerInset = NSSize(width: 8, height: 8)
        isVerticallyResizable = true; isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true; textContainer?.heightTracksTextView = false
        textContainer?.lineFragmentPadding = 0
        textStorage?.setAttributedString(document.text)
        setAccessibilityIdentifier("native-rich-result-text")
    }
    required init?(coder: NSCoder) { nil }
    private func updateCellBounds() {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer,
              cellBoundsWidth != container.containerSize.width else { return }
        manager.ensureLayout(for: container)
        cellBounds = tables.flatMap(\.cells).compactMap { cell in
            guard cell.range.location < storage.length,
                  let paragraph = storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let block = paragraph.textBlocks.first as? NSTextTableBlock else { return nil }
            let glyphs = manager.glyphRange(forCharacterRange: cell.range, actualCharacterRange: nil)
            let rect = manager.boundsRect(for: block, glyphRange: glyphs)
            let horizontal = max(block.width(for: .border, edge: .minX), block.width(for: .border, edge: .maxX)) / 2 + 1
            let vertical = max(block.width(for: .border, edge: .minY), block.width(for: .border, edge: .maxY)) / 2 + 1
            return rect.isEmpty ? nil : rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -horizontal, dy: -vertical)
        }
        cellBoundsWidth = container.containerSize.width
    }
    override func draw(_ dirtyRect: NSRect) {
        updateCellBounds()
        // TextKit's glyph lookup returns an empty range for a border-only dirty
        // strip. Supply the affected cell bounds to its one native drawing pass,
        // while AppKit's original graphics clip still limits the actual repaint.
        // Native selection, collapsed borders, merged cells and RTF stay intact.
        var drawingRect = dirtyRect
        for rect in cellBounds where rect.intersects(dirtyRect) {
            drawingRect = drawingRect.union(rect)
        }
        super.draw(drawingRect)
    }
    private func quoted(_ value: String) -> String {
        value.contains(where: { $0 == "\t" || $0.isNewline || $0 == "\"" })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    func plainTextForSelection(_ selection: NSRange) -> String {
        guard let storage = textStorage, selection.length > 0, NSMaxRange(selection) <= storage.length else { return "" }
        let ns = storage.string as NSString
        var text = "", offset = selection.location
        for table in tables {
            let hit = NSIntersectionRange(selection, table.range)
            guard hit.length > 0 else { continue }
            if hit.location > offset { text += ns.substring(with: NSRange(location: offset, length: hit.location - offset)) }
            let cells = table.cells.filter { NSIntersectionRange(hit, $0.range).length > 0 }
            if cells.count < 2 { text += ns.substring(with: hit) }
            else {
                let top = cells.map(\.row).min()!, bottom = cells.map { $0.row + $0.rowSpan - 1 }.max()!
                let left = cells.map(\.column).min()!, right = cells.map { $0.column + $0.columnSpan - 1 }.max()!
                text += (top...bottom).map { row in
                    (left...right).map { column in
                        guard let cell = cells.first(where: { $0.row == row && $0.column == column }) else { return "" }
                        let range = NSIntersectionRange(hit, cell.range)
                        var value = ns.substring(with: range)
                        if NSMaxRange(range) == NSMaxRange(cell.range), value.hasSuffix("\n") { value.removeLast() }
                        return quoted(value)
                    }.joined(separator: "\t")
                }.joined(separator: "\n")
                if NSMaxRange(hit) < NSMaxRange(selection) { text += "\n" }
            }
            offset = NSMaxRange(hit)
        }
        if offset < NSMaxRange(selection) { text += ns.substring(with: NSRange(location: offset, length: NSMaxRange(selection) - offset)) }
        return text
    }
    @discardableResult func copySelection(to pasteboard: NSPasteboard) -> Bool {
        let selection = selectedRange()
        guard selection.length > 0, let storage = textStorage, NSMaxRange(selection) <= storage.length else { return false }
        let value = storage.attributedSubstring(from: selection)
        let plain = plainTextForSelection(selection)
        let tableSelection = tables.contains { table in
            let hit = NSIntersectionRange(selection, table.range)
            return table.cells.filter { NSIntersectionRange(hit, $0.range).length > 0 }.count > 1
                && storage.attributedSubstring(from: selection).string.trimmingCharacters(in: .whitespacesAndNewlines)
                    == storage.attributedSubstring(from: hit).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var types: [NSPasteboard.PasteboardType] = [.string, RecordResultClipboard.markdownType]
        let rtf = try? value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        if rtf != nil { types.append(.rtf) }
        pasteboard.declareTypes(types, owner: nil); pasteboard.setString(plain, forType: .string)
        pasteboard.setString(RecordResultClipboard.markdown(plain, tableSelection: tableSelection), forType: RecordResultClipboard.markdownType)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
        return true
    }
    override func copy(_ sender: Any?) { _ = copySelection(to: .general) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: L10n.string("拷贝"), action: #selector(copy(_:)), keyEquivalent: "c"); copy.target = self
        copy.isEnabled = selectedRange().length > 0
        let all = menu.addItem(withTitle: L10n.string("全选"), action: #selector(selectAll(_:)), keyEquivalent: "a"); all.target = self
        return menu
    }
    func arrange(width: CGFloat) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 100 }
        let width = max(40, width)
        if abs(frame.width - width) > 0.5 { frame.size.width = width }
        container.containerSize = NSSize(width: max(24, width - textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        if tableContainerWidth != container.containerSize.width, let storage = textStorage {
            // A collapsed 100% NSTextTable can place its last stroke just past
            // TextKit's container clip when column widths divide evenly. Reserve
            // the authored stroke inside that clip, independently of the view's
            // existing inset and the result scroller gutter.
            for entry in tables {
                var table: NSTextTable?, rightBorder: CGFloat = 0
                for cell in entry.cells where cell.range.location < storage.length {
                    guard let paragraph = storage.attribute(.paragraphStyle, at: cell.range.location, effectiveRange: nil) as? NSParagraphStyle,
                          let block = paragraph.textBlocks.first as? NSTextTableBlock else { continue }
                    table = block.table
                    rightBorder = max(rightBorder, block.width(for: .border, edge: .maxX))
                }
                table?.setContentWidth(max(1, floor(container.containerSize.width - max(1, ceil(rightBorder)))), type: .absoluteValueType)
            }
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            tableContainerWidth = container.containerSize.width
            cellBoundsWidth = nil
        }
        manager.ensureLayout(for: container)
        updateCellBounds()
        let height = ceil(manager.usedRect(for: container).height) + textContainerInset.height * 2
        if abs(frame.height - height) > 0.5 { frame.size.height = height }
        return height
    }
}

/// Only the selected tab owns this surface. Other outputs remain lightweight data.
@MainActor final class RecordRichOutputView: NSView {
    private let scroll = RecordOutputViewport(frame: .zero)
    let textView: RecordNativeRichTextView
    override var isFlipped: Bool { true }
    init(output: RecordRichOutput, font: NSFont) {
        let order = ["text/html", "image/png", "image/jpeg", "image/svg+xml", "text/markdown", "text/plain"]
        var blocks: [RecordStaticBlock] = []
        if output.representations.reduce(0, { $0 + $1.data.count }) + output.styles.reduce(0, { $0 + $1.utf8.count }) <= 4 * 1024 * 1024 {
            for mime in order {
                guard let representation = output.representations.first(where: { $0.mime.lowercased() == mime }) else { continue }
                if mime == "text/html", let html = String(data: representation.data, encoding: .utf8), let parsed = RecordStaticHTML(font: font).parse(html, styles: output.styles) { blocks = parsed }
                else if mime.hasPrefix("image/"), let image = NSImage(data: representation.data), image.size.width > 0, image.size.height > 0 { blocks = [.image(image)] }
                else if ["text/markdown", "text/plain"].contains(mime), let text = String(data: representation.data, encoding: .utf8) {
                    let value = mime == "text/markdown" ? (try? AttributedString(markdown: text)) : nil
                    let styled = NSMutableAttributedString(attributedString: value.map(NSAttributedString.init) ?? NSAttributedString(string: text))
                    styled.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: styled.length))
                    blocks = [.text(styled)]
                }
                if !blocks.isEmpty { break }
            }
        }
        if blocks.isEmpty {
            let value = L10n.string("此结果格式暂不支持内嵌显示。\n") + (output.plainText ?? output.representations.map(\.mime).joined(separator: "、"))
            blocks = [.text(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))]
        }
        textView = RecordNativeRichTextView(document: RecordNativeRichDocument(blocks: blocks, font: font))
        super.init(frame: .zero)
        clipsToBounds = true
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.reservesVerticalScrollerSpace = true
        scroll.clipsToBounds = true; scroll.contentView.clipsToBounds = true
        scroll.documentView = textView; addSubview(scroll)
        setAccessibilityLabel(output.title)
    }
    required init?(coder: NSCoder) { nil }
    func desiredHeight(width: CGFloat) -> CGFloat { min(320, max(100, textView.arrange(width: width - scroll.verticalScrollerGutter))) }
    override func layout() { super.layout(); scroll.frame = bounds; _ = textView.arrange(width: scroll.contentSize.width) }
}
