import XCTest
@testable import Rnotebook

final class QuartoExportTests: XCTestCase {
    func testCustomSourceSeparatesOnlyFrontMatterAndRetainsBodyLineOffsets() throws {
        let source = "\u{FEFF}---\r\ntitle: DOCUMENT_TITLE\r\nexecute:\r\n  eval: false\r\n...\r\n\r\n# Body\r\n\r\n```{r}\r\n1+1\r\n```\r\n"
        var options = QuartoExportOptions()
        XCTAssertEqual(try options.renderedSource(source), source)
        options.parameterSource = .custom
        let staged = try options.renderedSource(source)
        XCTAssertEqual(staged, String(repeating: "\n", count: 5) + "\n# Body\n\n```{r}\n1+1\n```\n")
        XCTAssertFalse(staged.contains("DOCUMENT_TITLE"))
        XCTAssertEqual(try options.renderedSource("# Body\r\n"), "# Body\r\n")
        XCTAssertThrowsError(try options.renderedSource("---\ntitle: unclosed\n"))
        options.parameterSource = .yaml
        XCTAssertEqual(try options.renderedSource("---\ntitle: unclosed\n"), "---\ntitle: unclosed\n")
    }

    func testCustomDefaultsAndFormatFallbacksDoNotOverwriteDrafts() throws {
        var options = QuartoExportOptions()
        options.parameterSource = .custom
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: options.metadata()) as? [String: Any])
        XCTAssertEqual(initial["title"] as? String, "")
        XCTAssertEqual(options.language, "")
        XCTAssertNil(initial["lang"])
        XCTAssertEqual(initial["fig-dpi"] as? Double, 300)
        let execution = try XCTUnwrap(initial["execute"] as? [String: Any])
        XCTAssertEqual(execution["eval"] as? Bool, true)
        XCTAssertEqual(execution["message"] as? Bool, false)
        XCTAssertEqual(execution["error"] as? Bool, false)
        options.figureFormat = "svg"; options.tablePrint = "paged"
        options.extraYAMLByFormat = ["html": "title-block-banner: true\n", "pdf": "colorlinks: true\n"]
        options.format = .pdf
        XCTAssertEqual(options.effectiveFigureFormat, "png")
        XCTAssertEqual(options.effectiveTablePrint, "kable")
        XCTAssertEqual(options.additionalYAML, "colorlinks: true\n")
        options.format = .html
        XCTAssertEqual(options.figureFormat, "svg")
        XCTAssertEqual(options.effectiveFigureFormat, "svg")
        XCTAssertEqual(options.effectiveTablePrint, "paged")
        XCTAssertEqual(options.additionalYAML, "title-block-banner: true\n")
        options.format = .docx; options.fontSize = "invalid"; options.lineStretch = "invalid"; options.marginMM = "invalid"
        let word = try XCTUnwrap(JSONSerialization.jsonObject(with: options.metadata()) as? [String: Any])
        XCTAssertNil(word["fontsize"]); XCTAssertNil(word["geometry"])
        options.format = .pdf
        XCTAssertThrowsError(try options.metadata())
        options.parameterSource = .yaml
        XCTAssertNoThrow(try options.metadata())
        XCTAssertEqual(options.additionalYAML, "")
        XCTAssertEqual(options.extraYAMLByFormat.count, 2)
    }

    func testCustomLanguageBlankOmitsOverrideAndExplicitTagUsesTypedMetadataOnly() throws {
        var options = QuartoExportOptions(); options.parameterSource = .custom
        for value in ["", " \n\t "] {
            options.language = value
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: options.metadata()) as? [String: Any])
            XCTAssertNil(metadata["lang"])
            XCTAssertFalse(try options.metadataArguments().contains { $0.hasPrefix("lang:") })
        }
        for value in ["en", "en-US", "zh-CN"] {
            options.language = " " + value + " "
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: options.metadata()) as? [String: Any])
            XCTAssertEqual(metadata["lang"] as? String, value)
            XCTAssertFalse(try options.metadataArguments().contains { $0.hasPrefix("lang:") })
        }
    }

    func testYAMLSourceIgnoresHiddenCustomValuesAndExecutionFlags() throws {
        var options = QuartoExportOptions()
        XCTAssertEqual(options.parameterSource, .yaml)
        options.title = "hidden title"; options.language = "hidden language"
        options.execution = .disabled; options.toc = .yes; options.tocDepth = 99
        options.figureWidth = "nan"; options.pdfFont = "hidden font"
        options.echo = .no; options.codeFold = .yes
        for format in QuartoExportFormat.allCases {
            options.format = format
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: options.metadata()) as? [String: Any])
            XCTAssertEqual(Set(metadata.keys), format == .html ? ["embed-resources"] : format == .pdf ? ["latex-auto-install"] : [])
            XCTAssertTrue(options.executionArguments.isEmpty)
            XCTAssertFalse(try options.metadataArguments().joined().contains("hidden"))
        }
        XCTAssertEqual(options.title, "hidden title", "Custom draft is preserved while inactive")
        options.parameterSource = .custom
        XCTAssertThrowsError(try options.metadata(), "Invalid custom values matter again only when active")
    }

    func testCustomSourceRestoresItsOverridesAfterSwitchingBack() throws {
        var options = QuartoExportOptions()
        options.parameterSource = .custom; options.format = .html
        options.title = "自定义标题"; options.echo = .no; options.execution = .fresh
        options.toc = .yes; options.tocDepth = 4; options.figureWidth = "7.5"
        let before = try options.metadata()
        XCTAssertEqual(options.executionArguments, ["--execute", "--cache-refresh"])
        options.parameterSource = .yaml
        XCTAssertFalse(try options.metadata().elementsEqual(before))
        XCTAssertTrue(options.executionArguments.isEmpty)
        options.parameterSource = .custom
        XCTAssertEqual(try options.metadata(), before)
        XCTAssertEqual(options.executionArguments, ["--execute", "--cache-refresh"])
    }

    private struct Fixture {
        let root: URL
        let document: URL
        let destination: URL
        let job: URL
        let tools: QuartoExportTools
        let source: String

        init(script: String, timeout: TimeInterval = 10,
             source: String = "---\ntitle: 保留正文\n---\n\n正文与外部引用 ![](image.png)\n") throws {
            self.source = source
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Rnotebook-export-boundary-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            document = root.appendingPathComponent("报告.qmd")
            destination = root.appendingPathComponent("report.html")
            job = root.appendingPathComponent("job")
            let renderer = root.appendingPathComponent("renderer.sh")
            let prelude = """
            #!/bin/sh
            set -eu
            output=''
            outdir=''
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --output) output="$2"; shift 2 ;;
                    --output-dir) outdir="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            /bin/mkdir -p "$outdir"
            artifact="$outdir/$output"
            """
            try Data((prelude + "\n" + script + "\n").utf8).write(to: renderer)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: renderer.path)
            tools = .init(quarto: renderer, rscript: URL(fileURLWithPath: "/usr/bin/true"), timeout: timeout)
            try Data(source.utf8).write(to: document)
        }

        func run(process: QuartoProcess = QuartoProcess(), target: QuartoDestination? = nil, tools override: QuartoExportTools? = nil,
                 prepared: @escaping @Sendable (QuartoExportRecord) -> Void = { _ in },
                 log: @escaping @Sendable (Int, Data) -> Void = { _, _ in }) async throws -> QuartoExportRecord {
            await QuartoExportEngine.run(input: .init(source: source, documentURL: document), options: .init(), tools: override ?? tools,
                destination: try target ?? .init(destination, overwrite: false), directory: job,
                process: process, log: log, prepared: prepared)
        }

        func assertPreserved(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: document), Data(source.utf8), file: file, line: line)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix("rnotebook-render-") || $0.hasPrefix(".rnotebook-render-") }
            XCTAssertTrue(leftovers.isEmpty, "Transient render files remain: \(leftovers)", file: file, line: line)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testNonzeroExitPreservesExistingOutputAndDiagnosticLogs() async throws {
        let fixture = try Fixture(script: "printf 'partial' > \"$artifact\"\nprintf 'render stdout\\n'\nprintf 'render failed\\n' >&2\nexit 17")
        defer { fixture.remove() }
        let original = Data("previous successful export".utf8)
        try original.write(to: fixture.destination)
        let result = try await fixture.run(target: .init(fixture.destination, overwrite: true))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.exitCode, 17)
        XCTAssertTrue(result.diagnostic?.contains("17") == true)
        XCTAssertNil(result.artifact)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), original)
        XCTAssertEqual(try String(contentsOf: fixture.job.appendingPathComponent("stderr.log"), encoding: .utf8), "render failed\n")
        let record = try JSONDecoder().decode(QuartoExportRecord.self, from: Data(contentsOf: fixture.job.appendingPathComponent("record.json")))
        XCTAssertEqual(record.status, .failed)
        XCTAssertNotNil(record.finishedAt)
        try fixture.assertPreserved()
    }

    func testSuccessWithoutArtifactFailsWithoutPublishing() async throws {
        let fixture = try Fixture(script: "exit 0")
        defer { fixture.remove() }
        let result = try await fixture.run()
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.diagnostic, QuartoExportError.missingArtifact.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertPreserved()
    }

    func testEmptyArtifactCannotReplacePreviousExport() async throws {
        let fixture = try Fixture(script: ": > \"$artifact\"")
        defer { fixture.remove() }
        let original = Data("previous successful export".utf8)
        try original.write(to: fixture.destination)
        let result = try await fixture.run(target: .init(fixture.destination, overwrite: true))
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.diagnostic, QuartoExportError.missingArtifact.localizedDescription)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), original)
        try fixture.assertPreserved()
    }

    func testChangedDestinationRetainsNewerFileAndGeneratedArtifact() async throws {
        let fixture = try Fixture(script: "printf 'rendered' > \"$artifact\"")
        defer { fixture.remove() }
        try Data("old export".utf8).write(to: fixture.destination)
        let destination = fixture.destination
        let target = try QuartoDestination(destination, overwrite: true)
        let result = try await fixture.run(target: target, prepared: { _ in
            // Simulate another application saving after export was requested.
            try! Data("external edit".utf8).write(to: destination, options: .atomic)
        })
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.diagnostic, QuartoExportError.destinationChanged.localizedDescription)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "external edit")
        XCTAssertEqual(try String(contentsOf: fixture.job.appendingPathComponent("out/report.html"), encoding: .utf8), "rendered")
        try fixture.assertPreserved()
    }

    func testDirectoryAndLinkedArtifactsCannotReplacePreviousExport() async throws {
        for script in ["/bin/mkdir \"$artifact\"", "/bin/ln -s \"$PWD/报告.qmd\" \"$artifact\""] {
            let fixture = try Fixture(script: script)
            defer { fixture.remove() }
            let original = Data("previous successful export".utf8)
            try original.write(to: fixture.destination)
            let result = try await fixture.run(target: .init(fixture.destination, overwrite: true))
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.diagnostic, QuartoExportError.missingArtifact.localizedDescription)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), original)
            try fixture.assertPreserved()
        }
    }

    func testMissingExecutableFailsAndCleansTemporarySource() async throws {
        let fixture = try Fixture(script: "exit 0")
        defer { fixture.remove() }
        let tools = QuartoExportTools(quarto: fixture.root.appendingPathComponent("missing-quarto"), rscript: fixture.tools.rscript)
        let result = try await fixture.run(tools: tools)
        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(result.diagnostic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertPreserved()
    }

    func testCancellationStopsDescendantsAndPreservesOutput() async throws {
        let fixture = try Fixture(script: """
            printf 'partial' > "$artifact"
            (/bin/sleep 1; /usr/bin/touch child-survived) &
            printf 'READY\\n'
            wait
            """)
        defer { fixture.remove() }
        let original = Data("previous successful export".utf8)
        try original.write(to: fixture.destination)
        let process = QuartoProcess()
        let result = try await fixture.run(process: process, target: .init(fixture.destination, overwrite: true), log: { _, _ in
            process.cancel()
        })
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.artifact)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), original)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("child-survived").path))
        try fixture.assertPreserved()
    }

    func testTimeoutKillsRendererThatIgnoresTermination() async throws {
        let fixture = try Fixture(script: "trap '' TERM\nprintf 'partial' > \"$artifact\"\nwhile :; do /bin/sleep 1; done", timeout: 0.15)
        defer { fixture.remove() }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await fixture.run()
        XCTAssertEqual(result.status, .timedOut)
        XCTAssertNil(result.artifact)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertPreserved()
    }

    func testPrecancelledExportNeverStartsRenderer() async throws {
        let fixture = try Fixture(script: "/usr/bin/touch renderer-started\nprintf 'rendered' > \"$artifact\"")
        defer { fixture.remove() }
        let process = QuartoProcess(); process.cancel()
        let result = try await fixture.run(process: process)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("renderer-started").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertPreserved()
    }

    func testLargeLogsKeepDrainingAfterRetentionLimit() async throws {
        let fixture = try Fixture(script: """
            /usr/bin/head -c 1200000 /dev/zero
            /usr/bin/head -c 1200000 /dev/zero >&2
            printf '<html>complete</html>' > "$artifact"
            """)
        defer { fixture.remove() }
        let result = try await fixture.run()
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.logsTruncated)
        for name in ["stdout.log", "stderr.log"] {
            XCTAssertEqual(try Data(contentsOf: fixture.job.appendingPathComponent(name)).count, 1_048_576)
        }
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "<html>complete</html>")
        try fixture.assertPreserved()
    }

    private func realTools() throws -> QuartoExportTools {
        .init(quarto: try XCTUnwrap(QuartoExecutable.locate()),
              rscript: try XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 45)
    }

    func testRealQuartoRErrorPreservesPreviousExport() async throws {
        let fixture = try Fixture(script: "exit 0", source: "```{r}\nstop('EXPORT_FAILURE_SENTINEL')\n```\n")
        defer { fixture.remove() }
        let original = Data("previous successful export".utf8)
        try original.write(to: fixture.destination)
        let result = try await fixture.run(target: .init(fixture.destination, overwrite: true), tools: realTools())
        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.artifact)
        XCTAssertNotEqual(result.exitCode, 0)
        let logs = try ["stdout.log", "stderr.log"].map { try String(contentsOf: fixture.job.appendingPathComponent($0), encoding: .utf8) }.joined()
        XCTAssertTrue(logs.contains("EXPORT_FAILURE_SENTINEL"))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), original)
        try fixture.assertPreserved()
    }

    func testRealQuartoTaskCancellationLeavesInteractiveRSessionUsable() async throws {
        let fixture = try Fixture(script: "exit 0", source: "```{r}\nwriteLines('started', 'render-started')\nSys.sleep(30)\nwriteLines('unexpected', 'render-survived')\n```\n")
        defer { fixture.remove() }
        let tools = try realTools()
        let runtime = RRuntime()
        let worker = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap"))
        _ = try await runtime.start(.init(executable: tools.rscript, workerScript: worker, projectDirectory: fixture.root))
        addTeardownBlock { try await runtime.stop() }
        _ = try await runtime.evaluate(.init(cellID: "before-export", source: "retained_value <- 42L"))

        let process = QuartoProcess()
        let operation = Task { try await fixture.run(process: process, tools: tools) }
        defer { process.cancel(); operation.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        let marker = fixture.root.appendingPathComponent("render-started")
        while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The real render must reach R before cancellation")
        operation.cancel()
        let result = try await operation.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.artifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("render-survived").path))
        let readback = try await runtime.evaluate(.init(cellID: "after-export", source: "stopifnot(retained_value == 42L); cat('INTERACTIVE_SESSION_PRESERVED')"))
        XCTAssertTrue(readback.events.contains { $0.payload.text?.contains("INTERACTIVE_SESSION_PRESERVED") == true })
        try fixture.assertPreserved()
    }
}
