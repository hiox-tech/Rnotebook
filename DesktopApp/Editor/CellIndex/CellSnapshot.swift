import Foundation

struct CellSnapshot: Identifiable, Sendable {
    let id: String
    let label: String?
    let languageID: String
    let source: String
    let sourceHash: String
    let range: NSRange
    let sourceRange: NSRange
    var issues: [String]
    var options = NotebookExecutionOptions()
    var canRun: Bool { languageID == "r" && issues.isEmpty }
}

struct CellIndex: Sendable {
    var cells: [CellSnapshot]
    let issues: [String]
    var fences: [NotebookFence] = []
    var problems: [NotebookStructureProblem] = []
    var defaults = NotebookExecutionOptions()
    var canAppend: Bool { issues.isEmpty && cells.allSatisfy { $0.issues.isEmpty || $0.languageID != "r" } }

    func cell(atUTF16Location location: Int) -> CellSnapshot? {
        cells.first { NSLocationInRange(location, $0.range) }
    }
}

struct NotebookStructureProblem: Sendable {
    let range: NSRange
    let message: String
}

/// Shared physical source ranges. Display/language-service support is distinct
/// from permission to execute; no consumer rescans examples as executable R.
struct NotebookFence: Sendable {
    let range: NSRange
    let bodyRange: NSRange
    let language: String
    let prefix: String
    let closed: Bool
    let executable: Bool
}

/// Associates output with the exact current source without changing the document.
struct CellSourceReference: Sendable {
    let cellID: String
    let sourceHash: String
    func isCurrent(in index: CellIndex) -> Bool {
        index.cells.contains { $0.id == cellID && $0.sourceHash == sourceHash && $0.canRun }
    }
}
