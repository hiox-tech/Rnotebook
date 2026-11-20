import Foundation

/// Deliberately static execution controls, never evaluated as R or YAML code.
struct NotebookExecutionOptions: Sendable {
    var evaluate = true
    var enabled = true
    var continueOnError = false
    var label: String?
    var origins: [String: String] = [:]
    var issues: [String] = []

    mutating func apply(_ entries: [(String, NotebookYAML.Value)], origin: String, allowsEnabled: Bool = false) {
        var seen = Set<String>()
        for (key, value) in entries {
            guard ["eval", "error", "label", "child", "code", "ref.label", "ref-label", "metadata-files", "enabled", "<<", "engine", "file"].contains(key) else { continue }
            if !seen.insert(key).inserted { issues.append(L10n.string("重复的执行选项：") + key + "（" + origin + "）") }
            if ["child", "code", "ref.label", "ref-label", "metadata-files", "<<", "engine", "file"].contains(key) {
                issues.append(L10n.string("批量运行不解释此选项，请使用 Quarto 渲染或手动运行原文：") + key + "（" + origin + "）")
                continue
            }
            if key == "enabled" && !allowsEnabled { continue }
            if key == "label" {
                guard case .scalar(let name) = value, FenceScanner.validLabel(name) else {
                    issues.append(L10n.string("label 格式不受支持。") + "（" + origin + "）"); continue
                }
                if let label, label != name { issues.append(L10n.string("块头与选项中的 label 不一致。")) }
                label = name; origins[key] = origin; continue
            }
            guard case .boolean(let flag) = value else {
                issues.append(L10n.string("交互运行仅支持布尔执行选项：") + key + "（" + origin + "）"); continue
            }
            if key == "eval" { evaluate = flag }
            if key == "error" { continueOnError = flag }
            if key == "enabled" { enabled = flag }
            origins[key] = origin
        }
    }

    static func document(_ yaml: String) -> Self {
        var result = Self()
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        let value = NotebookYAML.parse(yaml)
        guard case .mapping(let root) = value else {
            result.issues.append(L10n.string("无法静态读取文档 YAML 的执行选项，请使用 Quarto 渲染或手动运行。")); return result
        }
        var rootKeys = Set<String>()
        for (key, _) in root where ["execute", "knitr", "metadata-files"].contains(key) {
            if !rootKeys.insert(key).inserted { result.issues.append(L10n.string("重复的执行选项：") + key + "（YAML）") }
        }
        for (key, knitr) in root where key == "knitr" {
            guard case .mapping(let fields) = knitr else { result.invalid("knitr"); continue }
            var seen = false
            for (key, options) in fields where key == "opts_chunk" {
                if seen { result.invalid("knitr.opts_chunk") }; seen = true
                if case .mapping(let entries) = options { result.apply(entries, origin: "YAML knitr.opts_chunk") }
                else { result.invalid("knitr.opts_chunk") }
            }
            if fields.contains(where: { ["opts_hooks", "opts_template"].contains($0.0) }) { result.invalid("knitr hooks/templates") }
        }
        for (key, execute) in root where key == "execute" {
            if case .mapping(let entries) = execute { result.apply(entries, origin: "YAML execute", allowsEnabled: true) }
            else { result.invalid("execute") }
        }
        result.apply(root.filter { ["metadata-files", "<<"].contains($0.0) }, origin: "YAML")
        return result
    }

    func overriding(_ block: Self) -> Self {
        var result = self
        if block.origins["eval"] != nil { result.evaluate = block.evaluate }
        if block.origins["error"] != nil { result.continueOnError = block.continueOnError }
        result.label = block.label
        result.origins.merge(block.origins) { _, next in next }
        result.issues += block.issues
        return result
    }

    var explanation: String {
        let eval = (enabled && evaluate) ? "true" : "false"
        let error = continueOnError ? "true" : "false"
        return "eval: " + eval + " (" + ((enabled ? origins["eval"] : origins["enabled"]) ?? L10n.string("默认")) + ")\nerror: " + error + " (" + (origins["error"] ?? L10n.string("默认")) + ")" + (issues.isEmpty ? "" : "\n" + issues.joined(separator: "\n"))
    }

    private mutating func invalid(_ key: String) {
        issues.append(L10n.string("无法静态读取执行选项：") + key)
    }
}

struct NotebookChunkHeader {
    var language = ""
    var executable = false
    var label: String?
    var entries: [(String, NotebookYAML.Value)] = []
    var issues: [String] = []
    init(_ info: String) {
        let info = info.trimmingCharacters(in: .whitespaces)
        executable = info.hasPrefix("{")
        let inner = executable ? String(info.dropFirst()) : info
        language = String(inner.prefix { !$0.isWhitespace && $0 != "," && $0 != "}" }).lowercased()
        guard executable else { return }
        guard info.hasSuffix("}"), let pieces = NotebookYAML.split(String(inner.dropLast()), on: ",", rQuotes: true), !pieces.isEmpty else {
            issues.append(L10n.string("代码块声明格式不明确。")); return
        }
        let first = pieces[0].trimmingCharacters(in: .whitespaces)
        let rest = first.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty {
            if let pair = NotebookYAML.pair(rest, separator: "=", rQuotes: true) { entries.append((pair.0, Self.rValue(pair.1))) }
            else { label = NotebookYAML.unquote(rest); entries.append(("label", .scalar(label!))) }
        }
        for piece in pieces.dropFirst() {
            guard let pair = NotebookYAML.pair(piece, separator: "=", rQuotes: true) else {
                issues.append(L10n.string("代码块参数格式不明确。")); continue
            }
            entries.append((pair.0, Self.rValue(pair.1)))
        }
    }
    private static func rValue(_ text: String) -> NotebookYAML.Value {
        switch text.trimmingCharacters(in: .whitespaces) {
        case "TRUE": return .boolean(true)
        case "FALSE": return .boolean(false)
        default: return .scalar(NotebookYAML.unquote(text))
        }
    }
}
