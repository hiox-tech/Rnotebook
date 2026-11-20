import Foundation
import CryptoKit

enum QuartoExportError: Error, LocalizedError {
    case invalidRequest, missingTools, busy, missingArtifact, destinationChanged
    case process(Int32)
    case detail(String)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: L10n.string("导出参数无效，请检查格式、文件名和数值范围。")
        case .missingTools: L10n.string("未找到可用的 Quarto 或 Rscript，请在软件设置中选择；R 渲染需要 knitr、rmarkdown。")
        case .busy: L10n.string("当前已有导出任务，请等待完成或先取消。")
        case .missingArtifact: L10n.string("Quarto 已退出，但本次任务没有生成有效的目标文件。")
        case .destinationChanged: L10n.string("目标文件在导出期间发生变化，未覆盖；生成文件保留在任务目录。")
        case .process(let code): L10n.string("无法启动 Quarto 子进程（\(String(code))）。")
        case .detail(let text): text
        }
    }
}
enum QuartoExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case html, docx, typst, pdf
    var id: String { rawValue }
    var label: String {
        switch self { case .html: "HTML"; case .docx: "Word (.docx)"; case .typst: L10n.string("PDF（Typst）"); case .pdf: L10n.string("PDF（LaTeX）") }
    }
    var fileExtension: String { self == .typst ? "pdf" : rawValue }
    var isPDF: Bool { self == .pdf || self == .typst }
    var figureFormats: [String] {
        switch self {
        case .html: ["png", "svg", "jpeg", "retina"]
        case .docx, .typst: ["png", "jpeg", "svg"]
        case .pdf: ["png", "pdf", "jpeg"]
        }
    }
}
enum QuartoOverride: String, CaseIterable, Identifiable, Codable, Sendable {
    case inherit, yes, no
    var id: String { rawValue }
    var label: String { switch self { case .inherit: L10n.string("跟随文档"); case .yes: L10n.string("显示"); case .no: L10n.string("隐藏") } }
    var value: Bool? { switch self { case .inherit: nil; case .yes: true; case .no: false } }
}
enum QuartoExecution: String, CaseIterable, Identifiable, Codable, Sendable {
    case fresh, document, disabled
    var id: String { rawValue }
    var label: String { switch self { case .fresh: L10n.string("完整重新计算"); case .document: L10n.string("跟随文档设置"); case .disabled: L10n.string("不运行代码（仅正文）") } }
}
enum QuartoParameterSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case yaml, custom
    var id: String { rawValue }
    var label: String { self == .yaml ? L10n.string("文档 YAML 块") : L10n.string("自定义") }
}
struct QuartoExportOptions: Codable, Sendable {
    var edmundCompatibility = true
    var format: QuartoExportFormat = .html
    var parameterSource: QuartoParameterSource = .yaml
    var execution: QuartoExecution = .fresh
    var title = "", language = ""
    var toc: QuartoOverride = .no
    var numbering: QuartoOverride = .no
    var echo: QuartoOverride = .yes
    var warning: QuartoOverride = .yes
    var continueOnError: QuartoOverride = .no
    var codeFold: QuartoOverride = .no
    var codeCopy: QuartoOverride = .yes
    var tocDepth = 3
    var figureWidth = "6.5", figureHeight = "4.5", figureDPI = "300"
    var pdfFont = ""
    var subtitle = "", author = "", date = "", abstract = ""
    var fontSize = "12", lineStretch = "1.2", paperSize = "a4", marginMM = "25.4"
    var htmlTheme = "cosmo", pageLayout = "article", tocLocation = "right"
    var codeLineNumbers = false, codeOverflow = "wrap", codeTheme = "pygments"
    var message = false, output = true, cache = false
    var figureFormat = "png", figureAlign = "center", tablePrint = "kable"
    var pdfEngine = "xelatex", documentClass = "article", cjkFont = ""
    var referenceDoc = "", stylesheet = "", bibliography = "", citationStyle = ""
    var extraYAMLByFormat: [String: String] = [:]
    var additionalYAML: String { parameterSource == .custom ? extraYAMLByFormat[format.rawValue] ?? "" : "" }
    var effectiveFigureFormat: String { format.figureFormats.contains(figureFormat) ? figureFormat : "png" }
    var effectiveTablePrint: String { tablePrint == "paged" && format != .html ? "kable" : tablePrint }

    /// A custom render has its own metadata, with the QMD body left intact.
    func renderedSource(_ source: String) throws -> String {
        guard parameterSource == .custom else { return source }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let text = normalized.hasPrefix("\u{FEFF}") ? String(normalized.dropFirst()) : normalized
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return source }
        guard let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" || lines[$0].trimmingCharacters(in: .whitespaces) == "..." }) else {
            throw QuartoExportError.detail(L10n.string("YAML 头未闭合，无法分离正文。"))
        }
        return String(repeating: "\n", count: end + 1) + lines.dropFirst(end + 1).joined(separator: "\n")
    }
    var openAfterExport = true
    var executionArguments: [String] {
        guard parameterSource == .custom else { return [] }
        return execution == .disabled ? ["--no-execute"] : cache ? ["--execute"] : ["--execute", "--cache-refresh"]
    }
    func metadata() throws -> Data {
        var data: [String: Any] = [:], execute: [String: Any] = [:]
        // Artifact delivery and no implicit TeX installation remain app policies,
        // independently of the source of the optional rendering overrides.
        if format == .html { data["embed-resources"] = true }
        if format == .pdf { data["latex-auto-install"] = false }
        guard parameterSource == .custom else {
            return try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        }
        guard toc != .yes || (1...6).contains(tocDepth) else { throw QuartoExportError.invalidRequest }
        func number(_ text: String, range: ClosedRange<Double>) throws -> Double {
            guard let value = Double(text), value.isFinite, range.contains(value) else { throw QuartoExportError.invalidRequest }
            return value
        }
        // All switches are explicit in custom mode; legacy inherit values resolve to app defaults.
        data["title"] = title
        let selectedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedLanguage.isEmpty { data["lang"] = selectedLanguage }
        for (key, value) in [("author", author), ("date", date), ("abstract", abstract)] where !value.isEmpty { data[key] = value }
        if format != .typst, !subtitle.isEmpty { data["subtitle"] = subtitle }
        data["toc"] = toc == .yes
        if toc == .yes { data["toc-depth"] = tocDepth }
        data["number-sections"] = numbering == .yes
        execute["echo"] = echo != .no
        execute["warning"] = warning != .no
        execute["message"] = message
        execute["output"] = output
        execute["error"] = continueOnError == .yes
        execute["cache"] = cache
        execute["eval"] = execution != .disabled
        data["execute"] = execute
        // Quarto maps its warning switch to both knitr warnings and messages.
        // Keep the independent message control explicit, while output=false hides both.
        data["knitr"] = ["opts_chunk": ["message": message && output]]
        data["fig-width"] = try number(figureWidth, range: 1...50)
        data["fig-height"] = try number(figureHeight, range: 1...50)
        data["fig-dpi"] = try number(figureDPI, range: 72...1200)
        guard ["png", "jpeg", "svg", "pdf", "retina"].contains(figureFormat),
              ["left", "center", "right"].contains(figureAlign),
              ["default", "kable", "tibble", "paged"].contains(tablePrint) else { throw QuartoExportError.invalidRequest }
        data["fig-format"] = effectiveFigureFormat
        data["fig-align"] = figureAlign
        data["df-print"] = effectiveTablePrint
        data["syntax-highlighting"] = codeTheme
        data["code-line-numbers"] = codeLineNumbers
        if !bibliography.isEmpty { data["bibliography"] = bibliography }
        if !citationStyle.isEmpty { data["csl"] = citationStyle }
        if format == .html {
            data["theme"] = htmlTheme
            data["page-layout"] = pageLayout
            data["toc-location"] = tocLocation
            data["code-fold"] = codeFold == .yes
            data["code-copy"] = codeCopy != .no
            data["code-overflow"] = codeOverflow
            if !stylesheet.isEmpty { data["css"] = stylesheet }
        }
        if format == .docx {
            if !referenceDoc.isEmpty { data["reference-doc"] = referenceDoc }
        } else {
            if !pdfFont.isEmpty { data["mainfont"] = pdfFont }
            data["fontsize"] = "\(try number(fontSize, range: 6...72))pt"
            data["linestretch"] = try number(lineStretch, range: 0.5...3)
        }
        if format.isPDF {
            data["papersize"] = paperSize
            let margin = "\(try number(marginMM, range: 0...100))mm"
            if format == .typst { data["margin"] = ["top": margin, "bottom": margin, "left": margin, "right": margin] }
            else {
                data["geometry"] = "margin=" + margin
                data["pdf-engine"] = pdfEngine
                data["documentclass"] = documentClass
                if !cjkFont.isEmpty { data["CJKmainfont"] = cjkFont }
            }
        }
        return try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
    }
    func metadataArguments(values selected: [String: Any]? = nil) throws -> [String] {
        let values = try selected ?? JSONSerialization.jsonObject(with: metadata()) as! [String: Any]
        return try values.keys.sorted().flatMap { key -> [String] in
            // The typed metadata file already supplies the language to Quarto.
            // Repeating a JSON-quoted tag via -M reaches Pandoc as literal quotes
            // and causes an invalid-language warning before our Meta filter runs.
            if key == "lang" { return [] }
            if key == "execute", let execution = values[key] as? [String: Any] {
                return try execution.keys.sorted().flatMap { name -> [String] in
                    let encoded = try JSONSerialization.data(withJSONObject: execution[name]!, options: [.fragmentsAllowed])
                    return ["--metadata", name + ":" + String(decoding: encoded, as: UTF8.self)]
                }
            }
            let value = String(decoding: try JSONSerialization.data(withJSONObject: values[key]!, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
            return ["--metadata", key + ":" + value]
        }
    }
}
struct QuartoExportInput: Sendable {
    let source: String
    let documentURL: URL
}
struct QuartoExportTools: Sendable {
    let quarto: URL
    let rscript: URL
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var timeout: TimeInterval = 3600
}
struct QuartoExportRecord: Codable, Sendable {
    enum Status: String, Codable, Sendable { case preparing, rendering, succeeded, failed, cancelled, timedOut }
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    var status: Status
    let format: QuartoExportFormat
    let sourceHash: String
    var renderedSourceHash: String?
    var renderedSourceLineOffset: Int?  // Extra staging header lines, when needed.
    var edmundCompatibility: Bool?
    var parameterSource: QuartoParameterSource?
    let destination: URL
    let directory: URL
    var quarto: URL?
    var rscript: URL?
    var quartoVersion: String?
    var arguments: [String] = []
    var resourceHashes: [String: String] = [:]
    var tableNames: [String] = []
    var exitCode: Int32?
    var logsTruncated = false
    var sourceChanged = false
    var dataChanged = false
    var diagnostic: String?
    var archivedArtifact: URL?
    var artifact: URL? { status == .succeeded ? archivedArtifact ?? destination : nil }
}
enum QuartoExecutable {
    static func locate(selected: String? = nil) -> URL? {
        if let selected, !selected.isEmpty { return FileManager.default.isExecutableFile(atPath: selected) ? URL(fileURLWithPath: selected) : nil }
        if let bundled = NotebookBundledRuntime.quarto { return bundled }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/quarto" }
        return (paths + ["/Applications/quarto/bin/quarto", "/opt/homebrew/bin/quarto", "/usr/local/bin/quarto"])
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}
struct QuartoDestination: Sendable {
    let url: URL
    let initialHash: String?
    init(_ url: URL, overwrite: Bool) throws {
        guard url.isFileURL else { throw QuartoExportError.invalidRequest }
        self.url = url
        initialHash = try Self.hashIfPresent(url)
        if initialHash != nil && !overwrite { throw QuartoExportError.destinationChanged }
    }
    static func hashIfPresent(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw QuartoExportError.destinationChanged }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func publish(_ artifact: URL) throws {
        guard try Self.hashIfPresent(url) == initialHash else { throw QuartoExportError.destinationChanged }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".quarto-export-" + UUID().uuidString)
        try FileManager.default.copyItem(at: artifact, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        if initialHash != nil { _ = try FileManager.default.replaceItemAt(url, withItemAt: temp) }
        else { try FileManager.default.moveItem(at: temp, to: url) }
    }
}

/// Renders the source snapshot using ordinary external file references and
/// explicit tool paths, independently of the interactive Notebook session.
enum QuartoExportEngine {
    static func save(_ record: QuartoExportRecord) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: record.directory.appendingPathComponent("record.json"), options: .atomic)
    }
    static func run(input: QuartoExportInput, options: QuartoExportOptions, tools: QuartoExportTools, destination: QuartoDestination, directory: URL,
                    process: QuartoProcess, log: @escaping @Sendable (Int, Data) -> Void,
                    prepared: @escaping @Sendable (QuartoExportRecord) -> Void, cacheLease: NotebookCacheLease? = nil) async -> QuartoExportRecord {
        var record = QuartoExportRecord(id: UUID(), startedAt: Date(), status: .preparing, format: options.format,
            sourceHash: DocumentRevision(text: input.source).rawValue, destination: destination.url, directory: directory)
        record.parameterSource = options.parameterSource
        record.edmundCompatibility = options.edmundCompatibility
        var temporarySource: URL?
        defer {
            if let temporarySource {
                try? FileManager.default.removeItem(at: temporarySource)
                for suffix in ["_files", "_cache", ".rmarkdown", ".knit.md", ".utf8.md", ".tex", ".log", ".aux", ".out", ".toc", ".typ", ".pdf", ".synctex.gz", ".fls", ".fdb_latexmk"] {
                    let generated = temporarySource.deletingLastPathComponent().appendingPathComponent(temporarySource.deletingPathExtension().lastPathComponent + suffix)
                    try? FileManager.default.removeItem(at: generated)
                }
            }
        }
        do {
            guard destination.url.resolvingSymlinksInPath().standardizedFileURL != input.documentURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw QuartoExportError.detail(L10n.string("导出目标不能是当前 QMD 文档，请选择其他文件。"))
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Render a temporary source beside the QMD so ordinary relative references keep working.
            // Only transient render input is created; no project or resource collection is introduced.
            let base = input.documentURL.deletingLastPathComponent()
            let baseParts = base.resolvingSymlinksInPath().pathComponents
            func relativeToBase(_ url: URL) -> String {
                let parts = url.resolvingSymlinksInPath().pathComponents
                var shared = 0
                while shared < min(baseParts.count, parts.count), baseParts[shared] == parts[shared] { shared += 1 }
                return (Array(repeating: "..", count: baseParts.count - shared) + parts.dropFirst(shared)).joined(separator: "/")
            }
            // TeX's restricted openout policy rejects job names starting with a
            // dot. Use a unique ordinary stem and clean its known intermediates.
            let staged = base.appendingPathComponent("rnotebook-render-" + (cacheLease?.id ?? UUID()).uuidString + ".qmd")
            temporarySource = staged
            var renderedSource = try options.renderedSource(input.source)
            let metadata = directory.appendingPathComponent("metadata.json")
            var selectedMetadata = try JSONSerialization.jsonObject(with: options.metadata()) as! [String: Any]
            if options.parameterSource == .custom && options.format == .html {
                guard let resource = Bundle.main.url(forResource: "local-fonts", withExtension: "scss", subdirectory: "Quarto") else {
                    throw QuartoExportError.detail(L10n.string("缺少 HTML 本地字体配置。"))
                }
                let bytes = try Data(contentsOf: resource), style = directory.appendingPathComponent("local-fonts.scss")
                try bytes.write(to: style)
                selectedMetadata["theme"] = [options.htmlTheme, relativeToBase(style)]
                record.resourceHashes["Quarto/local-fonts.scss"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            try JSONSerialization.data(withJSONObject: selectedMetadata, options: [.prettyPrinted, .sortedKeys]).write(to: metadata)
            // Quarto parses -M values as YAML, but Pandoc receives unknown
            // string keys literally (including quoting). Apply the selected
            // string values as typed Pandoc metadata after its command parsing.
            let filter = directory.appendingPathComponent("overrides.lua")
            try Data("""
            function Meta(meta)
              local input = assert(io.open(os.getenv('RNOTEBOOK_EXPORT_METADATA'), 'r'))
              local selected = pandoc.json.decode(input:read('*a'))
              input:close()
              local function metadata(value)
                if type(value) == 'boolean' then return pandoc.MetaBool(value) end
                if type(value) ~= 'table' then return pandoc.MetaString(tostring(value)) end
                local result = {}
                for key, item in pairs(value) do result[key] = metadata(item) end
                if #value > 0 then return pandoc.MetaList(result) end
                return pandoc.MetaMap(result)
              end
              for key, value in pairs(selected) do meta[key] = metadata(value) end
              if selected.title ~= nil then meta.pagetitle = pandoc.MetaString(selected.title) end
              return meta
            end
            """.utf8).write(to: filter)
            // Bundle the compatibility layer, then retain the exact script used
            // with the task evidence. It transforms only Pandoc's document AST.
            // CLI --lua-filter runs after Quarto's internal AST processing.
            // Use Quarto's explicit phase so generated callouts/images are
            // processed natively, even if the document orders its own filters.
            // Quarto merges this list with document/project filters.
            var resourceFilters: [[String: String]] = []
            if options.edmundCompatibility {
                guard let compatibilityURL = Bundle.main.url(forResource: "edmund-compat", withExtension: "lua", subdirectory: "Quarto") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let compatibility = directory.appendingPathComponent("edmund-compat.lua")
                let compatibilityData = try Data(contentsOf: compatibilityURL)
                try compatibilityData.write(to: compatibility)
                record.resourceHashes["Quarto/edmund-compat.lua"] = SHA256.hash(data: compatibilityData)
                    .map { String(format: "%02x", $0) }.joined()
                resourceFilters.append(["at": "pre-ast", "type": "lua", "path": compatibility.path])
            }
            // File URLs inserted by older versions must render with the syntax
            // compatibility switch both on and off. Run after wiki-image creation,
            // before Quarto interprets absolute paths as project-root resources.
            guard let imageResource = Bundle.main.url(forResource: "local-images", withExtension: "lua", subdirectory: "Quarto") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let imageFilter = directory.appendingPathComponent("local-images.lua")
            let imageData = try Data(contentsOf: imageResource)
            try imageData.write(to: imageFilter)
            record.resourceHashes["Quarto/local-images.lua"] = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
            resourceFilters.append(["at": "pre-ast", "type": "lua", "path": imageFilter.path])
            let resourceMetadata = directory.appendingPathComponent("resource-filters.json")
            try JSONSerialization.data(withJSONObject: ["filters": resourceFilters], options: [.sortedKeys]).write(to: resourceMetadata)
            record.quarto = tools.quarto; record.rscript = tools.rscript
            var environment = try NotebookLibrary.environment(tools.environment, rscript: tools.rscript)
            environment["QUARTO_R"] = tools.rscript.path
            environment["RNOTEBOOK_EXPORT_METADATA"] = metadata.path
            let outputDirectory = directory.appendingPathComponent("out")
            let artifact = outputDirectory.appendingPathComponent("report." + options.format.fileExtension)
            let relativeOutput = relativeToBase(outputDirectory)
            var compatibilityArguments = ["--metadata-file", resourceMetadata.path]
            if !options.additionalYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let extra = directory.appendingPathComponent("custom.yml")
                try Data(options.additionalYAML.utf8).write(to: extra)
                // Repeated CLI metadata files shallowly replace `filters` in
                // Quarto. Include the custom draft from the temporary QMD so
                // Quarto merges its user filters with our pre-ast entry.
                // Quarto resolves metadata-files with path.join(inputDir, path),
                // including absolute strings, so these must be relative paths.
                let metadataFiles = [extra, resourceMetadata]
                let paths = String(decoding: try JSONEncoder().encode(metadataFiles.map(relativeToBase)), as: UTF8.self)
                let header = "---\nmetadata-files: \(paths)\n---\n"
                if renderedSource.hasPrefix("\n\n\n") {
                    renderedSource = header + renderedSource.dropFirst(3)
                    record.renderedSourceLineOffset = 0
                } else {
                    renderedSource = header + renderedSource
                    record.renderedSourceLineOffset = 3
                }
                compatibilityArguments = []
            }
            record.renderedSourceHash = DocumentRevision(text: renderedSource).rawValue
            try Data(renderedSource.utf8).write(to: staged, options: .withoutOverwriting)
            try cacheLease?.recordStagedSource(staged, source: Data(renderedSource.utf8))
            record.arguments = ["render", staged.lastPathComponent, "--to", options.format.rawValue,
                "--output", artifact.lastPathComponent, "--output-dir", relativeOutput]
                + ["--metadata-file", metadata.path, "--lua-filter", filter.path]
                + compatibilityArguments
                + (try options.metadataArguments(values: selectedMetadata)) + options.executionArguments
            record.status = .rendering; try save(record); prepared(record)
            let output = try await process.run(executable: tools.quarto, arguments: record.arguments, directory: base,
                environment: environment, timeout: tools.timeout, cacheLease: cacheLease, log: log)
            record.exitCode = output.exitCode
            record.logsTruncated = output.truncated
            try output.stdout.write(to: directory.appendingPathComponent("stdout.log"))
            try output.stderr.write(to: directory.appendingPathComponent("stderr.log"))
            if output.timedOut { record.status = .timedOut; record.diagnostic = L10n.string("Quarto 渲染超时。") }
            else if output.cancelled || process.isCancelled || Task.isCancelled { record.status = .cancelled }
            else if output.exitCode != 0 { record.status = .failed; record.diagnostic = L10n.string("Quarto 退出码：") + String(output.exitCode) }
            else {
                let values = try? artifact.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                      let size = values?.fileSize, size > 0 else { throw QuartoExportError.missingArtifact }
                try destination.publish(artifact); record.status = .succeeded
            }
        } catch {
            record.status = process.isCancelled || Task.isCancelled ? .cancelled : .failed
            record.diagnostic = error.localizedDescription
        }
        record.finishedAt = Date(); try? save(record); return record
    }
}
