import Foundation
import EdmundCore

enum LanguageToolResources {
    static var bundle: Bundle { Bundle(for: RecordRTokenSource.self) }
    static func executable(_ name: String) -> URL? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        guard let url = bundle.url(forResource: name+"-"+arch, withExtension: nil, subdirectory: "LanguageTools"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}

struct RFormatPreferences: Sendable, Equatable {
    var custom = false
    var lineWidth = 80
    var indentWidth = 2
    var persistentBreaks = true
    init() {}
    init(defaults: UserDefaults) {
        custom = defaults.string(forKey: "rFormat.mode") == "custom"
        let width = defaults.integer(forKey: "rFormat.lineWidth")
        lineWidth = (1...320).contains(width) ? width : 80
        let indent = defaults.integer(forKey: "rFormat.indentWidth")
        indentWidth = (1...24).contains(indent) ? indent : 2
        persistentBreaks = defaults.object(forKey: "rFormat.persistentBreaks") == nil || defaults.bool(forKey: "rFormat.persistentBreaks")
    }
    var configuration: String {
        "[format]\nline-width = \(min(320, max(1, lineWidth)))\nindent-width = \(min(24, max(1, indentWidth)))\npersistent-line-breaks = \(persistentBreaks)\n"
    }
}

enum RAirFormatter {
    struct Edit: Sendable { let original: String; let range: NSRange; let replacement: String }
    enum Failure: Error { case outsideBlock, unclosed, unsupportedContainer, invalidCode, missingTool }
    static func format(source: String, selection: NSRange, documentURL: URL?, executable: URL? = nil,
                       preferences: RFormatPreferences = .init()) async throws -> Edit {
        let map = RCodeDocument(source)
        guard let block = map.block(at: selection.location), selection.upperBound <= block.bodyRange.upperBound else { throw Failure.outsideBlock }
        guard block.closed else { throw Failure.unclosed }
        guard !block.prefix.contains(">"), !block.prefix.contains("\t") else { throw Failure.unsupportedContainer }
        let body = (source as NSString).substring(with: block.bodyRange)
        let newline = body.contains("\r\n") ? "\r\n" : "\n"
        var lines = body.components(separatedBy: newline)
        if lines.last == "" { lines.removeLast() }
        let prefix = block.prefix
        var dedented: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { dedented.append("") }
            else if prefix.isEmpty || line.hasPrefix(prefix) { dedented.append(String(line.dropFirst(prefix.count))) }
            else { throw Failure.unsupportedContainer }
        }
        var protected = 0
        while protected < dedented.count {
            let text = dedented[protected].trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#|") { protected += 1 } else { break }
        }
        guard !dedented.dropFirst(protected).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#|") }) else { throw Failure.unsupportedContainer }
        let code = dedented.dropFirst(protected).joined(separator: "\n")
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Edit(original: source, range: block.bodyRange, replacement: body) }
        guard let tool = executable ?? LanguageToolResources.executable("air") else { throw Failure.missingTool }
        // Explicit custom settings are scoped to a managed temporary task.
        // Never write air.toml beside the user's notebook or change R state.
        let lease = preferences.custom ? try NotebookCacheStore().create(.completion) : nil
        defer { try? lease?.finish() }
        let directory = lease?.directory ?? documentURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        if preferences.custom {
            try Data(preferences.configuration.utf8).write(to: directory.appendingPathComponent("air.toml"), options: .atomic)
        }
        let associated = directory.appendingPathComponent("Rnotebook-block.R")
        let output = try await QuartoProcess().run(executable: tool,
            arguments: ["format", "--stdin-file-path", associated.path], directory: directory,
            environment: ProcessInfo.processInfo.environment, timeout: 15, input: Data(code.utf8), cacheLease: lease)
        guard output.exitCode == 0, !output.cancelled, !output.timedOut, !output.truncated,
              let formatted = String(data: output.stdout, encoding: .utf8) else { throw Failure.invalidCode }
        var codeLines = formatted.components(separatedBy: "\n")
        if codeLines.last == "" { codeLines.removeLast() }
        let unchanged = lines.prefix(protected).map { $0+newline }.joined()
        let replacement = unchanged + codeLines.map { ( $0.isEmpty ? "" : prefix+$0 )+newline }.joined()
        return Edit(original: source, range: block.bodyRange, replacement: replacement)
    }
}

extension RecordLayoutModel {
    func formatCurrentRBlock() {
        guard let editor = activeEditor else { return }
        formatRBlock(at: editor.selectedRange())
    }
    func formatRBlock(_ id: String) {
        guard let editor = activeEditor,
              let block = visualBlocks.blocks(in: editor.string).first(where: { $0.id == id && $0.language == "r" }) else { return }
        formatRBlock(at: NSRange(location: block.contentRange.location, length: 0))
    }
    private func formatRBlock(at selection: NSRange) {
        guard let editor = activeEditor, editor.isEditable, !editor.hasMarkedText() else { return }
        let source = editor.string, caret = editor.selectedRange()
        let preferences = RFormatPreferences(defaults: visualDefaults)
        Task { @MainActor [weak self, weak editor] in
            do {
                let edit = try await RAirFormatter.format(source: source, selection: selection, documentURL: self?.documentURL, preferences: preferences)
                guard let self, let editor, self.activeEditor === editor, DocumentRevision.sameSource(editor.string, edit.original),
                      editor.selectedRange() == caret, !editor.hasMarkedText() else { return }
                if (source as NSString).substring(with: edit.range) == edit.replacement { return }
                let delta = edit.replacement.utf16.count - edit.range.length
                let location = caret.location >= edit.range.upperBound ? caret.location + delta
                    : caret.location <= edit.range.location ? caret.location
                    : edit.range.location + min(caret.location - edit.range.location, edit.replacement.utf16.count)
                if let native = editor as? EditorTextView {
                    native.replaceSource(in: edit.range, with: edit.replacement,
                        selecting: NSRange(location: location, length: min(caret.length, source.utf16.count + delta - location)))
                    (native.enclosingScrollView?.superview as? RecordNativeEditorHost)?.publishCommittedText()
                }
                editor.undoManager?.setActionName(L10n.string("格式化 R 代码块"))
            } catch {
                guard let self else { return }
                notice = L10n.string("无法格式化：请将光标放在完整的 R 代码块内，并检查代码语法。")
            }
        }
    }
}
