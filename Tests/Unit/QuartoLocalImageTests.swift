import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class QuartoLocalImageTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuartoImages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testLocalInsertionUsesRelativeEscapedPathsAndNativeUndo() throws {
        let root = try folder(), document = root.appendingPathComponent("笔记.qmd")
        let image = root.appendingPathComponent("图片/图 1 % # ?.png")
        let path = RecordLayoutModel.visualImageDestination(image, documentURL: document)
        XCTAssertEqual(path.removingPercentEncoding, "图片/图 1 % # ?.png")
        XCTAssertTrue(path.contains("%25")); XCTAssertTrue(path.contains("%23")); XCTAssertTrue(path.contains("%3F"))
        XCTAssertFalse(path.hasPrefix("file:"))
        let external = root.deletingLastPathComponent().appendingPathComponent("外部.png")
        XCTAssertEqual(RecordLayoutModel.visualImageDestination(external, documentURL: document).removingPercentEncoding, "../外部.png")
        XCTAssertEqual(RecordLayoutModel.visualImageDestination(URL(string: "https://example.invalid/a%20b.png")!, documentURL: document), "https://example.invalid/a%20b.png")
        let model = RecordLayoutModel(initialSource: "before\n", usesProcessArguments: false)
        model.documentURL = document
        let host = RecordNativeEditorHost(model: model)
        defer { host.detach() }
        host.editor.setSelectedRange(NSRange(location: 7, length: 0))
        let anchor = try XCTUnwrap(model.captureVisualInsertion(for: .imageReference))
        XCTAssertTrue(model.insertVisualLinkedImage(url: image.absoluteString, description: "图片", anchor: anchor))
        host.publishCommittedText()
        XCTAssertEqual(model.source, "before\n![图片](<\(path)>)")
        host.undoSource(nil); XCTAssertEqual(model.source, "before\n")
        XCTAssertEqual(model.notebook.state, .notStarted)
    }

    func testNormalizerLeavesRemoteURLsCodeMetadataAndOrdinaryPathsUntouched() async throws {
        let root = try folder()
        let filter = try XCTUnwrap(Bundle.main.url(forResource: "local-images", withExtension: "lua", subdirectory: "Quarto"))
        let source = "---\ntitle: file:///tmp/title.png\n---\n\n![](https://example.invalid/a.png) ![](data:image/png;base64,AAAA) ![](file://server/share/a.png) ![](relative.png)\n\n`file:///tmp/code.png`\n"
        var outputs: [Data] = []
        for filtered in [false, true] {
            let args = ["pandoc", "--from", "markdown", "--to", "json"] + (filtered ? ["--lua-filter", filter.path] : [])
            let result = try await QuartoProcess().run(executable: XCTUnwrap(QuartoExecutable.locate()), arguments: args,
                directory: root, environment: ProcessInfo.processInfo.environment, timeout: 20, input: Data(source.utf8))
            XCTAssertEqual(result.exitCode, 0, String(decoding: result.stderr, as: UTF8.self))
            outputs.append(result.stdout)
        }
        XCTAssertEqual(outputs[0], outputs[1])
    }

    func testNormalizerEncodesCompleteUTF8BytesUnderChineseLocale() async throws {
        let root = try folder(), image = root.appendingPathComponent("中文 图%25.png")
        let filter = try XCTUnwrap(Bundle.main.url(forResource: "local-images", withExtension: "lua", subdirectory: "Quarto"))
        let wrapper = root.appendingPathComponent("locale.lua")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(decoding: try encoder.encode(filter.path), as: UTF8.self)
        try Data("assert(os.setlocale('zh_CN.UTF-8', 'ctype'))\nreturn dofile(\(quoted))\n".utf8).write(to: wrapper)
        let result = try await QuartoProcess().run(executable: XCTUnwrap(QuartoExecutable.locate()),
            arguments: ["pandoc", "--from", "markdown", "--to", "json", "--lua-filter", wrapper.path],
            directory: root, environment: ProcessInfo.processInfo.environment, timeout: 20,
            input: Data("![](<\(image.absoluteString)>)\n".utf8))
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.stderr, as: UTF8.self))
        let json = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(json.contains("%E4%B8%AD%E6%96%87%20%E5%9B%BE%2525.png"), json)
        XCTAssertFalse(json.contains("\u{FFFD}"))
    }

    func testRealHTMLImagesEmbedExactBytesInBothModesAndCompatibilityStates() async throws {
        let root = try folder(), base = root.appendingPathComponent("中文笔记")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = root.appendingPathComponent("外部 图像 %25 # 1.png")
        try bytes.write(to: image)
        let document = base.appendingPathComponent("复杂验证.qmd")
        let relative = RecordLayoutModel.visualImageDestination(image, documentURL: document)
        let localhost = image.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/")
        let sources = [image.absoluteString, localhost, relative]
        let body = sources.enumerated().map { "![IMAGE_\($0.offset)](<\($0.element)>){width=24px}" }.joined(separator: "\n\n")
        let source = "---\ntitle: Images\nfilters: [quarto, user.lua]\n---\n\nUSER_TOKEN\n\n" + body + "\n"
        try Data(source.utf8).write(to: document)
        try Data("function Str(el) if el.text == 'USER_TOKEN' then return pandoc.Str('USER_FILTER_OK') end end".utf8)
            .write(to: base.appendingPathComponent("user.lua"))
        for mode in [QuartoParameterSource.yaml, .custom] {
            for enabled in [true, false] {
                var options = QuartoExportOptions()
                options.parameterSource = mode; options.edmundCompatibility = enabled
                options.execution = .disabled; options.language = "en"
                if mode == .custom { options.extraYAMLByFormat["html"] = "filters: [quarto, user.lua]\n" }
                let name = mode.rawValue + "-" + String(enabled), job = root.appendingPathComponent(name)
                let output = root.appendingPathComponent(name + ".html")
                let result = try await QuartoExportEngine.run(input: .init(source: source, documentURL: document), options: options,
                    tools: .init(quarto: XCTUnwrap(QuartoExecutable.locate()), rscript: XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 60),
                    destination: .init(output, overwrite: false), directory: job, process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
                let logs = ["stdout.log", "stderr.log"].compactMap { try? String(contentsOf: job.appendingPathComponent($0), encoding: .utf8) }.joined()
                XCTAssertEqual(result.status, .succeeded, "\(name): \(logs)")
                guard result.status == .succeeded else { continue }
                let html = try String(contentsOf: output, encoding: .utf8)
                let encoded = "data:image/png;base64," + bytes.base64EncodedString()
                XCTAssertEqual(html.components(separatedBy: encoded).count - 1, sources.count, "\(name): embedded images must match original bytes")
                XCTAssertTrue(html.contains("USER_FILTER_OK"))
                XCTAssertFalse(logs.contains("Could not fetch resource"), logs)
                XCTAssertNotNil(result.resourceHashes["Quarto/local-images.lua"])
                XCTAssertEqual(result.resourceHashes["Quarto/edmund-compat.lua"] != nil, enabled)
                XCTAssertEqual(try Data(contentsOf: document), Data(source.utf8))
                XCTAssertEqual(try Data(contentsOf: image), bytes)
            }
        }
    }
}
