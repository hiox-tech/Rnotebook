import Foundation

/// A bounded, non-executing YAML subset for notebook scheduling, not a general
/// YAML loader. Unsupported structures remain explicit values, never defaults.
enum NotebookYAML {
    indirect enum Value: Sendable {
        case boolean(Bool), scalar(String), mapping([(String, Value)]), sequence, unsupported
    }
    private struct Line { let indent: Int; let text: String }
    static func parse(_ source: String) -> Value {
        let lines = source.components(separatedBy: .newlines).compactMap { raw -> Line? in
            let text = commentless(raw).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if raw.prefix(while: { $0.isWhitespace }).contains("\t") { return Line(indent: -1, text: text) }
            return Line(indent: raw.prefix(while: { $0 == " " }).count, text: text)
        }
        guard !lines.isEmpty else { return .mapping([]) }
        if lines.count == 1, lines[0].text.hasPrefix("{") { return inline(lines[0].text) }
        guard lines[0].indent == 0 else { return .unsupported }
        var index = 0
        let result = mapping(lines, at: &index, indent: 0, depth: 0)
        return index == lines.count ? result : .unsupported
    }
    private static func mapping(_ lines: [Line], at index: inout Int, indent: Int, depth: Int) -> Value {
        guard depth < 32 else { index = lines.count; return .unsupported }
        var fields: [(String, Value)] = []
        while index < lines.count, lines[index].indent == indent {
            let line = lines[index].text
            guard let (key, raw) = pair(line, separator: ":"), !key.isEmpty, !key.hasPrefix("?"), !key.hasPrefix("-") else { return .unsupported }
            index += 1
            var value: Value
            if raw.isEmpty {
                if index < lines.count, lines[index].indent > indent {
                    if lines[index].text.hasPrefix("-") {
                        while index < lines.count, lines[index].indent > indent { index += 1 }
                        value = .sequence
                    } else { value = mapping(lines, at: &index, indent: lines[index].indent, depth: depth + 1) }
                } else if index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("- ") {
                    // YAML permits indentless sequences as a mapping value.
                    while index < lines.count, lines[index].indent > indent || (lines[index].indent == indent && lines[index].text.hasPrefix("- ")) { index += 1 }
                    value = .sequence
                } else { value = .unsupported }
            } else if raw.hasPrefix("|") || raw.hasPrefix(">") {
                while index < lines.count, lines[index].indent > indent { index += 1 }
                value = .unsupported
            } else {
                value = inline(raw)
                // A continuation cannot silently change a scalar control value.
                if index < lines.count, lines[index].indent > indent {
                    while index < lines.count, lines[index].indent > indent { index += 1 }
                    value = .unsupported
                }
            }
            fields.append((unquote(key), value))
        }
        return .mapping(fields)
    }
    static func inline(_ raw: String, depth: Int = 0) -> Value {
        let text = commentless(raw).trimmingCharacters(in: .whitespaces)
        guard depth < 32, !text.isEmpty else { return .unsupported }
        if text.hasPrefix("{") {
            guard text.hasSuffix("}"), let pieces = split(String(text.dropFirst().dropLast()), on: ",") else { return .unsupported }
            var fields: [(String, Value)] = []
            for piece in pieces where !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let (key, value) = pair(piece, separator: ":"), !key.isEmpty else { return .unsupported }
                fields.append((unquote(key), inline(value, depth: depth + 1)))
            }
            return .mapping(fields)
        }
        if text.hasPrefix("[") { return text.hasSuffix("]") && split(text, on: ",") != nil ? .sequence : .unsupported }
        if ["!", "*", "&"].contains(where: { text.hasPrefix($0) }) || text == "<<" { return .unsupported }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            guard split(text, on: ",") != nil, text.last == text.first, text.count >= 2 else { return .unsupported }
            return .scalar(unquote(text))
        }
        if ["true", "false"].contains(text.lowercased()) { return .boolean(text.lowercased() == "true") }
        return .scalar(text)
    }
    static func pair(_ raw: String, separator: Character, rQuotes: Bool = false) -> (String, String)? {
        guard let pieces = split(raw, on: separator, rQuotes: rQuotes), pieces.count >= 2 else { return nil }
        let key = pieces[0].trimmingCharacters(in: .whitespaces)
        let value = pieces.dropFirst().joined(separator: String(separator)).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
    /// Splits only at outer depth; supports R argument parentheses as well as
    /// YAML flow mappings, quotes, escaped quotes and comments.
    static func split(_ text: String, on separator: Character, rQuotes: Bool = false) -> [String]? {
        var pieces: [String] = [], current = "", stack: [Character] = []
        var quote: Character?, escaped = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if escaped { escaped = false }
                else if c == "\\" && (q != "'" || rQuotes) { escaped = true }
                else if c == q {
                    if q == "'", i + 1 < chars.count, chars[i + 1] == "'" { current.append(chars[i + 1]); i += 1 }
                    else { quote = nil }
                }
            } else if c == "\"" || c == "'" || c == "`" { quote = c; current.append(c) }
            else if ["{", "[", "("].contains(c) { stack.append(c); current.append(c) }
            else if let opener: Character = ["}":"{", "]":"[", ")":"("][c] {
                guard stack.popLast() == opener else { return nil }; current.append(c)
            } else if c == separator && stack.isEmpty { pieces.append(current); current = "" }
            else { current.append(c) }
            i += 1
        }
        guard quote == nil, stack.isEmpty else { return nil }
        return pieces + [current]
    }
    static func commentless(_ text: String) -> String {
        var quote: Character?, escaped = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q {
                    if q == "'", i + 1 < chars.count, chars[i + 1] == "'" { i += 1 } else { quote = nil }
                }
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "#" && (i == 0 || chars[i - 1].isWhitespace) { return String(chars.prefix(i)) }
            i += 1
        }
        return text
    }
    static func unquote(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\""), let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String { return value }
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 { return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return text
    }
}
