import Foundation
import EdmundCore

/// Display-only indexing using the component's public block and syntax parsers.
/// The execution FenceScanner remains separate and unchanged. Reparse a fence
/// only when its exact contents change; always remap offsets after prose edits.
@MainActor final class RecordFencePresentationCache {
    struct Fence {
        let language: String?
        let fullRange: NSRange
        let contentRange: NSRange
        let delimiterRanges: [NSRange]
    }
    private var source: String?
    private var indexed: [Fence] = []
    private var parsed: [Data: [SyntaxHighlighter.Span]] = [:]
    func blocks(in text: String) -> [Fence] {
        if let source, source.utf8.elementsEqual(text.utf8) { return indexed }
        var result: [Fence] = []
        for block in BlockParser.parse(text) where block.kind == .fence {
            let spans: [SyntaxHighlighter.Span]
            if let hit = parsed[Data(block.content.utf8)] { spans = hit }
            else {
                spans = SyntaxHighlighter.parse(block.content)
                if parsed.count >= 256 { parsed.removeAll(keepingCapacity: true) }
                parsed[Data(block.content.utf8)] = spans
            }
            func shifted(_ range: NSRange) -> NSRange {
                NSRange(location: block.range.location + range.location, length: range.length)
            }
            for span in spans {
                guard case .codeBlock(let language) = span.kind else { continue }
                result.append(Fence(language: language, fullRange: shifted(span.fullRange),
                    contentRange: shifted(span.contentRange), delimiterRanges: span.delimiterRanges.map(shifted)))
            }
        }
        source = text; indexed = result
        return result
    }
}
