import AppKit
import SwiftUI
import EdmundCore
import UniformTypeIdentifiers

/// Localized tool definitions are immutable within a language. Cache them so
/// toolbar redraws do not repeat bundle lookups for every entry.
private final class RecordLocalizedCatalog<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: Value] = [:]
    func value(_ make: () -> Value) -> Value {
        let language = L10n.resources.language.id
        lock.lock(); defer { lock.unlock() }
        if let cached = snapshots[language] { return cached }
        let result = make(); snapshots[language] = result
        return result
    }
}

enum RecordVisualCommand: Hashable {
    case heading(Int), bold, italic, strike, inlineCode, bullet, numbered, task, quote
    case link, codeBlock, table, rule, formula
    case underline, highlight, superscript, subscriptText, inlineMath, keyboard, comment
    case wikilink, footnote, imageReference, attachImage, genericCode, headingIncrease, headingDecrease
    case callout(String), textCode, mermaid(String)

    var selector: Selector {
        switch self {
        case .heading: return #selector(EditorTextView.formatHeading(_:))
        case .headingIncrease: return #selector(EditorTextView.formatIncrementHeading(_:))
        case .headingDecrease: return #selector(EditorTextView.formatDecrementHeading(_:))
        case .bold: return #selector(EditorTextView.formatBold(_:))
        case .italic: return #selector(EditorTextView.formatItalic(_:))
        case .underline: return #selector(EditorTextView.formatUnderline(_:))
        case .strike: return #selector(EditorTextView.formatStrikethrough(_:))
        case .highlight: return #selector(EditorTextView.formatHighlight(_:))
        case .inlineCode: return #selector(EditorTextView.formatCode(_:))
        case .superscript: return #selector(EditorTextView.formatSuperscript(_:))
        case .subscriptText: return #selector(EditorTextView.formatSubscript(_:))
        case .inlineMath: return #selector(EditorTextView.formatInlineMath(_:))
        case .keyboard: return #selector(EditorTextView.formatKeyboard(_:))
        case .comment: return #selector(EditorTextView.formatComment(_:))
        case .bullet: return #selector(EditorTextView.formatBulletedList(_:))
        case .numbered: return #selector(EditorTextView.formatNumberedList(_:))
        case .task: return #selector(EditorTextView.formatChecklist(_:))
        case .quote: return #selector(EditorTextView.formatBlockQuote(_:))
        case .link: return #selector(EditorTextView.formatLink(_:))
        case .wikilink: return #selector(EditorTextView.formatWikilink(_:))
        case .footnote: return #selector(EditorTextView.formatFootnote(_:))
        case .imageReference: return #selector(EditorTextView.formatImage(_:))
        case .attachImage: return #selector(EditorTextView.formatAttachImage(_:))
        case .codeBlock, .genericCode, .textCode, .mermaid: return #selector(EditorTextView.formatCodeBlock(_:))
        case .table: return #selector(EditorTextView.formatTable(_:))
        case .rule: return #selector(EditorTextView.formatThematicBreak(_:))
        case .formula: return #selector(EditorTextView.formatMathBlock(_:))
        case .callout: return #selector(EditorTextView.formatCallout(_:))
        }
    }
    var representedObject: Any? {
        if case .callout(let type) = self { return Callout.isGFMAlert(type) ? type.uppercased() : type }
        return nil
    }
}

struct RecordVisualTool: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let command: RecordVisualCommand
    private static let commonCatalog = RecordLocalizedCatalog<[RecordVisualTool]>()
    private static let extendedCatalog = RecordLocalizedCatalog<[RecordVisualTool]>()
    private static let calloutCatalog = RecordLocalizedCatalog<[(String, String)]>()
    static var common: [Self] { commonCatalog.value { [
        .init(id: "bold", title: L10n.string("加粗"), symbol: "bold", command: .bold),
        .init(id: "italic", title: L10n.string("斜体"), symbol: "italic", command: .italic),
        .init(id: "underline", title: L10n.string("下划线"), symbol: "underline", command: .underline),
        .init(id: "strike", title: L10n.string("删除线"), symbol: "strikethrough", command: .strike),
        .init(id: "highlight", title: L10n.string("高亮"), symbol: "highlighter", command: .highlight),
        .init(id: "inline-code", title: L10n.string("行内代码"), symbol: "chevron.left.forwardslash.chevron.right", command: .inlineCode),
        .init(id: "bullet", title: L10n.string("无序列表"), symbol: "list.bullet", command: .bullet),
        .init(id: "numbered", title: L10n.string("有序列表"), symbol: "list.number", command: .numbered),
        .init(id: "task", title: L10n.string("任务列表"), symbol: "checklist", command: .task),
        .init(id: "link", title: L10n.string("链接"), symbol: "link", command: .link),
        .init(id: "image", title: L10n.string("导入图片"), symbol: "photo", command: .attachImage),
        .init(id: "table", title: L10n.string("表格"), symbol: "tablecells", command: .table),
        .init(id: "r-code", title: L10n.string("R代码块"), symbol: "curlybraces", command: .codeBlock),
        .init(id: "quote", title: L10n.string("引用"), symbol: "text.quote", command: .quote),
    ] } }
    static var extended: [Self] { extendedCatalog.value { [
        .init(id: "code", title: L10n.string("普通代码块"), symbol: "curlybraces.square", command: .genericCode),
        .init(id: "text-code", title: L10n.string("Text代码块"), symbol: "text.alignleft", command: .textCode),
        .init(id: "inline-math", title: L10n.string("行内公式"), symbol: "function", command: .inlineMath),
        .init(id: "math", title: L10n.string("公式块"), symbol: "sum", command: .formula),
        .init(id: "footnote", title: L10n.string("脚注"), symbol: "number.square", command: .footnote),
        .init(id: "wikilink", title: L10n.string("内部链接"), symbol: "link.circle", command: .wikilink),
        .init(id: "image-reference", title: L10n.string("图片路径引用"), symbol: "photo.on.rectangle", command: .imageReference),
        .init(id: "keyboard", title: L10n.string("键盘标记"), symbol: "keyboard", command: .keyboard),
        .init(id: "superscript", title: L10n.string("上标"), symbol: "textformat.superscript", command: .superscript),
        .init(id: "subscript", title: L10n.string("下标"), symbol: "textformat.subscript", command: .subscriptText),
        .init(id: "comment", title: L10n.string("注释"), symbol: "text.bubble", command: .comment),
        .init(id: "rule", title: L10n.string("分隔线"), symbol: "minus", command: .rule),
    ] } }
    static var callouts: [(String, String)] { calloutCatalog.value { [
        ("note", L10n.string("备注")), ("tip", L10n.string("提示")), ("important", L10n.string("重要")), ("warning", L10n.string("警告")), ("caution", L10n.string("注意")),
        ("abstract", L10n.string("摘要")), ("info", L10n.string("信息")), ("todo", L10n.string("待办")), ("success", L10n.string("成功")), ("question", L10n.string("问题")),
        ("failure", L10n.string("失败")), ("danger", L10n.string("危险")), ("bug", L10n.string("问题报告")), ("example", L10n.string("示例")), ("quote", L10n.string("引文")),
    ] } }
}

struct RecordMermaidDiagram: Identifiable {
    let id: String
    let title: String
    let source: String
    // The six diagram families supported by the pinned beautiful-mermaid engine.
    private static let catalog = RecordLocalizedCatalog<[RecordMermaidDiagram]>()
    static var all: [Self] { catalog.value { [
        .init(id: "flowchart", title: L10n.string("流程图"), source: L10n.string("flowchart TD\n    A[开始] --> B[结束]")),
        .init(id: "sequence", title: L10n.string("时序图"), source: L10n.string("sequenceDiagram\n    participant A as 发起方\n    participant B as 接收方\n    A->>B: 请求\n    B-->>A: 响应")),
        .init(id: "class", title: L10n.string("类图"), source: "classDiagram\n    class Sample {\n        +String name\n        +analyze()\n    }"),
        .init(id: "state", title: L10n.string("状态图"), source: "stateDiagram-v2\n    [*] --> Ready\n    Ready --> Done\n    Done --> [*]"),
        .init(id: "er", title: L10n.string("实体关系图"), source: "erDiagram\n    PROJECT ||--o{ SAMPLE : contains\n    SAMPLE {\n        string name\n    }"),
        .init(id: "xy", title: L10n.string("XY图"), source: "xychart-beta\n    x-axis [A, B, C]\n    y-axis 0 --> 10\n    bar [3, 7, 5]"),
    ] } }
}

enum RecordVisualTableAlignment: String, CaseIterable, Identifiable {
    case left, center, right
    var id: Self { self }
    var title: String { switch self { case .left: return L10n.string("左对齐"); case .center: return L10n.string("居中对齐"); case .right: return L10n.string("右对齐") } }
    var separator: String { switch self { case .left: return ":---"; case .center: return ":---:"; case .right: return "---:" } }
}

@MainActor final class RecordVisualInsertionAnchor {
    weak var editor: EditorTextView?
    let source: String
    let selection: NSRange
    init(editor: EditorTextView) {
        self.editor = editor; source = editor.rawSource; selection = editor.selectedRange()
    }
}

struct RecordVisualContext: Equatable {
    var heading = 0
    var bold = false
    var italic = false
    var strike = false
    var inlineCode = false
    var list = ""
    var activeActions = Set<Selector>()
}

/// Reads structural context without converting or serializing the source.
@MainActor enum RecordVisualEditing {
    static func context(_ source: String, selection: NSRange) -> RecordVisualContext {
        let ns = source as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length,
              Range(selection, in: source) != nil else { return .init() }
        let end = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let range = NSUnionRange(ns.paragraphRange(for: NSRange(location: selection.location, length: 0)),
                                 ns.paragraphRange(for: NSRange(location: end, length: 0)))
        let text = ns.substring(with: range)
        var result = RecordVisualContext()
        if let match = text.range(of: "^ {0,3}#{1,6}[ \t]+", options: .regularExpression) {
            result.heading = text[match].filter { $0 == "#" }.count
        }
        if text.range(of: #"^\s*[-+*] \[[ xX]\] "#, options: .regularExpression) != nil { result.list = "task" }
        else if text.range(of: #"^\s*[-+*] "#, options: .regularExpression) != nil { result.list = "bullet" }
        else if text.range(of: #"^\s*[0-9]+[.)] "#, options: .regularExpression) != nil { result.list = "numbered" }
        return result
    }

}

extension RecordLayoutModel {
    func refreshVisualContext() {
        guard !sourceOnly, let editor = activeEditor, !editor.hasMarkedText() else {
            if visualContext != .init() { visualContext = .init() }; return
        }
        var next = RecordVisualEditing.context(editor.string, selection: editor.selectedRange())
        if let native = editor as? EditorTextView {
            let active = native.activeFormattingActions()
            next.activeActions = active
            next.bold = active.contains(#selector(EditorTextView.formatBold(_:)))
            next.italic = active.contains(#selector(EditorTextView.formatItalic(_:)))
            next.strike = active.contains(#selector(EditorTextView.formatStrikethrough(_:)))
            next.inlineCode = active.contains(#selector(EditorTextView.formatCode(_:)))
        }
        if visualContext != next { visualContext = next }
    }
    func format(_ command: RecordVisualCommand) {
        guard let editor = prepareVisualFormatting() else { return }
        if command == .attachImage { importVisualImage(); return }
        editor.window?.makeFirstResponder(editor)
        if formatBlankHeading(command, editor: editor) {
            source = editor.rawSource; refreshVisualContext(); return
        }
        // The component's selection path treats a three-star run as indivisible.
        // Preserve the other emphasis when toggling a selected bold+italic span.
        let selection = editor.selectedRange(), ns = editor.rawSource as NSString
        if selection.length > 0, command == .bold || command == .italic {
            var left = 0, right = 0
            while selection.location - left > 0, ns.character(at: selection.location - left - 1) == 42 { left += 1 }
            while NSMaxRange(selection) + right < ns.length, ns.character(at: NSMaxRange(selection) + right) == 42 { right += 1 }
            let count = min(left, right)
            if (1...3).contains(count) {
                let width = command == .bold ? 2 : 1
                let present = command == .bold ? count >= 2 : count % 2 == 1
                let stars = String(repeating: "*", count: present ? count - width : count + width)
                let text = ns.substring(with: selection)
                editor.insertText(stars + text + stars, replacementRange: NSRange(location: selection.location - count, length: selection.length + count * 2))
                editor.setSelectedRange(NSRange(location: selection.location - count + (stars as NSString).length, length: selection.length))
                source = editor.rawSource; refreshVisualContext(); return
            }
        }
        switch command {
        case .heading(let level):
            let item = NSMenuItem(); item.tag = level; editor.formatHeading(item)
        case .bold: editor.formatBold(nil)
        case .italic: editor.formatItalic(nil)
        case .strike: editor.formatStrikethrough(nil)
        case .inlineCode: editor.formatCode(nil)
        case .bullet: editor.formatBulletedList(nil)
        case .numbered: editor.formatNumberedList(nil)
        case .task: editor.formatChecklist(nil)
        case .quote: editor.formatBlockQuote(nil)
        case .link: editor.formatLink(nil)
        case .table: editor.formatTable(nil)
        case .rule: editor.formatThematicBreak(nil)
        case .formula: editor.formatMathBlock(nil)
        case .underline, .highlight, .superscript, .subscriptText, .inlineMath, .keyboard, .comment,
             .wikilink, .footnote, .imageReference, .genericCode, .headingIncrease, .headingDecrease:
            _ = editor.perform(command.selector, with: nil)
        case .callout:
            let item = NSMenuItem(); item.representedObject = command.representedObject
            if let block = BlockParser.parse(editor.rawSource).first(where: { block in
                guard case .quoteRun = block.kind else { return false }
                return selection.location >= block.range.location && NSMaxRange(selection) <= NSMaxRange(block.range)
            }), let type = command.representedObject as? String {
                let header = ns.lineRange(for: NSRange(location: block.range.location, length: 0))
                let marker = ns.range(of: #"\[![A-Za-z]+\]"#, options: .regularExpression, range: header)
                if marker.location != NSNotFound {
                    let range = NSRange(location: marker.location + 2, length: marker.length - 3)
                    let length = (type as NSString).length
                    func remap(_ offset: Int) -> Int {
                        if offset <= range.location { return offset }
                        if offset >= NSMaxRange(range) { return offset + length - range.length }
                        return range.location + min(length, offset - range.location)
                    }
                    editor.insertText(type, replacementRange: range)
                    editor.setSelectedRange(NSRange(location: remap(selection.location), length: remap(NSMaxRange(selection)) - remap(selection.location)))
                } else { editor.formatCallout(item) }
            } else { editor.formatCallout(item) }
        case .attachImage: break // The file chooser is handled above.
        case .codeBlock, .textCode, .mermaid:
            let info: String, placeholder: String
            switch command {
            case .codeBlock: info = "{r}"; placeholder = L10n.string("# 在这里输入 R 代码")
            case .textCode: info = "text"; placeholder = L10n.string("在这里输入文本")
            case .mermaid(let id):
                guard let diagram = RecordMermaidDiagram.all.first(where: { $0.id == id }) else { return }
                info = "mermaid"; placeholder = diagram.source
            default: return
            }
            let selected = ns.substring(with: selection)
            let body = selected.isEmpty ? placeholder : selected
            let longestRun = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            let prefix = selection.location == 0 ? "" : "\n\n"
            let opening = prefix + fence + info + "\n"
            editor.insertText(opening + body + "\n" + fence + "\n\n", replacementRange: selection)
            editor.setSelectedRange(NSRange(location: selection.location + (opening as NSString).length, length: (body as NSString).length))
        }
        source = editor.rawSource
        refreshVisualContext()
    }
    /// Edmund skips empty lines when applying headings to a multi-line range.
    /// A caret on a blank line instead starts a heading ready for typing.
    private func formatBlankHeading(_ command: RecordVisualCommand, editor: EditorTextView) -> Bool {
        let level: Int
        switch command {
        case .heading(let value):
            guard (0...6).contains(value) else { return false }
            level = value
        case .headingIncrease: level = 1
        case .headingDecrease: level = 0
        default: return false
        }
        let selection = editor.selectedRange(), ns = editor.rawSource as NSString
        guard selection.length == 0 else { return false }
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: selection)
        let range = NSRange(location: start, length: contentsEnd - start)
        guard ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard level > 0 else { return true }
        let prefix = String(repeating: "#", count: level) + " "
        editor.insertText(prefix, replacementRange: range)
        editor.setSelectedRange(NSRange(location: start + prefix.utf16.count, length: 0))
        return true
    }
    private func prepareVisualFormatting() -> EditorTextView? {
        guard let editor = activeEditor as? EditorTextView, editor.isEditable else { return nil }
        if editor.hasMarkedText() { editor.unmarkText() }
        return editor
    }
    func canFormat(_ command: RecordVisualCommand) -> Bool {
        activeEditor?.isEditable == true
    }
    func captureVisualInsertion(for command: RecordVisualCommand) -> RecordVisualInsertionAnchor? {
        refreshVisualContext()
        guard let editor = prepareVisualFormatting() else { return nil }
        return RecordVisualInsertionAnchor(editor: editor)
    }
    private func restoreVisualInsertion(_ anchor: RecordVisualInsertionAnchor, command: RecordVisualCommand) -> EditorTextView? {
        guard let editor = prepareVisualFormatting(), editor === anchor.editor else { return nil }
        guard editor.rawSource == anchor.source else { notice = L10n.string("正文已变化，请重新打开插入窗口。"); return nil }
        editor.setSelectedRange(anchor.selection)
        editor.window?.makeFirstResponder(editor)
        return editor
    }
    @discardableResult
    func insertVisualTable(rows: Int, columns: Int, alignment: RecordVisualTableAlignment = .center,
                           anchor: RecordVisualInsertionAnchor) -> Bool {
        guard (1...100).contains(rows), (1...30).contains(columns),
              let editor = restoreVisualInsertion(anchor, command: .table) else { return false }
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |\n" }
        var table = row((1...columns).map { L10n.string("列 \(String($0))") })
        table += row(Array(repeating: alignment.separator, count: columns))
        table += String(repeating: row(Array(repeating: "", count: columns)), count: rows - 1)
        let ns = editor.rawSource as NSString
        let end = anchor.selection.length == 0 ? anchor.selection.location : NSMaxRange(anchor.selection) - 1
        let line = ns.lineRange(for: NSRange(location: end, length: 0))
        let blank = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let position = blank ? line.location : NSMaxRange(line)
        let prefix = blank ? "" : (ns.substring(with: line).hasSuffix("\n") ? "\n" : "\n\n")
        editor.insertText(prefix + table + "\n", replacementRange: NSRange(location: position, length: 0))
        editor.setSelectedRange(NSRange(location: position + (prefix as NSString).length + 2, length: 3))
        source = editor.rawSource; refreshVisualContext()
        return true
    }
    static func visualImageURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isNewline || $0 == "\0" || $0 == "<" || $0 == ">" }),
              let url = URL(string: text) else { return nil }
        if let scheme = url.scheme?.lowercased() {
            if scheme == "file" { return url.isFileURL ? url : nil }
            guard ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        } else if url.host != nil { return nil }
        return url
    }
    /// Plain relative file references work in both Edmund and Quarto. File
    /// URLs render in the editor but fail Quarto's self-contained HTML pass.
    static func visualImageDestination(_ url: URL, documentURL: URL?) -> String {
        let local = url.isFileURL || (url.scheme == nil && url.absoluteString.hasPrefix("/"))
        guard local, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              let documentURL else { return url.absoluteString }
        let file = (url.isFileURL ? url : URL(fileURLWithPath: url.path)).resolvingSymlinksInPath()
        let base = documentURL.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let parts = file.pathComponents
        var shared = 0
        while shared < min(base.count, parts.count), base[shared].utf8.elementsEqual(parts[shared].utf8) { shared += 1 }
        let path = (Array(repeating: "..", count: base.count - shared) + parts.dropFirst(shared)).joined(separator: "/")
        // Encode literal percent/hash/question marks as filename characters.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
    @discardableResult
    func insertVisualLinkedImage(url: String, description: String, anchor: RecordVisualInsertionAnchor) -> Bool {
        guard let url = Self.visualImageURL(url),
              let editor = restoreVisualInsertion(anchor, command: .imageReference) else { return false }
        let alt = description.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .components(separatedBy: .newlines).joined(separator: " ")
        let path = Self.visualImageDestination(url, documentURL: documentURL)
        editor.insertText("![\(alt)](<\(path)>)", replacementRange: anchor.selection)
        source = editor.rawSource; refreshVisualContext()
        return true
    }
    func importVisualImage() {
        guard let anchor = captureVisualInsertion(for: .attachImage) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .svg]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url,
                  let editor = self.restoreVisualInsertion(anchor, command: .attachImage) else { return }
            let path = Self.visualImageDestination(url, documentURL: self.documentURL)
            editor.window?.makeFirstResponder(editor)
            editor.insertText(L10n.string("![图片](<\(String(path))>)"), replacementRange: anchor.selection)
        }
    }
}

struct RecordVisualToolbarEntry: Identifiable {
    enum Kind { case command(RecordVisualTool), paragraph, code, list, table, image, math, mermaid, callout, other }
    let id: String
    let title: String
    let symbol: String
    let kind: Kind
    var estimatedWidth: CGFloat {
        switch kind { case .command: return 26; default: return 44 }
    }
    var commands: [RecordVisualTool] {
        let ids: [String]
        switch kind {
        case .command(let tool): return [tool]
        case .paragraph: return []
        case .code: ids = ["r-code", "text-code", "code"]
        case .list: ids = ["numbered", "bullet", "task"]
        case .table: ids = ["table"]
        case .image: ids = ["image", "image-reference"]
        case .math: ids = ["inline-math", "math"]
        case .mermaid:
            return RecordMermaidDiagram.all.map { .init(id: "mermaid-" + $0.id, title: $0.title,
                symbol: "point.3.connected.trianglepath.dotted", command: .mermaid($0.id)) }
        case .callout:
            return RecordVisualTool.callouts.map { .init(id: "callout-" + $0.0, title: $0.1,
                symbol: "text.bubble", command: .callout($0.0)) }
        case .other: return otherGroups.flatMap { $0 }
        }
        let tools = RecordVisualTool.common + RecordVisualTool.extended
        return ids.compactMap { id in tools.first { $0.id == id } }
    }
    var otherGroups: [[RecordVisualTool]] {
        let tools = RecordVisualTool.common + RecordVisualTool.extended
        return [["underline", "highlight", "superscript", "subscript", "keyboard"],
                ["wikilink", "footnote", "comment"], ["rule"]]
            .map { ids in ids.compactMap { id in tools.first { $0.id == id } } }
    }
    var reachableCommands: [RecordVisualCommand] {
        var result = commands.map(\.command)
        if case .paragraph = kind { result += (0...6).map { .heading($0) } }
        return result
    }
    private static let catalog = RecordLocalizedCatalog<[RecordVisualToolbarEntry]>()
    static var ordered: [Self] { catalog.value {
        let tools = RecordVisualTool.common + RecordVisualTool.extended
        func action(_ id: String) -> Self {
            let tool = tools.first { $0.id == id }!
            return Self(id: id, title: tool.title, symbol: tool.symbol, kind: .command(tool))
        }
        return [action("bold"), action("italic"), action("strike"), action("inline-code"), action("link"), action("quote"),
                Self(id: "paragraph", title: L10n.string("字体级别"), symbol: "textformat", kind: .paragraph),
                Self(id: "code-block", title: L10n.string("代码块"), symbol: "curlybraces", kind: .code),
                Self(id: "list", title: L10n.string("列表"), symbol: "list.bullet", kind: .list),
                Self(id: "table", title: L10n.string("表格"), symbol: "tablecells", kind: .table),
                Self(id: "image", title: L10n.string("图片插入"), symbol: "photo", kind: .image),
                Self(id: "math", title: L10n.string("公式"), symbol: "function", kind: .math),
                Self(id: "mermaid", title: L10n.string("Mermaid图形"), symbol: "point.3.connected.trianglepath.dotted", kind: .mermaid),
                Self(id: "callout", title: L10n.string("提示块"), symbol: "text.bubble", kind: .callout),
                Self(id: "other", title: L10n.string("其他"), symbol: "ellipsis.circle", kind: .other)]
    } }
}

enum RecordVisualToolbarGeometry {
    static let height: CGFloat = 40
    static let topGap: CGFloat = 12
    static let bottomGap: CGFloat = 12
    static let contentInset: CGFloat = topGap + height + bottomGap
    static func visibleCount(widths: [CGFloat], available: CGFloat, moreWidth: CGFloat = 28, spacing: CGFloat = 4) -> Int {
        let fullWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing
        if fullWidth <= available { return widths.count }
        var used: CGFloat = 0, count = 0
        for width in widths {
            let next = used + (count == 0 ? 0 : spacing) + width
            guard next + spacing + moreWidth <= available else { break }
            used = next; count += 1
        }
        return count
    }
}

struct RecordVisualToolbarWidths: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum RecordVisualPopover: Identifiable {
    case table(RecordVisualInsertionAnchor), image(RecordVisualInsertionAnchor)
    var id: String { switch self { case .table: return "table"; case .image: return "image" } }
}

struct RecordVisualTableInsertion: View {
    @ObservedObject var model: RecordLayoutModel
    let anchor: RecordVisualInsertionAnchor
    let dismiss: () -> Void
    @State private var rows = "3"
    @State private var columns = "3"
    @State private var alignment = RecordVisualTableAlignment.center
    private var valid: Bool { (1...100).contains(Int(rows) ?? 0) && (1...30).contains(Int(columns) ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.string("行"))
                TextField(L10n.string("行数"), text: $rows).frame(width: 36).help(L10n.string("行数包含表头"))
                    .accessibilityIdentifier("visual-table-rows")
                Spacer(minLength: 0)
                Text(L10n.string("列"))
                TextField(L10n.string("列数"), text: $columns).frame(width: 36).accessibilityIdentifier("visual-table-columns")
            }
            HStack(spacing: 6) {
                Text(L10n.string("对齐"))
                Spacer(minLength: 0)
                Picker(L10n.string("对齐"), selection: $alignment) {
                    ForEach(RecordVisualTableAlignment.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().accessibilityIdentifier("visual-table-alignment")
            }
            if !valid { Text(L10n.string("行数为1–100，列数为1–30。")).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                Text(L10n.string("行数含表头")).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(L10n.string("插入")) {
                    if model.insertVisualTable(rows: Int(rows) ?? 0, columns: Int(columns) ?? 0,
                                               alignment: alignment, anchor: anchor) { dismiss() }
                }.disabled(!valid).keyboardShortcut(.defaultAction).accessibilityIdentifier("visual-table-insert")
            }
        }.font(.system(size: 12)).controlSize(.small).textFieldStyle(.roundedBorder)
            .tint(.primary).frame(width: 146).padding(8).onExitCommand(perform: dismiss)
    }
}

struct RecordVisualImageInsertion: View {
    @ObservedObject var model: RecordLayoutModel
    let anchor: RecordVisualInsertionAnchor
    let dismiss: () -> Void
    @State private var url = ""
    @State private var description = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("插入图片链接")).font(.headline)
            TextField(L10n.string("网址或文件路径，例如 images/plot.png"), text: $url).accessibilityIdentifier("visual-image-url")
            TextField(L10n.string("图片说明（可选）"), text: $description).accessibilityIdentifier("visual-image-description")
            HStack {
                Spacer()
                Button(L10n.string("取消"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(L10n.string("插入")) {
                    if model.insertVisualLinkedImage(url: url, description: description, anchor: anchor) { dismiss() }
                }.disabled(RecordLayoutModel.visualImageURL(url) == nil)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("visual-image-insert")
            }
        }.textFieldStyle(.roundedBorder).padding(16).frame(width: 330)
    }
}
