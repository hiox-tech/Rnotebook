import AppKit
import SwiftUI
import Combine

extension RecordLayoutModel {
    private func committedSource() -> Bool {
        guard activeEditor?.hasMarkedText() != true,
              activeEditor.map({ $0.string.utf8.elementsEqual(source.utf8) }) ?? true else {
            notice = L10n.string("请先完成当前输入，再运行 R。"); return false
        }
        return true
    }
    /// Prepare the entire requested range before starting R or asking to save.
    func notebookJobs(blockID: String? = nil, all: Bool = false, selectionOnly: Bool = false, relative: Int = 0) -> [NotebookExecution.Job] {
        guard committedSource() else { return [] }
        let scan = FenceScanner().scan(source)
        let blocks = visualBlocks.blocks(in: source)
        let selection = activeEditor?.selectedRange() ?? NSRange(location: 0, length: 0)
        let batch = all || relative != 0
        var scope = NSRange(location: 0, length: source.utf16.count)
        let chosen: [RecordVisualBlockIndex.Block]
        if all { chosen = blocks.filter { $0.language == "r" && $0.executable } }
        else if let blockID { chosen = blocks.filter { $0.id == blockID } }
        else if relative != 0 {
            let current = blocks.first { NSLocationInRange(selection.location, $0.range) }
            let boundary = current.map { relative < 0 ? $0.range.location : NSMaxRange($0.range) } ?? selection.location
            scope = relative < 0 ? NSRange(location: 0, length: boundary) : NSRange(location: boundary, length: source.utf16.count - boundary)
            chosen = blocks.filter { $0.language == "r" && $0.executable && (relative < 0 ? NSMaxRange($0.range) <= boundary : $0.range.location >= boundary) }
        } else { chosen = blocks.filter { NSLocationInRange(selection.location, $0.range) } }
        if batch, let problem = scan.problems.first(where: { NSIntersectionRange($0.range, scope).length > 0 }) {
            notice = problem.message; return []
        }
        guard !chosen.isEmpty else {
            notice = relative < 0 ? L10n.string("当前位置以上没有可运行的 R 代码块。") : relative > 0 ? L10n.string("当前位置以下没有可运行的 R 代码块。") : all ? L10n.string("文档中没有可运行的 R 代码块。") : L10n.string("请将光标移到 R 代码块内。")
            return []
        }
        let ns = source as NSString, hash = DocumentRevision(text: source).rawValue
        var jobs: [NotebookExecution.Job] = []
        for block in chosen {
            guard block.canRun else { notice = block.reason; return [] }
            if batch, !block.options.issues.isEmpty { notice = block.options.issues.joined(separator: "\n"); return [] }
            let code: String
            if selectionOnly {
                if let editor = activeEditor, let window = editor.window, window.firstResponder !== editor {
                    notice = L10n.string("请在 R 代码块内选择代码。"); return []
                }
                guard selection.length > 0, NSIntersectionRange(selection, block.contentRange) == selection else {
                    notice = L10n.string("请选择同一个 R 代码块内的代码。"); return []
                }
                code = ns.substring(with: selection)
            } else { code = ns.substring(with: block.contentRange) }
            var note: String?
            if !batch {
                if !block.options.enabled || !block.options.evaluate { note = L10n.string("手动运行，忽略 eval 禁用") }
                if !block.options.issues.isEmpty { note = L10n.string("手动运行原文，未解释动态或不支持的选项") }
            }
            jobs.append(.init(blockID: block.id, blockHash: block.sourceHash,
                request: EvaluationRequest(cellID: block.id, source: code,
                    plot: NotebookPlotOptions(width: (activeEditor?.enclosingScrollView?.superview?.bounds.width ?? 552) - 72,
                        pointSize: fontSize), continueOnError: !selectionOnly && block.options.continueOnError && block.options.issues.isEmpty),
                documentHash: hash, selectionOnly: selectionOnly,
                skipped: batch && (!block.options.enabled || !block.options.evaluate), manualNote: note))
        }
        return jobs
    }
    func runAllNotebookCells() { notebook.run(notebookJobs(all: true), batch: true) }
    func runCurrentNotebookCell() { notebook.run(notebookJobs()) }
    func runNotebookCellsAbove() { notebook.run(notebookJobs(relative: -1), batch: true) }
    func runNotebookCellsBelow() { notebook.run(notebookJobs(relative: 1), batch: true) }
    func runNotebookSelection() { notebook.run(notebookJobs(selectionOnly: true)) }
    func runNotebookBlock(_ id: String) {
        if notebook.isBusy { if notebook.activeBlockID == id { notebook.interrupt() }; return }
        notebook.run(notebookJobs(blockID: id))
    }
    func runOrStopNotebook() { if notebook.isBusy { notebook.interrupt() } else { runAllNotebookCells() } }

    func requestRestartAndRunAll() {
        guard !notebook.isBusy, let window = notebook.window, window.attachedSheet == nil else { return }
        let planned = notebookJobs(all: true)
        guard !planned.isEmpty else { return }
        if planned.allSatisfy(\.skipped) { notebook.run(planned, batch: true); return }
        if notebook.state == .notStarted { runAllNotebookCells(); return }
        let session = notebook.sessionID
        let alert = NSAlert(); alert.messageText = L10n.string("重启 R 并运行全部？")
        alert.informativeText = notebook.restartWarning
        alert.addButton(withTitle: L10n.string("重启并运行")); alert.addButton(withTitle: L10n.string("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, notebook.sessionID == session, !notebook.isBusy else { return }
            // Rebuild after confirmation. restart() also rebuilds after any
            // untitled save sheet and again when the new R session is ready.
            guard !notebookJobs(all: true).isEmpty else { return }
            notebook.restart(runAllAfter: true)
        }
    }

    func toggleRSession() {
        if notebook.state == .notStarted { notebook.start() }
        else { requestStopR() }
    }

    func requestStopR() {
        guard notebook.canStop, let window = notebook.window, window.attachedSheet == nil else { return }
        let session = notebook.sessionID
        let alert = NSAlert(); alert.messageText = L10n.string("停止 R 会话？")
        alert.informativeText = L10n.string("停止 R 会清除当前会话中的所有变量；已有输出仅保留在当前文档窗口。")
        alert.addButton(withTitle: L10n.string("停止")); alert.addButton(withTitle: L10n.string("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, notebook.sessionID == session, notebook.canStop else { return }
            notebook.stop()
        }
    }

    func requestRestartR() {
        guard !notebook.isBusy else { return }
        if notebook.state == .notStarted { notebook.manage(.init(operation: .snapshot)); return }
        guard let window = notebook.window, window.attachedSheet == nil else { return }
        let session = notebook.sessionID
        let alert = NSAlert(); alert.messageText = L10n.string("重启 R 会话？"); alert.informativeText = notebook.restartWarning
        alert.addButton(withTitle: L10n.string("重启")); alert.addButton(withTitle: L10n.string("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, notebook.sessionID == session else { return }
            notebook.restart()
        }
    }

}

/// Native AppKit first responders do not reliably propagate SwiftUI focused
/// values into Commands. Route the single Notebook window explicitly.
@MainActor final class NotebookCommandContext: NSObject, ObservableObject {
    static let shared = NotebookCommandContext()
    private(set) var model: RecordLayoutModel?
    private var changes: AnyCancellable?
    var target: RecordLayoutModel? { target(in: NSApp.keyWindow) }
    func target(in window: NSWindow?) -> RecordLayoutModel? {
        (window?.windowController?.document as? QMDDocument)?.model
    }
    override private init() {
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)), name: name, object: nil)
        }
    }
    func set(_ model: RecordLayoutModel?) {
        guard self.model !== model else { return }
        objectWillChange.send(); self.model = model
        changes = model?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    @objc private func focusChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification, notification.object as? NSWindow === model?.notebook.window {
            set(nil)
        } else if notification.name == NSWindow.didBecomeKeyNotification,
                  let document = (notification.object as? NSWindow)?.windowController?.document as? QMDDocument {
            set(document.model)
        }
        objectWillChange.send()
    }
}

struct NotebookSessionBar: View {
    @ObservedObject var model: RecordLayoutModel
    @AppStorage("notebook.rscript") private var selectedRscript = ""
    @State private var selectedVersion: String?
    init(model: RecordLayoutModel) {
        self.model = model
        _selectedRscript = AppStorage(wrappedValue: "", "notebook.rscript", store: model.visualDefaults)
    }
    private var session: NotebookExecution { model.notebook }
    private var version: String { session.handshake?.rVersion ?? selectedVersion ?? "" }
    private var tooltip: String {
        if session.hasPendingRSelection { return L10n.string("R 或包目录已更换，请重启；当前运行版本仍为 ") + (session.handshake?.rVersion ?? L10n.string("未知")) }
        if let progress = session.executionProgress {
            return session.status + " · \(session.runTotalCount - session.pendingCount)/\(session.runTotalCount) (\(Int(progress * 100))%)"
        }
        return [session.inspectorActivity ?? session.status, session.lastRunSummary].compactMap { $0 }.joined(separator: "\n")
    }
    private var symbol: String {
        if session.hasPendingRSelection { return "exclamationmark.triangle" }
        return switch session.state {
        case .notStarted: "circle"
        case .ready: "checkmark.circle"
        case .crashed: "xmark.circle"
        case .uncertain: "exclamationmark.triangle"
        default: "clock"
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if !session.hasPendingRSelection && (session.isBusy || session.state == .starting || session.isStopping) {
                    NotebookRunProgress(progress: session.executionProgress)
                } else { Image(systemName: symbol).frame(width: 14) }
            }
            .help(tooltip).accessibilityElement(children: .ignore)
            .accessibilityLabel(tooltip)
            .accessibilityValue(session.executionProgress.map { "\(Int($0 * 100))%" } ?? "")
            .accessibilityIdentifier("notebook-r-status")
            Text(version.isEmpty ? "R" : "R " + version).monospacedDigit().lineLimit(1)
                .help(tooltip)
                .accessibilityIdentifier("notebook-r-version")
        }
        .font(.system(size: 12)).controlSize(.small)
        .frame(maxWidth: .infinity).frame(height: 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notebook-session-status")
        .task(id: selectedRscript) {
            selectedVersion = nil
            let value = await InspectorRVersion.shared.version(executable: NotebookRExecutable.locate(selected: selectedRscript))
            if !Task.isCancelled { selectedVersion = value }
        }
    }
}

/// A download-style pie shows completed cells; cell durations may differ.
struct NotebookRunProgress: View {
    let progress: Double?
    var body: some View {
        ZStack {
            Circle().stroke(.secondary, lineWidth: 1)
            if let progress {
                NotebookProgressSector(fraction: min(1, max(0, progress)))
                    .fill(Color.accentColor).padding(2)
            } else {
                Image(systemName: "ellipsis").font(.system(size: 8, weight: .medium))
            }
        }.frame(width: 14, height: 14)
    }
}

private struct NotebookProgressSector: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        guard fraction > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}
