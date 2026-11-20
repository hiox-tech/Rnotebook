import Foundation

/// Native semantic categories, independent of any JavaScript/CSS class names.
enum RecordSyntaxKind: String {
    case plain, comment, string, number, keyword, literal, heading, strong
    case emphasis, quote, link, bullet, function, builtin, code
}

/// Parsers and incremental trees live on the editor's main actor. No R process.
@MainActor final class RecordRTokenSource {
    struct Token {
        let range: NSRange
        let kind: RecordSyntaxKind
        var scope: String { kind.rawValue } // NSTextStorage stores stable scalar values.
    }
    let version = "tree-sitter 0.25.10"
    private final class Parser: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { rn_tree_destroy(pointer) }
    }
    private var parsers: [String: Parser] = [:]
    init(bundle: Bundle = Bundle(for: RecordRTokenSource.self)) throws {
        for (name, language) in [("r", 0), ("markdown", 1), ("markdown_inline", 2)] {
            guard let url = bundle.url(forResource: name, withExtension: "scm", subdirectory: "LanguageTools") else { throw CocoaError(.fileNoSuchFile) }
            let query = try String(contentsOf: url, encoding: .utf8)
            guard let parser = query.withCString({ rn_tree_create(Int32(language), $0, UInt32(query.utf8.count)) }) else { throw CocoaError(.coderInvalidValue) }
            parsers[name] = Parser(parser)
        }
    }
    private func captures(_ code: String, language: String) -> [(NSRange, String, Int)]? {
        guard let parser = parsers[language], code.utf8.count <= Int(UInt32.max) else { return nil }
        var count: UInt32 = 0
        let output = code.withCString { rn_tree_highlight(parser.pointer, $0, UInt32(code.utf8.count), &count) }
        guard let output else { return code.isEmpty ? [] : nil }
        defer { rn_tree_free(output) }
        // Map UTF-8 node boundaries to UTF-16 NSTextView ranges, including emoji.
        var boundaries = [Int: Int](); var byte = 0; var utf16 = 0
        boundaries[0] = 0
        for scalar in code.unicodeScalars {
            byte += scalar.utf8.count; utf16 += scalar.utf16.count; boundaries[byte] = utf16
        }
        return UnsafeBufferPointer(start: output, count: Int(count)).compactMap { capture in
            guard let start = boundaries[Int(capture.start)], let end = boundaries[Int(capture.end)], end > start else { return nil }
            return (NSRange(location: start, length: end-start), String(cString: capture.scope), Int(capture.pattern))
        }
    }
    func tokens(_ code: String, language: String = "r") -> [Token]? {
        guard var spans = captures(code, language: language) else { return nil }
        if language == "markdown" {
            let inlines = spans.filter { $0.1 == "rn.inline" }
            spans.removeAll { $0.1 == "rn.inline" }
            let ns = code as NSString
            for (range, _, _) in inlines {
                guard let nested = captures(ns.substring(with: range), language: "markdown_inline") else { continue }
                spans += nested.map { (NSRange(location: range.location+$0.0.location, length: $0.0.length), $0.1, $0.2+1000) }
            }
        }
        var scopes = [RecordSyntaxKind?](repeating: nil, count: code.utf16.count)
        for (range, scope, _) in spans.sorted(by: { $0.2 < $1.2 }) {
            guard range.upperBound <= scopes.count, scope != "none", scope != "error" else { continue }
            let mapped = Self.paletteScope(scope)
            for index in range.location..<range.upperBound { scopes[index] = mapped }
        }
        var tokens: [Token] = []; var start = 0
        while start < scopes.count {
            var end = start+1
            while end < scopes.count, scopes[end] == scopes[start] { end += 1 }
            if let kind = scopes[start] { tokens.append(Token(range: NSRange(location: start, length: end-start), kind: kind)) }
            start = end
        }
        return tokens
    }
    private static func paletteScope(_ scope: String) -> RecordSyntaxKind {
        if scope.hasPrefix("comment") { return .comment }
        if scope.hasPrefix("string") { return .string }
        if scope == "number" { return .number }
        if scope == "boolean" || scope.hasPrefix("constant") { return .literal }
        if scope.hasPrefix("keyword") || ["conditional", "repeat"].contains(scope) { return .keyword }
        if scope == "function" { return .function }
        if scope == "text.title" { return .heading }
        if scope == "text.strong" { return .strong }
        if scope == "text.emphasis" { return .emphasis }
        if scope == "text.literal" { return .code }
        if ["text.uri", "text.reference"].contains(scope) { return .link }
        if scope == "punctuation.special" { return .keyword }
        return .plain
    }
}
