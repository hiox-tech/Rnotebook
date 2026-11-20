import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class ExportWorkflowTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportWorkflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func tools() throws -> QuartoExportTools {
        .init(quarto: try XCTUnwrap(QuartoExecutable.locate()), rscript: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 60)
    }
    func testRealCustomBlankAndExplicitLanguageTagsHaveNoInvalidLanguageWarning() async throws {
        let root = try folder(), document = root.appendingPathComponent("language.qmd")
        let source = "# Language verification\n\nBody.\n"
        try Data(source.utf8).write(to: document)
        for language in ["", "en", "en-US", "zh-CN"] {
            var options = QuartoExportOptions(); options.parameterSource = .custom
            options.language = language; options.execution = .disabled
            let name = language.isEmpty ? "default" : language
            let output = root.appendingPathComponent(name + ".html"), job = root.appendingPathComponent(name)
            let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: document), options: options,
                tools: try tools(), destination: try .init(output, overwrite: false), directory: job,
                process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
            let logs = ["stdout.log", "stderr.log"].compactMap { try? String(contentsOf: job.appendingPathComponent($0), encoding: .utf8) }.joined()
            XCTAssertEqual(result.status, .succeeded, logs)
            guard result.status == .succeeded else { continue }
            XCTAssertFalse(logs.contains("Invalid 'lang'"), logs)
            let html = try String(contentsOf: output, encoding: .utf8)
            XCTAssertTrue(html.contains("lang=\"\(language.isEmpty ? "en" : language)\""))
            XCTAssertEqual(try Data(contentsOf: document), Data(source.utf8))
        }
    }
    func testRealCustomFormatsIgnoreDocumentYAMLAndKeepSourceUnchanged() async throws {
        let root = try folder(), url = root.appendingPathComponent("custom.qmd")
        let source = "---\ntitle: IGNORED_DOCUMENT_TITLE\nexecute:\n  eval: false\n---\n\n# Stage section\n\n```{r}\nstage_value <- 17L\ncat('STAGE_CUSTOM_RESULT', stage_value)\nmessage('STAGE_HIDDEN_MESSAGE')\n```\n"
        try Data(source.utf8).write(to: url)
        for format in QuartoExportFormat.allCases {
            var options = QuartoExportOptions()
            options.parameterSource = .custom; options.format = format
            options.language = "en"; options.echo = .no; options.openAfterExport = false
            let output = root.appendingPathComponent("custom-" + format.rawValue + "." + format.fileExtension)
            let job = root.appendingPathComponent("job-" + format.rawValue)
            let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options,
                tools: try tools(), destination: try .init(output, overwrite: false), directory: job,
                process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
            let logs = ["stdout.log", "stderr.log"].compactMap { try? String(contentsOf: job.appendingPathComponent($0), encoding: .utf8) }.joined()
            XCTAssertEqual(result.status, .succeeded, "\(format): \(result.diagnostic ?? "") \(logs)")
            guard result.status == .succeeded else { continue }
            let data = try Data(contentsOf: output)
            XCTAssertGreaterThan(data.count, 500)
            if format == .html {
                let html = String(decoding: data, as: UTF8.self)
                XCTAssertFalse(html.contains("fonts.googleapis.com"))
                XCTAssertTrue(html.contains("STAGE_CUSTOM_RESULT 17"))
                XCTAssertFalse(html.contains("IGNORED_DOCUMENT_TITLE"))
                XCTAssertFalse(html.contains("STAGE_HIDDEN_MESSAGE"))
                XCTAssertFalse(html.contains("stage_value &lt;-"))
            } else if format == .docx { XCTAssertTrue(data.starts(with: [0x50, 0x4b])) }
            else { XCTAssertTrue(data.starts(with: Data("%PDF-".utf8))) }
            XCTAssertNotEqual(result.renderedSourceHash, result.sourceHash)
            XCTAssertEqual(try Data(contentsOf: url), Data(source.utf8))
        }
    }
    func testRealMessageOptionIsIndependentOfWarningsAndRespectsHiddenOutput() async throws {
        let root = try folder(), url = root.appendingPathComponent("messages.qmd")
        let source = "```{r}\ncat('VISIBLE_RESULT')\nmessage('VISIBLE_MESSAGE')\nwarning('HIDDEN_WARNING')\n```\n"
        try Data(source.utf8).write(to: url)
        for outputVisible in [true, false] {
            var options = QuartoExportOptions()
            options.parameterSource = .custom; options.language = "en"; options.echo = .no
            options.message = true; options.warning = .no; options.output = outputVisible
            let output = root.appendingPathComponent("messages-\(outputVisible).html")
            let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options,
                tools: try tools(), destination: try .init(output, overwrite: false), directory: root.appendingPathComponent("job-\(outputVisible)"),
                process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
            XCTAssertEqual(result.status, .succeeded, result.diagnostic ?? "")
            guard result.status == .succeeded else { continue }
            let html = try String(contentsOf: output, encoding: .utf8)
            XCTAssertEqual(html.contains("VISIBLE_MESSAGE"), outputVisible)
            XCTAssertEqual(html.contains("VISIBLE_RESULT"), outputVisible)
            XCTAssertFalse(html.contains("HIDDEN_WARNING"))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
        }
    }
    func testRealYAMLSourceUsesDocumentSettingsAndSelectedFormatWithoutCustomLeaks() async throws {
        let root = try folder(), url = root.appendingPathComponent("yaml.qmd")
        let source = "---\ntitle: YAML_SOURCE_TITLE\nformat: docx\ntoc: true\nexecute:\n  echo: false\n---\n\n# Section\n\n```{r}\nsecret_source <- 42L\ncat('YAML_RESULT', secret_source)\n```\n"
        try Data(source.utf8).write(to: url)
        var options = QuartoExportOptions()
        options.format = .html; options.openAfterExport = false
        options.title = "HIDDEN_CUSTOM_TITLE"; options.execution = .disabled
        options.echo = .yes; options.toc = .no; options.figureWidth = "nan"
        let output = root.appendingPathComponent("yaml.html")
        let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options,
            tools: try tools(), destination: try .init(output, overwrite: false), directory: root.appendingPathComponent("job"),
            process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
        XCTAssertEqual(result.status, .succeeded, result.diagnostic ?? "")
        XCTAssertEqual(result.parameterSource, .yaml)
        XCTAssertFalse(result.arguments.contains("--no-execute"))
        XCTAssertFalse(result.arguments.contains("--cache-refresh"))
        let html = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(html.contains("YAML_SOURCE_TITLE")); XCTAssertTrue(html.contains("YAML_RESULT 42"))
        XCTAssertTrue(html.contains("TOC")); XCTAssertFalse(html.contains("secret_source"))
        XCTAssertFalse(html.contains("HIDDEN_CUSTOM_TITLE"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
    func testRealHTMLFormattingOverridesDoNotRewriteQMD() async throws {
        let root = try folder(), url = root.appendingPathComponent("format.qmd")
        let source = "---\ntitle: Original\nexecute:\n  echo: true\n---\n\n# Section\n\n```{r}\nsecret_source <- 42L\ncat('RESULT_VISIBLE', secret_source)\n```\n"
        try Data(source.utf8).write(to: url)
        var options = QuartoExportOptions()
        options.parameterSource = .custom
        options.title = "格式标题"; options.language = "zh-CN"; options.echo = .no
        options.toc = .yes; options.numbering = .yes; options.openAfterExport = false
        let output = root.appendingPathComponent("report.html")
        let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options,
            tools: try tools(), destination: try .init(output, overwrite: false), directory: root.appendingPathComponent("job"),
            process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
        XCTAssertEqual(result.status, .succeeded, result.diagnostic ?? "")
        let html = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(html.contains("格式标题"))
        XCTAssertTrue(html.contains("lang=\"zh-CN\""), String(html.prefix(200)))
        XCTAssertTrue(html.contains("RESULT_VISIBLE 42")); XCTAssertFalse(html.contains("secret_source"))
        XCTAssertTrue(html.contains("TOC")); XCTAssertTrue(html.contains("header-section-number"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
    func testLiteralTitleWithQuotesAndColonIsNotParsedAsYAMLOrHTML() async throws {
        let root = try folder(), url = root.appendingPathComponent("literal.qmd"), source = "---\ntitle: Original\n---\n\nBody.\n"
        try Data(source.utf8).write(to: url)
        var options = QuartoExportOptions(); options.parameterSource = .custom; options.execution = .disabled; options.openAfterExport = false
        options.title = "'Tis a report: \"引号\" & <标题>"
        let output = root.appendingPathComponent("literal.html")
        let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options,
            tools: try tools(), destination: try .init(output, overwrite: false), directory: root.appendingPathComponent("job"),
            process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
        XCTAssertEqual(result.status, .succeeded, result.diagnostic ?? "")
        let html = try String(contentsOf: output, encoding: .utf8)
        let start = try XCTUnwrap(html.range(of: "<title>")), end = try XCTUnwrap(html.range(of: "</title>"))
        var title = String(html[start.upperBound..<end.lowerBound])
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&")] { title = title.replacingOccurrences(of: entity, with: value) }
        XCTAssertEqual(title, options.title)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
    func testExporterKeepsSnapshotDetectsChangesAndDoesNotOpenWhenDisabled() async throws {
        let root = try folder(), model = RecordLayoutModel(initialSource: "original snapshot", usesProcessArguments: false)
        model.documentURL = root.appendingPathComponent("source.qmd")
        let runner = root.appendingPathComponent("renderer.sh")
        let script = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            case "$1" in --output-dir) folder="$2"; shift 2;; --output) output="$2"; shift 2;; *) shift;; esac
        done
        /bin/mkdir -p "$folder"
        /bin/sleep 0.2
        printf '<html>snapshot export</html>' > "$folder/$output"
        """
        try Data(script.utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        let exporter = model.exporter
        exporter.outputRoot = root.appendingPathComponent("jobs")
        exporter.toolOverride = .init(quarto: runner, rscript: URL(fileURLWithPath: "/usr/bin/true"))
        var opened = 0; exporter.openArtifact = { _ in opened += 1; return true }
        var options = QuartoExportOptions(); options.openAfterExport = false
        let output = root.appendingPathComponent("report.html")
        exporter.start(options: options, destination: output)
        XCTAssertTrue(exporter.isRunning)
        exporter.start(options: options, destination: root.appendingPathComponent("second.html"))
        XCTAssertEqual(exporter.diagnostic, QuartoExportError.busy.localizedDescription)
        model.source = "changed while rendering"
        await exporter.waitUntilIdle()
        XCTAssertFalse(exporter.isRunning); XCTAssertEqual(exporter.record?.status, .succeeded)
        XCTAssertTrue(exporter.record?.sourceChanged == true); XCTAssertEqual(opened, 0)
        let cached = try XCTUnwrap(exporter.record?.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path), "Successful managed exports must remove their task cache")
        XCTAssertNil(exporter.taskFilesURL, "Removed task directories must not retain a broken Finder action")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "Published user output must remain")
        XCTAssertEqual(exporter.record?.sourceHash, DocumentRevision(text: "original snapshot").rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.html").path))
    }
    func testMissingQuartoAndInvalidOptionsDoNotBlockEditingOrR() async throws {
        let root = try folder(), doc = QMDDocument(recoveryStore: .init(directory: root.appendingPathComponent("recovery")))
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.model.source = "```{r}\ncat('R_WITHOUT_QUARTO')\n```\n"
        try await doc.save(to: root.appendingPathComponent("source.qmd"), ofType: "org.quarto.qmd", for: .saveOperation)
        let exporter = doc.model.exporter
        exporter.toolOverride = .init(quarto: root.appendingPathComponent("missing-quarto"), rscript: try tools().rscript)
        exporter.outputRoot = root.appendingPathComponent("jobs")
        var options = QuartoExportOptions(); options.parameterSource = .custom; options.figureWidth = "nan"
        exporter.start(options: options, destination: root.appendingPathComponent("report.html"))
        XCTAssertFalse(exporter.isRunning); XCTAssertNotNil(exporter.diagnostic)
        options.figureWidth = "6.5"
        exporter.start(options: options, destination: root.appendingPathComponent("report.html"))
        await exporter.waitUntilIdle()
        XCTAssertEqual(exporter.record?.status, .failed)
        let failedDirectory = try XCTUnwrap(exporter.record?.directory)
        XCTAssertEqual(exporter.taskFilesURL, failedDirectory)
        let retained = Set(try FileManager.default.contentsOfDirectory(atPath: failedDirectory.path))
        XCTAssertTrue(retained.isSubset(of: ["owner.json", "lease.lock", "record.json", "stdout.log", "stderr.log"]))
        XCTAssertTrue(retained.contains("record.json"))
        XCTAssertFalse(retained.contains("metadata.json"))
        doc.model.source += "\n可继续编辑\n"
        doc.model.runAllNotebookCells(); await doc.model.notebook.waitUntilIdle()
        XCTAssertEqual(doc.model.notebook.completedCount, 1, doc.model.notebook.diagnostic ?? "")
        await doc.model.notebook.shutdown()
    }
    func testExportCannotOverwriteItsSourceQMD() async throws {
        let root = try folder(), url = root.appendingPathComponent("source.qmd"), source = "正文必须保留"
        try Data(source.utf8).write(to: url)
        let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: .init(),
            tools: try tools(), destination: try .init(url, overwrite: true), directory: root.appendingPathComponent("job"),
            process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.diagnostic?.contains("QMD") == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
    func testLaTeXPDFProducesPDFOrReportsMissingTeXWithoutInstalling() async throws {
        let root = try folder(), url = root.appendingPathComponent("latex.qmd"), source = "# PDF acceptance\n\nA simple equation: $x^2$.\n"
        try Data(source.utf8).write(to: url)
        var options = QuartoExportOptions(); options.format = .pdf; options.openAfterExport = false
        let job = root.appendingPathComponent("job"), output = root.appendingPathComponent("report.pdf")
        let result = await QuartoExportEngine.run(input: .init(source: source, documentURL: url), options: options,
            tools: try tools(), destination: try .init(output, overwrite: false), directory: job,
            process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
        let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".local/validation/latex-pdf-runs/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let logs = try ["stdout.log", "stderr.log"].map { try String(contentsOf: job.appendingPathComponent($0), encoding: .utf8) }.joined()
        try Data(logs.utf8).write(to: evidence.appendingPathComponent("latex-pdf.log"))
        if result.status == .succeeded {
            XCTAssertTrue(try Data(contentsOf: output).starts(with: Data("%PDF-".utf8)))
        } else {
            XCTAssertEqual(result.status, .failed)
            XCTAssertTrue(logs.lowercased().contains("no tex installation") || logs.lowercased().contains("not found") || logs.lowercased().contains("not installed"), logs)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let report: [String: Any] = ["status": result.status.rawValue, "producedPDF": result.status == .succeeded,
                                   "diagnostic": result.diagnostic ?? "", "log": "latex-pdf.log"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("latex-pdf.json"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
}
