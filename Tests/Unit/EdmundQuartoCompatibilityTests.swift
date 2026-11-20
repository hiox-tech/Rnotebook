import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import Rnotebook

@MainActor final class EdmundQuartoCompatibilityTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EdmundQuarto-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func filter() throws -> URL {
        try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "edmund-compat", withExtension: "lua", subdirectory: "Quarto"))
    }
    private func ast(_ source: String, filtered: Bool = true) async throws -> [String: Any] {
        let root = try folder()
        var args = ["pandoc", "--from", "markdown", "--to", "json"]
        if filtered { args += ["--lua-filter", try filter().path] }
        let result = try await QuartoProcess().run(executable: XCTUnwrap(QuartoExecutable.locate()), arguments: args,
            directory: root, environment: ProcessInfo.processInfo.environment, timeout: 20, input: Data(source.utf8))
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.stderr, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    }
    private func nodes(_ value: Any, _ type: String) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            return (object["t"] as? String == type ? [object] : []) + object.values.flatMap { nodes($0, type) }
        }
        if let array = value as? [Any] { return array.flatMap { nodes($0, type) } }
        return []
    }
    private func text(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            if object["t"] as? String == "Str" { return object["c"] as? String ?? "" }
            return object.values.map { text($0) }.joined(separator: " ")
        }
        if let array = value as? [Any] { return array.map { text($0) }.joined(separator: " ") }
        return ""
    }
    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func testHighlightAndCommentsPreserveInlineFormattingAndOpaqueNodes() async throws {
        let result = try await ast("==high **bold** `code`== and **==nested==** %%PRIVATE *italic*%%\n\n`==literal== %%literal%% [[literal]]` $x == y$\n\n```r\n%%code%%\n==code==\n```\n")
        let marks = nodes(result, "Span").filter { (($0["c"] as? [Any])?.first as? [Any])?[1] as? [String] == ["mark"] }
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(nodes(marks, "Strong").count, 1)
        XCTAssertEqual(nodes(marks, "Code").count, 1)
        XCTAssertFalse(text(result).contains("PRIVATE"))
        XCTAssertTrue(nodes(result, "Code").contains { ($0["c"] as? [Any])?.last as? String == "==literal== %%literal%% [[literal]]" })
        XCTAssertEqual((nodes(result, "CodeBlock").first?["c"] as? [Any])?.last as? String, "%%code%%\n==code==")
        XCTAssertEqual((nodes(result, "Math").first?["c"] as? [Any])?.last as? String, "x == y")
        let mixed = try await ast("==[[Note]] %%PRIVATE_NESTED%% **bold**==\n")
        XCTAssertEqual(nodes(mixed, "Link").count, 1)
        XCTAssertFalse(text(mixed).contains("PRIVATE_NESTED"))
        let crossing = try await ast("before %%**PRIVATE_CROSS%% visible** after\n\n**start %%PRIVATE_OTHER** hidden%% end\n")
        XCTAssertFalse(text(crossing).contains("PRIVATE"))
        for expected in ["before", "visible", "after", "start", "end"] { XCTAssertTrue(text(crossing).contains(expected)) }
    }

    func testCommentsAcrossBlocksAreLocalAndMetadataRemainsUntouched() async throws {
        let source = "---\ntitle: '==YAML_TITLE=='\ncustom: '%%YAML_VALUE%%'\n---\n\nvisible\n\n%% start\n\n# PRIVATE_HEADING\n\nPRIVATE_BODY\n\n%% tail\n\n> %% PRIVATE_QUOTE\n>\n> PRIVATE_QUOTE_BODY\n\noutside\n\ninline %%unclosed\n"
        let result = try await ast(source)
        let baseline = try await ast(source, filtered: false)
        XCTAssertEqual(try canonical(XCTUnwrap(result["meta"])), try canonical(XCTUnwrap(baseline["meta"])))
        let body = text(result["blocks"] as Any)
        XCTAssertFalse(body.contains("PRIVATE"))
        for expected in ["visible", "tail", "outside", "%%unclosed"] { XCTAssertTrue(body.contains(expected), expected) }
        let unclosed = try await ast("before\n\n%% start\n\nHIDDEN_TO_EOF\n")
        XCTAssertTrue(text(unclosed).contains("before"))
        XCTAssertFalse(text(unclosed).contains("HIDDEN_TO_EOF"))
    }

    func testAllKnownCalloutTypesMapAndUnknownQuoteRemainsLiteral() async throws {
        let mapping = ["note":"note", "tip":"tip", "important":"important", "warning":"warning", "caution":"caution",
            "hint":"tip", "abstract":"note", "summary":"note", "tldr":"note", "info":"note", "todo":"note",
            "success":"tip", "check":"tip", "done":"tip", "question":"warning", "help":"warning", "faq":"warning",
            "attention":"warning", "failure":"caution", "fail":"caution", "missing":"caution", "danger":"caution",
            "error":"caution", "bug":"caution", "example":"note", "quote":"note", "cite":"note"]
        for (kind, mapped) in mapping {
            let result = try await ast("> [!\(kind.uppercased())]- Custom **title**\n> body\n>\n> - list\n")
            let div = try XCTUnwrap(nodes(result, "Div").first)
            let content = try XCTUnwrap(div["c"] as? [Any])
            let attr = try XCTUnwrap(content.first as? [Any])
            XCTAssertEqual(attr[1] as? [String], ["callout-" + mapped])
            let attrs = try XCTUnwrap(attr[2] as? [[String]])
            XCTAssertTrue(attrs.contains(["collapse", "true"]))
            XCTAssertTrue(attrs.contains(["data-edmund-callout", kind]))
            XCTAssertEqual(nodes(div, "Strong").count, 1)
            XCTAssertEqual(nodes(div, "BulletList").count, 1)
            XCTAssertFalse(text(div).contains("[!"))
        }
        let unknown = try await ast("> [!unknown]+ Title\n> body\n")
        XCTAssertEqual(nodes(unknown, "BlockQuote").count, 1)
        XCTAssertTrue(text(unknown).contains("[!unknown]+"))
    }

    func testExpandedAndNestedCalloutsKeepAllBodyBlocks() async throws {
        let result = try await ast("> [!note]+\n> first\n>\n> > [!tip] Nested\n> > inner\n>\n> last\n")
        XCTAssertEqual(nodes(result, "Div").count, 2)
        XCTAssertTrue(text(result).contains("Note"))
        for expected in ["first", "inner", "last"] { XCTAssertTrue(text(result).contains(expected)) }
        let data = String(decoding: try canonical(result), as: UTF8.self)
        XCTAssertTrue(data.contains("\"collapse\",\"false\""))
    }

    func testWikiLinksImagesAndBlockAnchorsUseOrdinaryDestinations() async throws {
        let result = try await ast("# Heading Name\n\n[[Note]] [[path/file.qmd#Heading|别名]] [[#Heading Name|local]] [[#^block-id|block]] ![[photo.png|200x100]] ![[note.qmd]]\n\nbody ^block-id\n")
        let links = nodes(result, "Link")
        XCTAssertEqual(links.count, 4)
        let targets = links.compactMap { (($0["c"] as? [Any])?.last as? [String])?.first }
        XCTAssertEqual(targets, ["Note", "path/file.qmd#Heading", "#heading-name", "#block-id"])
        let image = try XCTUnwrap(nodes(result, "Image").first?["c"] as? [Any])
        let attrs = try XCTUnwrap(image[0] as? [Any])[2] as? [[String]]
        XCTAssertEqual(attrs, [["width", "200px"], ["height", "100px"]])
        XCTAssertEqual(image.last as? [String], ["photo.png", ""])
        XCTAssertTrue(text(result).contains("![[note.qmd]]"))
        let spans = nodes(result, "Span").compactMap { ($0["c"] as? [Any])?.first as? [Any] }
        XCTAssertTrue(spans.contains { $0.first as? String == "block-id" })
        XCTAssertFalse(text(result).contains("^block-id"))
    }

    func testImageSizesCleanRichAndImplicitCaptionsAndRespectExplicitAttributes() async throws {
        let result = try await ast("![**caption**|200x100](image.png)\n\n![other|300](image.png){width=40px}\n\n![invalid|0](image.png)\n")
        let images = nodes(result, "Image")
        XCTAssertEqual(images.count, 3)
        XCTAssertFalse(text(images[0]).contains("|200"))
        XCTAssertEqual(nodes(images[0], "Strong").count, 1)
        let data = String(decoding: try canonical(images[1]), as: UTF8.self)
        XCTAssertTrue(data.contains("40px")); XCTAssertFalse(data.contains("300px"))
        XCTAssertTrue(text(images[2]).contains("invalid|0"))
        let figures = nodes(result, "Figure")
        XCTAssertFalse(text(figures[0]).contains("|200"))
        let styledSize = try await ast("![caption|**200**](image.png)\n")
        XCTAssertTrue(text(styledSize).contains("caption|"))
        XCTAssertEqual(nodes(styledSize, "Strong").count, 2) // image and implicit caption
    }

    func testSimpleHTMLFormatsBecomePortableNodesAndKeepUnsupportedRawHTML() async throws {
        let result = try await ast("<u>under **bold**</u> <mark>marked</mark> <sub>2</sub> <sup>3</sup> <kbd>key</kbd> <small>small</small> <span data-x='keep'>raw</span> <img src='image.png' alt='A &amp; B' width='200'>\n")
        for kind in ["Underline", "Subscript", "Superscript", "Image", "Strong"] { XCTAssertEqual(nodes(result, kind).count, 1, kind) }
        XCTAssertEqual(nodes(result, "Span").count, 4) // mark/kbd/small + native span
        let image = try XCTUnwrap(nodes(result, "Image").first)
        XCTAssertTrue(text(image).contains("A")); XCTAssertTrue(text(image).contains("B"))
        let escaped = try await ast("`<mark>literal</mark>` $x_{<u>}$ <mark>unclosed\n")
        XCTAssertEqual(nodes(escaped, "Code").count, 1)
        XCTAssertEqual(nodes(escaped, "Math").count, 1)
        XCTAssertEqual(nodes(escaped, "RawInline").count, 1)
    }

    func testNativeMarkdownAndQuartoConstructsAreUnchanged() async throws {
        let source = "# Heading {#explicit}\n\n**bold** *italic* ~~strike~~ [link](file.qmd) $a^2$ [^n]\n\n- [x] task\n\n[^n]: footnote\n\n::: {.callout-note}\nNative callout\n:::\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```mermaid\ngraph TD; A-->B\n```\n\n```{r}\nx <- '%%not a comment%%'\n```\n"
        let filtered = try await ast(source)
        let baseline = try await ast(source, filtered: false)
        XCTAssertEqual(try canonical(filtered), try canonical(baseline))
    }

    func testCompatibilityDefaultsOnAndCanBeDisabledWithoutAffectingUserFilters() async throws {
        XCTAssertTrue(QuartoExportOptions().edmundCompatibility)
        let root = try folder(), document = root.appendingPathComponent("toggle.qmd")
        let user = root.appendingPathComponent("user.lua")
        try Data("function Str(el) if el.text == 'USER_TOKEN' then return pandoc.Str('USER_APPLIED') end end".utf8).write(to: user)
        for mode in [QuartoParameterSource.yaml, .custom] {
            let source = (mode == .yaml ? "---\nfilters: [user.lua]\n---\n\n" : "")
                + "==VISIBLE_MARK== %%HIDDEN_COMMENT%% USER_TOKEN\n\n> [!tip] Title\n> body\n"
            try Data(source.utf8).write(to: document)
            for enabled in [true, false] {
                var options = QuartoExportOptions(); options.parameterSource = mode
                options.edmundCompatibility = enabled; options.execution = .disabled
                if mode == .custom { options.extraYAMLByFormat["html"] = "filters: ['\(user.path)']\n" }
                let job = root.appendingPathComponent("\(mode.rawValue)-\(enabled)")
                let output = job.appendingPathExtension("html")
                let result = try await QuartoExportEngine.run(input: .init(source: source, documentURL: document), options: options,
                    tools: .init(quarto: XCTUnwrap(QuartoExecutable.locate()), rscript: XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 30),
                    destination: .init(output, overwrite: false), directory: job, process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
                XCTAssertEqual(result.status, .succeeded, result.diagnostic ?? "")
                guard result.status == .succeeded else { continue }
                let html = try String(contentsOf: output, encoding: .utf8)
                if mode == .custom {
                    XCTAssertFalse(html.contains("fonts.googleapis.com"), "Default custom HTML must not download theme fonts during resource embedding")
                    XCTAssertNotNil(result.resourceHashes["Quarto/local-fonts.scss"])
                } else {
                    XCTAssertNil(result.resourceHashes["Quarto/local-fonts.scss"], "Document YAML styling must not receive app font overrides")
                }
                XCTAssertEqual(result.edmundCompatibility, enabled)
                XCTAssertEqual(html.contains("<mark>VISIBLE_MARK</mark>"), enabled)
                XCTAssertEqual(html.contains("HIDDEN_COMMENT"), !enabled)
                XCTAssertEqual(html.contains("callout-title"), enabled)
                XCTAssertTrue(html.contains("USER_APPLIED"))
                XCTAssertEqual(result.resourceHashes["Quarto/edmund-compat.lua"] != nil, enabled)
                XCTAssertEqual(FileManager.default.fileExists(atPath: job.appendingPathComponent("edmund-compat.lua").path), enabled)
                XCTAssertEqual(try Data(contentsOf: document), Data(source.utf8))
            }
        }
    }

    func testCompatibilityMergesWithUserFiltersEvenAfterQuartoMarker() async throws {
        let root = try folder(), document = root.appendingPathComponent("source.qmd")
        let userFilter = root.appendingPathComponent("user.lua")
        try Data("function Str(el) if el.text == 'USER_FILTER_TOKEN' then return pandoc.Str('USER_FILTER_APPLIED') end end".utf8).write(to: userFilter)
        for mode in [QuartoParameterSource.yaml, .custom] {
            // Custom starts without front matter to cover the extra staging
            // header and recorded source-line offset as well.
            let source = (mode == .yaml ? "---\nfilters:\n  - quarto\n  - user.lua\n---\n\n" : "")
                + "> [!tip] Title\n> USER_FILTER_TOKEN\n"
            try Data(source.utf8).write(to: document)
            var options = QuartoExportOptions()
            options.parameterSource = mode; options.execution = .disabled
            if mode == .custom {
                options.extraYAMLByFormat["html"] = "filters:\n  - quarto\n  - '\(userFilter.path)'\nheader-includes:\n  - '<meta name=\"CUSTOM_EXTRA_HEADER\" content=\"retained\">'\n"
            }
            let job = root.appendingPathComponent(mode.rawValue)
            let output = root.appendingPathComponent(mode.rawValue + ".html")
            let result = try await QuartoExportEngine.run(input: .init(source: source, documentURL: document), options: options,
                tools: .init(quarto: XCTUnwrap(QuartoExecutable.locate()), rscript: XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 30),
                destination: .init(output, overwrite: false), directory: job, process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
            XCTAssertEqual(result.status, .succeeded, result.diagnostic ?? "")
            guard result.status == .succeeded else { continue }
            let html = try String(contentsOf: output, encoding: .utf8)
            XCTAssertTrue(html.contains("callout-title"))
            let logs = ["stdout.log", "stderr.log"].compactMap { try? String(contentsOf: job.appendingPathComponent($0), encoding: .utf8) }.joined()
            XCTAssertTrue(html.contains("USER_FILTER_APPLIED"), "\(mode.rawValue): \(logs)")
            XCTAssertFalse(html.contains("USER_FILTER_TOKEN"), mode.rawValue)
            if mode == .custom {
                XCTAssertEqual(result.renderedSourceLineOffset, 3)
                XCTAssertTrue(html.contains("CUSTOM_EXTRA_HEADER"))
            }
            XCTAssertEqual(try Data(contentsOf: document), Data(source.utf8))
        }
    }

    func testRealYAMLAndCustomExportsConvertAcrossAllFourFormatsWithoutChangingQMD() async throws {
        let root = try folder(), document = root.appendingPathComponent("source.qmd")
        let source = "---\ntitle: KEEP_YAML_TITLE\npdf-engine: xelatex\nexecute:\n  eval: false\n---\n\n# Heading\n\n==VISIBLE_MARK== <u>VISIBLE_UNDER</u> %%PRIVATE_INLINE%%\n\n> [!warning]- Export title\n> VISIBLE_CALLOUT\n\n[[#Heading|VISIBLE_LINK]] ![[pixel.png|24x24]]\n\n%% private\n\nPRIVATE_BLOCK\n\n%%\n"
        try Data(source.utf8).write(to: document)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("pixel.png"))
        let filterBytes = try Data(contentsOf: filter())
        let hash = SHA256.hash(data: filterBytes).map { String(format: "%02x", $0) }.joined()
        for mode in [QuartoParameterSource.yaml, .custom] {
            for format in QuartoExportFormat.allCases {
                var options = QuartoExportOptions()
                options.parameterSource = mode; options.format = format
                options.language = "en"; options.execution = .disabled
                let name = mode.rawValue + "-" + format.rawValue
                let output = root.appendingPathComponent(name + "." + format.fileExtension)
                let job = root.appendingPathComponent(name)
                let result = try await QuartoExportEngine.run(input: .init(source: source, documentURL: document), options: options,
                    tools: .init(quarto: XCTUnwrap(QuartoExecutable.locate()), rscript: XCTUnwrap(NotebookRExecutable.locate(selected: nil)), timeout: 60),
                    destination: .init(output, overwrite: false), directory: job, process: QuartoProcess(), log: { _, _ in }, prepared: { _ in })
                let logs = ["stdout.log", "stderr.log"].compactMap { try? String(contentsOf: job.appendingPathComponent($0), encoding: .utf8) }.joined()
                XCTAssertEqual(result.status, .succeeded, "\(name): \(result.diagnostic ?? "") \(logs)")
                guard result.status == .succeeded else { continue }
                XCTAssertEqual(result.resourceHashes["Quarto/edmund-compat.lua"], hash)
                XCTAssertEqual(try Data(contentsOf: job.appendingPathComponent("edmund-compat.lua")), filterBytes)
                let content: String
                if format == .html {
                    content = try String(contentsOf: output, encoding: .utf8)
                    XCTAssertTrue(content.contains("<mark>VISIBLE_MARK</mark>"))
                    XCTAssertTrue(content.contains("callout-title"), "Callout must pass through Quarto, not just a classed div")
                    XCTAssertTrue(content.contains("collapse"))
                } else if format == .docx {
                    let unzip = try await QuartoProcess().run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", output.path, "word/document.xml"],
                        directory: root, environment: ProcessInfo.processInfo.environment, timeout: 10)
                    XCTAssertEqual(unzip.exitCode, 0)
                    content = String(decoding: unzip.stdout, as: UTF8.self)
                    XCTAssertTrue(content.contains("w:highlight"))
                    XCTAssertTrue(content.contains("w:drawing"))
                } else {
                    content = try XCTUnwrap(PDFDocument(url: output)?.string)
                }
                for visible in ["VISIBLE_MARK", "VISIBLE_UNDER", "VISIBLE_CALLOUT", "VISIBLE_LINK"] { XCTAssertTrue(content.contains(visible), "\(name) missing \(visible)") }
                XCTAssertFalse(content.contains("PRIVATE_INLINE"), name)
                XCTAssertFalse(content.contains("PRIVATE_BLOCK"), name)
                XCTAssertEqual(try Data(contentsOf: document), Data(source.utf8))
                XCTAssertEqual(result.sourceHash, DocumentRevision(text: source).rawValue)
            }
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".rnotebook-render-") })
    }
}
