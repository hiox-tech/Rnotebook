import Foundation

struct ResponseFrameDecoder {
    static let maximumFrameBytes = 1_048_576
    private var buffer = Data()
    var hasPartialFrame: Bool { !buffer.isEmpty }

    mutating func feed(_ bytes: Data) throws -> [RuntimeEnvelope] {
        buffer.append(bytes)
        var events: [RuntimeEnvelope] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumFrameBytes else { throw RuntimeError.invalidFrame(L10n.string("长度超限或为零")) }
            guard buffer.count >= 4 + length else { break }
            let body = Data(buffer.dropFirst(4).prefix(length))
            guard String(data: body, encoding: .utf8) != nil else { throw RuntimeError.invalidFrame(L10n.string("无效 UTF-8")) }
            do { events.append(try JSONDecoder().decode(RuntimeEnvelope.self, from: body)) }
            catch { throw RuntimeError.invalidFrame(L10n.string("无效响应 JSON：") + error.localizedDescription) }
            buffer.removeFirst(4 + length)
        }
        return events
    }
    func finish() throws {
        if hasPartialFrame { throw RuntimeError.invalidFrame(L10n.string("响应在帧中断开")) }
    }
}

struct ResponseValidator {
    private static let richLimit = 1_048_576
    let command: RuntimeCommand
    private(set) var sequence = 0
    private(set) var terminal = false
    private var finalized = false
    private var inspected = false
    mutating func accept(_ event: RuntimeEnvelope) throws {
        guard !terminal, event.protocolVersion == "1.4", event.sessionID == command.sessionID,
              event.requestID == command.requestID, event.taskID == command.taskID,
              event.cellID == command.cellID, event.sourceHash == command.sourceHash,
              event.sequence == sequence + 1 else { throw RuntimeError.protocolViolation(L10n.string("版本、关联标识、顺序或终态不匹配")) }
        if command.kind == "hello" {
            guard event.kind == "ready", event.payload.pid != nil, event.payload.rVersion != nil,
                  event.payload.evaluateVersion != nil else { throw RuntimeError.protocolViolation(L10n.string("握手内容无效")) }
            terminal = true
        } else if command.kind == "shutdown" {
            guard event.kind == "stopped" else { throw RuntimeError.protocolViolation(L10n.string("退出响应无效")) }
            terminal = true
        } else if sequence == 0 {
            guard event.kind == "started" else { throw RuntimeError.protocolViolation(L10n.string("缺少任务开始事件")) }
        } else {
            if command.kind == "inspector", !["stdout", "message", "warning", "error", "inspector_result", "finished"].contains(event.kind) {
                throw RuntimeError.protocolViolation(L10n.string("非面板管理事件"))
            }
            switch event.kind {
            case "inspector_result":
                let previewRequest = command.inspector?.operation == .previewObject
                let resultIsValid: Bool
                if command.inspector?.operation == .completion, let items = event.payload.completions {
                    resultIsValid = items.count <= 200 && event.payload.inspector == nil && event.payload.objectPreview == nil &&
                        items.allSatisfy { !$0.label.isEmpty && $0.label.utf8.count <= 512 &&
                            $0.insertion.utf8.count <= 2048 && !$0.insertion.contains("\n") && !$0.insertion.contains("\0") &&
                            $0.detail == "R session" && $0.range == nil }
                } else if previewRequest, let preview = event.payload.objectPreview {
                    resultIsValid = preview.isValid && preview.name == command.inspector?.name && preview.request == (command.inspector?.preview ?? .init()) && event.payload.inspector == nil
                } else {
                    let snapshot = event.payload.inspector
                    let request = command.inspector?.variablePage ?? .init()
                    let pageMatches = snapshot?.variablePage.map {
                        Data($0.query.utf8) == Data(request.query.utf8) &&
                        ($0.offset == request.offset || ($0.offset == 0 && $0.snapshotID != request.snapshotID)) &&
                        (request.offset == 0 || $0.offset == 0 || $0.snapshotID == request.snapshotID)
                    } ?? (command.inspector?.variablePage == nil)
                    resultIsValid = !previewRequest && snapshot?.isValid == true && pageMatches && event.payload.objectPreview == nil
                }
                guard command.kind == "inspector", !inspected, resultIsValid,
                      event.payload.helpURL.map({ NotebookInspectorSnapshot.helpURL($0) != nil }) ?? true else {
                    throw RuntimeError.protocolViolation(L10n.string("面板快照或帮助地址无效"))
                }
                inspected = true
            case "stdout", "display_text", "message", "warning", "error":
                guard event.payload.text != nil else { throw RuntimeError.protocolViolation(L10n.string("文本事件缺少正文")) }
            case "display_rich":
                guard let items = event.payload.representations, !items.isEmpty, items.count <= 4,
                      items.allSatisfy({ ["text/html", "text/markdown", "text/plain"].contains($0.mime) }),
                      items.reduce(0, { $0 + $1.text.utf8.count }) + (event.payload.styles ?? []).reduce(0, { $0 + $1.utf8.count }) <= Self.richLimit else {
                    throw RuntimeError.protocolViolation(L10n.string("富内容事件无效或超限"))
                }
            case "display_image":
                guard !finalized, event.payload.resourceID != nil, event.payload.mime == "image/png", event.payload.sizeBytes != nil else {
                    throw RuntimeError.protocolViolation(L10n.string("图形事件不完整"))
                }
            case "plots_finalized":
                guard !finalized, event.payload.resourceIDs != nil else { throw RuntimeError.protocolViolation(L10n.string("图形终态无效")) }
                finalized = true
            case "finished":
                guard ["completed", "failed", "interrupted"].contains(event.payload.status), event.payload.uncertain != nil else {
                    throw RuntimeError.protocolViolation(L10n.string("任务终态无效"))
                }
                if command.kind == "inspector", event.payload.status == "completed", !inspected {
                    throw RuntimeError.protocolViolation(L10n.string("面板任务缺少结果"))
                }

                terminal = true
            default: throw RuntimeError.protocolViolation(L10n.string("非Notebook事件：") + event.kind)
            }
        }
        sequence += 1
    }
}
