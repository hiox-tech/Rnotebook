import Foundation

/// Shared physical Markdown ranges, with opaque literal contexts and local
/// structural refusals. It never evaluates options or rewrites user source.
struct FenceScanner {
    private struct Line { let text: String; let start: Int; let end: Int }
    private struct Fence { let marker: Character; let count: Int; let info: String }
    private struct Open {
        let fence: Fence; let header: NotebookChunkHeader
        let start: Int; let body: Int; let prefix: String; let nested: Bool
    }
    private struct Opaque {
        let start: Int; let close: String; let name: String; var depth = 1
        var rawTag: String?
        var htmlComment = false
        var pendingTag = ""
    }

    func scan(_ text: String) -> CellIndex {
        let ns = text as NSString
        var lines: [Line] = [], offset = 0
        while offset < ns.length {
            var start = 0, end = 0, contentEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
            lines.append(.init(text: ns.substring(with: NSRange(location: start, length: contentEnd - start)), start: start, end: end))
            offset = end
        }
        var cells: [CellSnapshot] = [], fences: [NotebookFence] = [], problems: [NotebookStructureProblem] = []
        var defaults = NotebookExecutionOptions()
        var open: Open?, opaque: Opaque?, yamlStart: Int?, yamlBody = 0
        var divs: [Int] = [], listIndent: Int?
        func problem(_ start: Int, _ end: Int, _ message: String) {
            problems.append(.init(range: NSRange(location: start, length: end - start), message: message))
        }
        func finish(_ current: Open, bodyEnd: Int, end: Int, closed: Bool) {
            let range = NSRange(location: current.start, length: end - current.start)
            let bodyRange = NSRange(location: current.body, length: bodyEnd - current.body)
            fences.append(.init(range: range, bodyRange: bodyRange, language: current.header.language,
                                prefix: current.prefix, closed: closed, executable: current.header.executable))
            if !closed { problem(current.start, end, L10n.string("Markdown 代码围栏未闭合。")) }
            if current.nested && current.header.executable && current.header.language == "r" { problem(current.start, end, L10n.string("列表或引用中的嵌套围栏不支持逐块定位，请在 Quarto 中完整渲染。")) }
            guard current.header.executable else { return }
            let source = ns.substring(with: bodyRange)
            var options = NotebookExecutionOptions()
            options.apply(current.header.entries, origin: L10n.string("块头"))
            var blockIssues = current.header.issues
            if !options.issues.isEmpty, current.header.entries.contains(where: { $0.0 == "label" }) {
                blockIssues += options.issues.filter { $0.contains("label") }
            }
            var optionLines: [String] = [], optionsOpen = true
            for raw in source.components(separatedBy: .newlines) {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("#|") {
                    if optionsOpen { optionLines.append(String(trimmed.dropFirst(2)).replacingOccurrences(of: #"^ ?"#, with: "", options: .regularExpression)) }
                    else if let pair = NotebookYAML.pair(String(trimmed.dropFirst(2)), separator: ":"), ["label", "eval", "error"].contains(pair.0) {
                        blockIssues.append(L10n.string("执行选项必须位于代码块开头。"))
                    }
                } else { optionsOpen = false }
            }
            if !optionLines.isEmpty {
                if case .mapping(let entries) = NotebookYAML.parse(optionLines.joined(separator: "\n")) {
                    let previousIssueCount = options.issues.count
                    options.apply(entries, origin: "#|")
                    blockIssues += options.issues.dropFirst(previousIssueCount).filter { $0.contains("label") }
                } else { options.issues.append(L10n.string("无法静态读取块选项，请使用 Quarto 渲染或手动运行。")) }
            }
            if !closed { blockIssues.append(L10n.string("Markdown 代码围栏未闭合。")) }
            if current.nested { blockIssues.append(L10n.string("嵌套代码块的位置有歧义。")) }
            if current.header.language != "r" { blockIssues.append(L10n.string("当前仅支持 R 代码块交互执行。")) }
            if current.header.language == "r" {
                for message in current.header.issues { problem(current.start, end, message) }
                for message in blockIssues where message.contains("label") || message == L10n.string("执行选项必须位于代码块开头。") { problem(current.start, end, message) }
            }
            cells.append(.init(id: options.label.map { "label:" + $0 } ?? "source:\(current.start)", label: options.label, languageID: current.header.language,
                source: source, sourceHash: DocumentRevision(text: ns.substring(with: range)).rawValue,
                range: range, sourceRange: bodyRange, issues: blockIssues, options: options))
        }

        for (number, line) in lines.enumerated() {
            var raw = line.text
            if number == 0 && raw.hasPrefix("\u{feff}") { raw.removeFirst() }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " }.count
            if let start = yamlStart {
                if indent == 0, !raw.hasPrefix("\t"), trimmed == "---" || trimmed == "..." {
                    defaults = .document(ns.substring(with: NSRange(location: yamlBody, length: line.start - yamlBody)))
                    if start != 0 { problem(start, line.end, L10n.string("YAML 起始标记必须位于行首。")) }
                    yamlStart = nil
                }
                continue
            }
            if number == 0, trimmed == "---" {
                yamlStart = indent == 0 && !raw.hasPrefix("\t") ? 0 : line.start + 1; yamlBody = line.end; continue
            }
            if let current = open {
                var closing = raw
                if current.prefix.contains(">") { closing = quoteContent(raw).body }
                if isClosing(closing, fence: current.fence, nested: current.nested) {
                    finish(current, bodyEnd: line.start, end: line.end, closed: true); open = nil
                }
                continue
            }
            if var current = opaque {
                if current.name.hasPrefix("html:") {
                    advanceHTML(raw, context: &current)
                    opaque = current.depth <= 0 && current.pendingTag.isEmpty ? nil : current
                } else if current.name.hasPrefix("tex:") {
                    let environment = String(current.name.dropFirst(4))
                    current.depth += raw.components(separatedBy: "\\begin{" + environment + "}").count - raw.components(separatedBy: current.close).count
                    opaque = current.depth <= 0 ? nil : current
                } else if raw.contains(current.close) { opaque = nil }
                continue
            }
            let literalFree = withoutInlineCode(raw)
            if let comment = literalFree.range(of: "<!--", options: .backwards) {
                if !literalFree[comment.upperBound...].contains("-->") { opaque = .init(start: line.start, close: "-->", name: "comment") }
                continue
            }
            if literalFree.contains("$$") {
                let markers = (try? NSRegularExpression(pattern: #"(?<!\\)\$\$"#).numberOfMatches(in: literalFree, range: NSRange(location: 0, length: literalFree.utf16.count))) ?? 0
                if markers % 2 != 0 { opaque = .init(start: line.start, close: "$$", name: "math") }
                continue
            }
            if trimmed.hasPrefix("\\[") {
                if !trimmed.dropFirst(2).contains("\\]") { opaque = .init(start: line.start, close: "\\]", name: "math") }
                continue
            }
            if let environment = texEnvironment(trimmed) {
                let end = "\\end{" + environment + "}"
                let depth = raw.components(separatedBy: "\\begin{" + environment + "}").count - raw.components(separatedBy: end).count
                if depth > 0 { opaque = .init(start: line.start, close: end, name: "tex:" + environment, depth: depth) }
                continue
            }
            if let tag = htmlTag(trimmed) {
                var context = Opaque(start: line.start, close: "</" + tag + ">", name: "html:" + tag, depth: 0)
                advanceHTML(raw, context: &context)
                if context.depth > 0 || !context.pendingTag.isEmpty { opaque = context }
                continue
            }
            if trimmed.hasPrefix("<![CDATA[") {
                if !trimmed.contains("]]>") { opaque = .init(start: line.start, close: "]]>", name: "html") }; continue
            }
            if trimmed.hasPrefix("<?") {
                if !trimmed.contains("?>") { opaque = .init(start: line.start, close: "?>", name: "html") }; continue
            }
            if trimmed.hasPrefix(":::") {
                let count = trimmed.prefix { $0 == ":" }.count
                if trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    if !divs.isEmpty { divs.removeLast() }
                    else { problem(line.start, line.end, L10n.string("容器结束标记没有对应的开始。")) }
                } else { divs.append(line.start) }
                continue
            }
            let isList = listMarker(trimmed)
            if isList { listIndent = indent }
            else if !trimmed.isEmpty, let active = listIndent, indent <= active { listIndent = nil }
            let quote = quoteContent(raw)
            let nested = quote.prefix.contains(">") || (listIndent != nil && (isList || indent > listIndent!))
            var body = quote.prefix.isEmpty ? raw : quote.body
            if isList { body = body.replacingOccurrences(of: #"^\s*(?:[-+*:]|[0-9]+[.)])\s+"#, with: "", options: .regularExpression) }
            guard (indent <= 3 || nested), !raw.hasPrefix("\t") || nested, let fence = opening(body) else { continue }
            let prefix = quote.prefix.isEmpty ? String(raw.prefix { $0 == " " }) : quote.prefix
            open = .init(fence: fence, header: .init(fence.info), start: line.start, body: line.end, prefix: prefix, nested: nested)
        }
        if let current = open { finish(current, bodyEnd: ns.length, end: ns.length, closed: false) }
        if let start = yamlStart { problem(max(0, start - 1), ns.length, L10n.string("YAML front matter 未闭合。")) }
        if let current = opaque { problem(current.start, ns.length, current.name == "comment" ? L10n.string("HTML 注释未闭合。") : L10n.string("公式或 HTML 区域未闭合，后续内容不能可靠定位。")) }
        for start in divs { problem(start, ns.length, L10n.string("Quarto 容器未闭合。")) }
        let labels = Dictionary(grouping: cells.compactMap(\.label), by: { $0 })
        for i in cells.indices {
            if let label = cells[i].label, (labels[label]?.count ?? 0) > 1 { problem(cells[i].range.location, cells[i].range.upperBound, L10n.string("重复的代码块 label：") + label) }
        }
        for i in cells.indices {
            cells[i].issues = Array(Set(cells[i].issues + problems.filter { NSIntersectionRange($0.range, cells[i].range).length > 0 }.map(\.message))).sorted()
        }
        return CellIndex(cells: cells, issues: Array(Set(problems.map(\.message))).sorted(), fences: fences, problems: problems, defaults: defaults)
    }

    private func opening(_ raw: String) -> Fence? {
        let body = raw.drop { $0 == " " }
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let count = body.prefix { $0 == marker }.count
        guard count >= 3 else { return nil }
        let info = String(body.dropFirst(count))
        if marker == "`", info.contains("`") { return nil }
        return .init(marker: marker, count: count, info: info)
    }
    private func isClosing(_ raw: String, fence: Fence, nested: Bool) -> Bool {
        guard nested || (!raw.hasPrefix("\t") && raw.prefix { $0 == " " }.count <= 3) else { return false }
        let body = raw.trimmingCharacters(in: .whitespaces)
        let count = body.prefix { $0 == fence.marker }.count
        return count >= fence.count && body.dropFirst(count).allSatisfy(\.isWhitespace)
    }
    private func quoteContent(_ raw: String) -> (prefix: String, body: String) {
        guard let range = raw.range(of: #"^[ ]{0,3}(?:>[ \t]*)+"#, options: .regularExpression) else { return ("", raw) }
        return (String(raw[range]), String(raw[range.upperBound...]))
    }
    private func texEnvironment(_ raw: String) -> String? {
        guard let range = raw.range(of: #"^\\begin\{[A-Za-z][A-Za-z0-9*]*\}"#, options: .regularExpression) else { return nil }
        return String(String(raw[range]).replacingOccurrences(of: "\\begin{", with: "").dropLast())
    }
    private func htmlTag(_ text: String) -> String? {
        guard let range = text.range(of: #"^<[A-Za-z][A-Za-z0-9:_-]*(?=\s|>|$)"#, options: .regularExpression), !text.hasSuffix("/>") else { return nil }
        let tag = String(text[range].dropFirst()).lowercased()
        return ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"].contains(tag) ? nil : tag
    }
    private func advanceHTML(_ text: String, context: inout Opaque) {
        let tag = String(context.name.dropFirst(5)), ns = ((context.pendingTag.isEmpty ? "" : context.pendingTag + "\n") + text) as NSString
        context.pendingTag = ""
        var start = 0
        while start < ns.length {
            let remaining = NSRange(location: start, length: ns.length - start)
            if context.htmlComment {
                let end = ns.range(of: "-->", range: remaining)
                guard end.location != NSNotFound else { return }
                context.htmlComment = false; start = end.upperBound; continue
            }
            if let raw = context.rawTag {
                let end = ns.range(of: "</" + raw + #"\s*>"#, options: [.regularExpression, .caseInsensitive], range: remaining)
                guard end.location != NSNotFound else { return }
                if raw == tag { context.depth -= 1 }
                context.rawTag = nil; start = end.upperBound; continue
            }
            let token = ns.range(of: #"<!--|</?[A-Za-z][A-Za-z0-9:_-]*(?:"[^"]*"|'[^']*'|[^'">])*>"#, options: .regularExpression, range: remaining)
            guard token.location != NSNotFound else {
                let partial = ns.range(of: #"</?[A-Za-z][^>]*$"#, options: .regularExpression, range: remaining)
                if partial.location != NSNotFound {
                    if partial.length <= 65536 { context.pendingTag = ns.substring(with: partial) }
                    else { context.rawTag = "unclosed-tag"; context.depth = max(1, context.depth) }
                }
                return
            }
            let raw = ns.substring(with: token).lowercased()
            start = token.upperBound
            if raw == "<!--" { context.htmlComment = true; continue }
            let closing = raw.hasPrefix("</")
            let name = String(raw.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" || $0 == "_" })
            if name == tag { context.depth += closing ? -1 : raw.hasSuffix("/>") ? 0 : 1 }
            if !closing && !raw.hasSuffix("/>") && ["pre", "script", "style", "code", "textarea"].contains(name) { context.rawTag = name }
            if context.depth <= 0 { return }
        }
    }
    private func withoutInlineCode(_ text: String) -> String {
        var result = "", marker = 0
        let chars = Array(text); var i = 0
        while i < chars.count {
            if chars[i] == "`" {
                let start = i
                while i < chars.count, chars[i] == "`" { i += 1 }
                let count = i - start
                if marker == 0 { marker = count } else if marker == count { marker = 0 }
            } else { if marker == 0 { result.append(chars[i]) }; i += 1 }
        }
        return result
    }
    private func listMarker(_ text: String) -> Bool { text.range(of: #"^(?:[-+*:]|[0-9]+[.)])\s+"#, options: .regularExpression) != nil }
    static func validLabel(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII && first.isLetter else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
