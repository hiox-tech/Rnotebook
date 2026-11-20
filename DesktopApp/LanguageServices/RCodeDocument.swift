import Foundation

/// QMD remains authoritative. Virtual R preserves UTF-16 positions and line endings.
struct RCodeDocument: Sendable {
    struct Block: Sendable {
        let fullRange: NSRange
        let bodyRange: NSRange
        let prefix: String
        let closed: Bool
    }
    let source: String
    let blocks: [Block]
    init(_ source: String) {
        self.source = source
        blocks = FenceScanner().scan(source).fences.filter { $0.language == "r" }.map {
            Block(fullRange: $0.range, bodyRange: $0.bodyRange, prefix: $0.prefix, closed: $0.closed)
        }
    }

    func block(at offset: Int) -> Block? {
        blocks.first { offset >= $0.bodyRange.location && (offset < $0.bodyRange.upperBound || (!$0.closed && offset == $0.bodyRange.upperBound)) }
    }
    var virtualSource: String {
        let units = source.utf16.map { $0 == 10 || $0 == 13 ? $0 : UInt16(32) }
        let result = NSMutableString(string: String(decoding: units, as: UTF16.self))
        let ns = source as NSString
        for block in blocks {
            var body = ns.substring(with: block.bodyRange)
            if block.prefix.contains(">") {
                body = body.components(separatedBy: "\n").map { line in
                    line.hasPrefix(block.prefix) ? String(repeating: " ", count: block.prefix.utf16.count) + String(line.dropFirst(block.prefix.count)) : line
                }.joined(separator: "\n")
            }
            result.replaceCharacters(in: block.bodyRange, with: body)
        }
        return result as String
    }
    func position(at offset: Int) -> [String: Int] {
        let text = (source as NSString).substring(to: min(max(0, offset), source.utf16.count))
        let parts = text.components(separatedBy: "\n")
        return ["line": parts.count-1, "character": parts.last?.utf16.count ?? 0]
    }
    func offset(line: Int, character: Int) -> Int? {
        let lines = source.components(separatedBy: "\n")
        guard line >= 0, line < lines.count, character >= 0, character <= lines[line].utf16.count else { return nil }
        let offset = lines.prefix(line).reduce(0) { $0 + $1.utf16.count+1 } + character
        let units = Array(source.utf16)
        if offset > 0, offset < units.count, (0xDC00...0xDFFF).contains(units[offset]), (0xD800...0xDBFF).contains(units[offset-1]) { return nil }
        return offset
    }
    func prefix(at offset: Int) -> (String, NSRange) {
        let before = (source as NSString).substring(to: offset)
        let range = (before as NSString).range(of: #"[\p{L}\p{N}._]*$"#, options: .regularExpression)
        return range.location == NSNotFound ? ("", NSRange(location: offset, length: 0)) : ((before as NSString).substring(with: range), range)
    }
}
