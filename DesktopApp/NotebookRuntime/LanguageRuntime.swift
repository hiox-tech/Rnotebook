import Foundation

struct RuntimeConfiguration: Sendable {
    let executable: URL
    let workerScript: URL
    let projectDirectory: URL
    var startupTimeout: TimeInterval = 10
    var taskTimeout: TimeInterval = 3600
    var packageLibrary: URL?
}

enum SessionState: Equatable, Sendable {
    case notStarted, starting, ready, interrupting, uncertain, crashed
    case busy(taskID: UUID)
}

enum ExecutionMode: String, Sendable { case notebookCell }

protocol LanguageRuntime: Actor {
    var state: SessionState { get }
    func start(_ configuration: RuntimeConfiguration) async throws -> RuntimePayload
    func evaluate(_ request: EvaluationRequest, event: @escaping @Sendable (RuntimeEnvelope) -> Void,
                  console: @escaping @Sendable (String, Data) -> Void) async throws -> RuntimeTranscript
    func interrupt() async
    func stop() async throws
}
