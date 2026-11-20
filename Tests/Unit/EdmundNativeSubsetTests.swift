import AppKit
import XCTest
@testable import EdmundCore
@testable import Rnotebook

@MainActor final class EdmundNativeSubsetTests: XCTestCase {
    func testNativeMathStillRendersInlineAndDisplayWithBaselineMetrics() throws {
        XCTAssertEqual(MathRendering.shared.active.id, "swiftmath")
        for display in [false, true] {
            let result = try XCTUnwrap(MathRendering.shared.render(latex: #"\frac{x^2}{1+x}+\alpha"#, displayMode: display,
                pointSize: 18, color: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1), scale: 2))
            XCTAssertGreaterThan(result.image.size.width, 0)
            XCTAssertGreaterThan(result.ascent, 0); XCTAssertGreaterThanOrEqual(result.descent, 0)
            XCTAssertEqual(result.ascent + result.descent, result.image.size.height, accuracy: 0.01)
        }
    }
    func testBundledMermaidRendersWithoutReadModeOrDownloaderAndRejectsWrongHash() throws {
        let script = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "beautiful-mermaid", withExtension: "js", subdirectory: "RecordPreviewAssets/Mermaid"))
        let renderer = MermaidRenderer()
        XCTAssertFalse(renderer.loadBundled(from: script.deletingLastPathComponent(), scriptSHA256: String(repeating: "0", count: 64)))
        XCTAssertFalse(renderer.isReady)
        XCTAssertTrue(renderer.loadBundled(from: script.deletingLastPathComponent(), scriptSHA256: "135071f07173aba0473343630291d93d0b065e76a3db4619937b8d87cf4fb86c"))
        renderer.isEnabled = true
        let style = MermaidStyle(backgroundHex: "#FFFFFF", foregroundHex: "#000000")
        let image = try XCTUnwrap(renderer.image(source: "flowchart LR\nA[Import] --> B[Analyze]\nB --> C[Export]", style: style))
        XCTAssertGreaterThan(image.size.width, 0); XCTAssertGreaterThan(image.size.height, 0)
    }
    func testNativeCodeVisualRoundTripAndHeadingNavigationPreserveQMD() throws {
        let source = "# 标题\n\n公式 $x^2+1$。\n\n## Section\n\n```{r}\nhead(iris)\n```\n\n```mermaid\nflowchart LR\nA --> B\n```\n"
        let model = RecordLayoutModel(initialSource: source, usesProcessArguments: false)
        let host = RecordNativeEditorHost(model: model)
        defer { host.detach() }
        host.frame = NSRect(x: 0, y: 0, width: 740, height: 600)
        host.layoutSubtreeIfNeeded()
        for sourceOnly in [true, false, true, false] {
            model.sourceOnly = sourceOnly; host.update()
            XCTAssertEqual(host.editor.rawSource, source)
            XCTAssertEqual(host.editor.viewMode, sourceOnly ? .source : .edit)
            XCTAssertNotNil(host.editor.textLayoutManager)
        }
        let heading = try XCTUnwrap(host.editor.outlineHeadings.first { $0.title == "Section" })
        host.editor.scrollToBlock(heading.range)
        XCTAssertEqual(host.editor.selectedRange(), heading.range)
        XCTAssertEqual(model.source, source)
    }
}
