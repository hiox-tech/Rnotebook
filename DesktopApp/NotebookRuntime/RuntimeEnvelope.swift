import Foundation

enum RuntimeError: Error, LocalizedError, Sendable, Equatable {
    case invalidFrame(String)
    case protocolViolation(String)
    case io(String, Int32)
    case timedOut(String)
    case disconnected
    case unavailable
    case busy
    case uncertain
    case stopped
    case staleSource
    case resource(String)
    case table(String)
    var errorDescription: String? {
        switch self {
        case .invalidFrame(let reason), .protocolViolation(let reason): L10n.string("R 通信协议错误：") + reason
        case .io(let operation, let code): L10n.string("R 通信操作失败：\(String(operation)) (\(String(code)))")
        case .timedOut(let phase): L10n.string("R 会话超时：") + phase
        case .disconnected: L10n.string("R 进程或响应通道已断开；任务不会自动重跑。")
        case .unavailable: L10n.string("未找到可用的 Rscript 或 Worker 资源。")
        case .busy: L10n.string("R 会话正在处理另一任务。")
        case .uncertain: L10n.string("R 会话状态无法确认，请明确重启后再运行。")
        case .stopped: L10n.string("R 会话已停止。")
        case .staleSource: L10n.string("运行源码已改变，未提交执行。")
        case .table(let reason): L10n.string("数据表同步失败：") + reason
        case .resource(let reason): L10n.string("无法读取图形资源：") + reason
        }
    }
}

struct RuntimeCommand: Encodable, Sendable {
    let protocolVersion = "1.4"
    let sessionID: UUID
    let requestID: UUID
    let taskID: UUID
    let kind: String
    var cellID: String?
    var sourceHash: String?
    var source: String?
    var mode: String?
    var plot: NotebookPlotOptions?
    var inspector: NotebookInspectorRequest?
    var continueOnError: Bool?
}

struct RuntimeRepresentation: Codable, Sendable, Equatable {
    let mime: String
    let text: String
}

struct RuntimePayload: Codable, Sendable, Equatable {
    var text: String?
    var title: String?
    var representations: [RuntimeRepresentation]?
    var styles: [String]?
    var status: String?
    var uncertain: Bool?
    var resourceID: String?
    var mime: String?
    var sizeBytes: Int?
    var resourceIDs: [String]?
    var pid: Int32?
    var rVersion: String?
    var evaluateVersion: String?
    var captureBackend: String?
    var rHome: String?
    var workingDirectory: String?
    var libraryPaths: [String]?
    var inspector: NotebookInspectorSnapshot?
    var completions: [RCompletionCandidate]?
    var objectPreview: NotebookObjectPreview?
    var helpURL: String?

}

struct RuntimeEnvelope: Codable, Sendable, Equatable {
    let protocolVersion: String
    let sessionID: UUID
    let requestID: UUID
    let taskID: UUID
    let sequence: Int
    let cellID: String?
    let sourceHash: String?
    let kind: String
    let payload: RuntimePayload
}

/// Display points are distinct from raster pixels. Two pixels per point
/// at 144 dpi preserve R's 1/72-inch font sizes in AppKit's point layout.
struct NotebookPlotOptions: Codable, Sendable, Equatable {
    let width: Int
    let height: Int
    let pointSize: Double
    let scale: Int
    let background: String?
    init(width: Double = 480, pointSize: Double = 14) {
        self.width = min(1600, max(240, Int((width.isFinite ? width : 480).rounded())))
        self.pointSize = min(36, max(8, pointSize.isFinite ? pointSize : 14))
        height = max(Int((Double(self.width) * 2 / 3).rounded()), Int(ceil(self.pointSize * 16)))
        scale = 2; background = nil
    }
    init(graphicWidth: Double, graphicHeight: Double, pointSize: Double, background: String? = nil) {
        width = min(1800, max(72, Int(graphicWidth.rounded())))
        height = min(1800, max(72, Int(graphicHeight.rounded())))
        self.pointSize = min(36, max(8, pointSize)); scale = 2; self.background = background
    }
}



struct EvaluationRequest: Sendable {
    let taskID: UUID
    let cellID: String
    let source: String
    let sourceHash: String
    let mode: ExecutionMode
    let plot: NotebookPlotOptions
    let continueOnError: Bool
    init(taskID: UUID = UUID(), cellID: String, source: String, mode: ExecutionMode = .notebookCell, plot: NotebookPlotOptions = .init(), continueOnError: Bool = false) {
        self.taskID = taskID; self.cellID = cellID; self.source = source
        sourceHash = DocumentRevision(text: source).rawValue
        self.mode = mode; self.plot = plot; self.continueOnError = continueOnError
    }
}

struct RuntimeTranscript: Sendable {
    let sessionID: UUID
    let events: [RuntimeEnvelope]
    let stdout: Data
    let stderr: Data
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
}
