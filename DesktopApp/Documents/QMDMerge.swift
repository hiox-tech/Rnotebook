import Foundation

/// A line-based three-way merge. Conflicts never introduce markers into QMD.
enum QMDMerge {
    struct Edit: Equatable {
        let range: Range<Int>
        let replacement: [String]
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.range == rhs.range && lhs.replacement.elementsEqual(rhs.replacement, by: DocumentRevision.sameSource)
        }
    }
    static func edits(from original: [String], to updated: [String]) -> [Edit] {
        let prefix = zip(original, updated).prefix { DocumentRevision.sameSource($0, $1) }.count
        let suffix = zip(original.dropFirst(prefix).reversed(), updated.dropFirst(prefix).reversed())
            .prefix { DocumentRevision.sameSource($0, $1) }.count
        let base = Array(original[prefix..<(original.count - suffix)])
        let next = Array(updated[prefix..<(updated.count - suffix)])
        // External reconciliation runs on the main actor. Bound adversarial
        // whole-document rewrites; a coarse edit may require review, but never
        // guesses a merge or freezes the editor with an unbounded Myers diff.
        if base.count > 4_000_000 / max(1, next.count) {
            return [Edit(range: prefix..<(prefix + base.count), replacement: next)]
        }
        let difference = next.difference(from: base, by: DocumentRevision.sameSource)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Edit] = [], i = 0, j = 0
        while i < base.count || j < next.count {
            let start = i
            var replacement: [String] = []
            while i < base.count && removed.contains(i) { i += 1 }
            while j < next.count && inserted.contains(j) { replacement.append(next[j]); j += 1 }
            if start != i || !replacement.isEmpty { result.append(Edit(range: (prefix + start)..<(prefix + i), replacement: replacement)) }
            if i < base.count && j < next.count { i += 1; j += 1 }
        }
        return result
    }
    static func merge(base: String, editor: String, external: String) -> String? {
        if DocumentRevision.sameSource(editor, external) || DocumentRevision.sameSource(external, base) { return editor }
        if DocumentRevision.sameSource(editor, base) { return external }
        let lines = base.components(separatedBy: "\n")
        let local = edits(from: lines, to: editor.components(separatedBy: "\n"))
        let remote = edits(from: lines, to: external.components(separatedBy: "\n"))
        for a in local {
            for b in remote where a != b {
                if a.range.isEmpty || b.range.isEmpty {
                    let insertion = a.range.isEmpty ? a.range.lowerBound : b.range.lowerBound
                    let other = a.range.isEmpty ? b.range : a.range
                    if insertion >= other.lowerBound && insertion <= other.upperBound { return nil }
                } else if a.range.overlaps(b.range) { return nil }
            }
        }
        var combined = local
        for edit in remote where !combined.contains(edit) { combined.append(edit) }
        var result = lines
        for edit in combined.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result.joined(separator: "\n")
    }
}
