import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class RichTableBorderTests: XCTestCase {
    private let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".local/validation/rich-table-borders-2026-11-13/runs/" + UUID().uuidString)
    private var printedEvidence = false
    private func output() -> RecordRichOutput {
        .init(title: "Border probe", representations: [.init(mime: "text/html", text:
            "<table><tr><th>A</th><th>B</th><th>C</th></tr><tr><td>one</td><td>two</td><td>three</td></tr><tr><td>four</td><td>five</td><td>six</td></tr></table>")],
            styles: ["td,th {border: 1pt solid #e00040; background-color: white;}"])
    }
    private func cells(_ text: NSTextView) throws -> [(NSTextTableBlock, NSRange, NSRect)] {
        let storage = try XCTUnwrap(text.textStorage), manager = try XCTUnwrap(text.layoutManager)
        var cells: [(NSTextTableBlock, NSRange, NSRect)] = []
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                  seen.insert(ObjectIdentifier(block)).inserted else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            cells.append((block, range, manager.boundsRect(for: block, glyphRange: glyphs).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)))
        }
        return cells
    }
    private func capture(_ view: NSView, name: String, scale: Int = 2, rect: NSRect? = nil) throws -> NSBitmapImageRep {
        let area = rect ?? view.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(area.width)) * scale,
            pixelsHigh: Int(ceil(area.height)) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = area.size
        view.cacheDisplay(in: area, to: rep)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        if !printedEvidence { print("BORDER_EVIDENCE", evidence.path); printedEvidence = true }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: evidence.appendingPathComponent(name + ".png"))
        return rep
    }
    func testProbeNativeBorderGeometryBeforeAndAfterSelectionAndResize() async throws {
        let rich = RecordRichOutputView(output: output(), font: .systemFont(ofSize: 13))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = rich; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        for width in [420.0, 421.5, 320.0] {
            window.setContentSize(NSSize(width: width, height: 200)); rich.layoutSubtreeIfNeeded()
            _ = rich.desiredHeight(width: width)
            try await Task.sleep(for: .milliseconds(80)); rich.layoutSubtreeIfNeeded()
            let text = rich.textView
            text.drawsBackground = true; text.backgroundColor = .white
            let layout = try cells(text)
            print("BORDER_GEOMETRY", width, "view", text.frame, "container", text.textContainer?.containerSize ?? .zero,
                  "used", text.layoutManager?.usedRect(for: text.textContainer!) ?? .zero)
            for (block, _, rect) in layout { print("BORDER_CELL", block.startingRow, block.startingColumn, rect) }
            _ = try capture(text, name: "baseline-\(width)")
            let cell = try XCTUnwrap(layout.first?.2)
            let strip = NSRect(x: cell.maxX - 1, y: cell.minY + 4, width: 2, height: cell.height - 8)
            let glyphs = text.layoutManager!.glyphRange(forBoundingRect: strip.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y), in: text.textContainer!)
            let partial = try capture(text, name: "border-strip-\(width)", rect: strip)
            var red = 0
            for y in 0..<partial.pixelsHigh { for x in 0..<partial.pixelsWide {
                if let c = partial.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent > 0.7, c.greenComponent < 0.3 { red += 1 }
            } }
            print("BORDER_PARTIAL", strip, glyphs, "red", red, "total", partial.pixelsWide * partial.pixelsHigh)
            XCTAssertGreaterThan(red, partial.pixelsWide * partial.pixelsHigh / 8, "A border-only dirty rect must repaint even without text glyphs")
            text.selectAll(nil); _ = try capture(text, name: "selected-\(width)")
            text.setSelectedRange(NSRange(location: 0, length: 0)); _ = try capture(text, name: "deselected-\(width)")
            XCTAssertEqual(layout.count, 9)
            for (_, _, rect) in layout { XCTAssertLessThanOrEqual(rect.maxX, text.bounds.maxX, "The cell border must fit the text surface") }
        }
    }

    func testDefaultKableRightEdgeFitsNestedVisualResultAfterResize() async throws {
        let html = "<table><caption>三个中心的完整配对核对</caption><thead><tr><th>Site</th><th>Total</th><th>Complete</th></tr></thead><tbody>" + (0..<3).map { "<tr><td>Site \($0)</td><td>60</td><td>55</td></tr>" }.joined() + "</tbody></table>"
        let output = RecordRichOutput(title: "kable", representations: [.init(mime: "text/html", text: html)])
        let shelf = RecordOutputShelf(frame: .zero)
        var state = RecordOutputLayout.State(hash: "kable")
        state.isSample = false; state.events = [.rich(output)]
        shelf.configure(id: "kable", state: state, stale: false, font: .monospacedSystemFont(ofSize: 13, weight: .regular), bodyFont: .systemFont(ofSize: 13))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 740, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = shelf; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func richView(_ node: NSView) -> RecordRichOutputView? {
            if let rich = node as? RecordRichOutputView { return rich }
            return node.subviews.lazy.compactMap { richView($0) }.first
        }
        for width in [739.0, 740, 740.5, 420, 1120, 739] {
            let height = shelf.desiredHeight(width: width)
            window.setContentSize(NSSize(width: width, height: height))
            shelf.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            shelf.layoutSubtreeIfNeeded()
            let rich = try XCTUnwrap(richView(shelf)), text = rich.textView
            let layout = try cells(text)
            let viewport = try XCTUnwrap(rich.subviews.first as? RecordOutputViewport)
            print("KABLE_NESTED", width, "rich", rich.frame, "text", text.frame, "container", text.textContainer!.containerSize, "visible", text.visibleRect)
            for cell in layout where cell.0.startingColumn == 2 {
                print("KABLE_RIGHT", cell.2)
                XCTAssertLessThanOrEqual(cell.2.maxX + cell.0.width(for: .border, edge: .maxX) / 2, text.textContainerOrigin.x + text.textContainer!.containerSize.width, "Collapsed outer strokes must fit the native text-container drawing clip")
                XCTAssertLessThanOrEqual(cell.2.maxX + 0.25, text.visibleRect.maxX, "The right border must fit the actual nested clip, including its stroke")
                let edge = text.convert(cell.2, to: viewport)
                XCTAssertLessThanOrEqual(edge.maxX + 0.25, viewport.contentView.frame.maxX)
            }
            _ = try capture(shelf, name: "kable-nested-\(width)")
        }
    }

    func testVisualEditorKableOuterEdgeRemainsVisibleAfterModeSwitches() async throws {
        let source = "# Results\n\n```{r}\n#| label: kable-edge\nx\n```\n"
        let model = RecordLayoutModel(initialSource: source, usesProcessArguments: false)
        model.sourceOnly = false
        let host = RecordNativeEditorHost(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 840, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { host.detach(); window.orderOut(nil); window.close() }
        let html = "<table><thead><tr><th>Site</th><th>Total</th><th>Complete</th></tr></thead><tbody>" + (0..<3).map { "<tr><td>Site \($0)</td><td>60</td><td>55</td></tr>" }.joined() + "</tbody></table>"
        var state = RecordOutputLayout.State(hash: FenceScanner().scan(source).cells[0].sourceHash)
        state.isSample = false; state.events = [.rich(.init(title: "kable", representations: [.init(mime: "text/html", text: html)]))]
        model.outputStates["kable-edge"] = state
        func richView(_ node: NSView) -> RecordRichOutputView? {
            if let rich = node as? RecordRichOutputView { return rich }
            return node.subviews.lazy.compactMap { richView($0) }.first
        }
        for width in [840.0, 839.5, 620, 1000, 840] {
            window.setContentSize(NSSize(width: width, height: 640))
            for code in [true, false] {
                model.sourceOnly = code; host.update(); host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(90))
            }
            let rich = try XCTUnwrap(richView(host.editor)), text = rich.textView
            let layout = try cells(text), right = try XCTUnwrap(layout.first { $0.0.startingColumn == 2 }?.2)
            print("KABLE_EDITOR", width, "text", text.frame, "container", text.textContainer!.containerSize, "visible", text.visibleRect, "right", right)
            XCTAssertLessThanOrEqual(right.maxX + 0.25, text.visibleRect.maxX)
            let rep = try capture(rich, name: "kable-editor-\(width)")
            let box = text.convert(NSRect(x: right.maxX - 1, y: right.minY + 4, width: 2, height: right.height - 8), to: rich)
            var marks = 0
            for y in max(0, Int(box.minY * 2))..<min(rep.pixelsHigh, Int(box.maxY * 2)) {
                for x in max(0, Int(box.minX * 2))..<min(rep.pixelsWide, Int(box.maxX * 2)) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent < 0.97, c.alphaComponent > 0.03 { marks += 1 }
                }
            }
            XCTAssertGreaterThan(marks, Int(right.height), "The real Visual result must display the default right border")
        }
    }

    func testRealKableAndFlextableSourceAndNativeGeometry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RichBorder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = try XCTUnwrap(NotebookRExecutable.locate(selected: nil))
        let worker = try XCTUnwrap(Bundle(for: RecordNativeEditorHost.self).url(forResource: "worker", withExtension: "R", subdirectory: "NotebookRuntime/Bootstrap"))
        let config = RuntimeConfiguration(executable: executable, workerScript: worker, projectDirectory: root, startupTimeout: 10, taskTimeout: 20)
        let model = RecordLayoutModel(notebookConfiguration: { config }, initialSource: "```{r}\n#| label: border\nx <- head(iris, 3)\nknitr::kable(x)\nflextable::flextable(x)\nflextable::border_outer(flextable::border_inner(flextable::flextable(x), border=officer::fp_border(color='red', width=1)), border=officer::fp_border(color='red', width=1))\n```\n", usesProcessArguments: false)
        addTeardownBlock { @MainActor in await model.notebook.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.runAllNotebookCells(); await model.notebook.waitUntilIdle()
        let state = try XCTUnwrap(model.outputStates["border"])
        XCTAssertFalse(state.failed, state.events.compactMap { if case .error(let message) = $0 { return message }; return nil }.joined())
        var index = 0
        for event in state.events {
            guard case .rich(let output) = event else { continue }
            index += 1
            let tag = "real-\(index)-\(output.title)"
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try JSONEncoder().encode(output).write(to: evidence.appendingPathComponent(tag + ".json"))
            let rich = RecordRichOutputView(output: output, font: .systemFont(ofSize: 13))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 540, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = rich; window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            rich.layoutSubtreeIfNeeded(); _ = rich.desiredHeight(width: 540)
            try await Task.sleep(for: .milliseconds(80)); rich.layoutSubtreeIfNeeded()
            rich.textView.drawsBackground = true; rich.textView.backgroundColor = .white
            let layout = try cells(rich.textView)
            print("BORDER_REAL", tag, rich.textView.frame, rich.textView.textContainer?.containerSize ?? .zero)
            for (block, _, rect) in layout {
                print("BORDER_REAL_CELL", block.startingRow, block.startingColumn, rect,
                      "right", block.width(for: .border, edge: .maxX))
                XCTAssertLessThanOrEqual(rect.maxX, rich.textView.bounds.maxX)
            }
            _ = try capture(rich.textView, name: tag + "-before")
            rich.textView.selectAll(nil); _ = try capture(rich.textView, name: tag + "-selected")
            rich.textView.setSelectedRange(NSRange(location: 0, length: 0)); _ = try capture(rich.textView, name: tag + "-after")
        }
        XCTAssertEqual(index, 3)
    }

    func testLongTableBorderAndOverlayScrollerGeometry() async throws {
        let rows = (0..<40).map { "<tr><td>\($0)</td><td>value</td><td>right</td></tr>" }.joined()
        let value = RecordRichOutput(title: "scrolling", representations: [.init(mime: "text/html", text: "<table>\(rows)</table>")], styles: ["td{border:1pt solid #e00040;background-color:white}"])
        let rich = RecordRichOutputView(output: value, font: .systemFont(ofSize: 13))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = rich; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        rich.layoutSubtreeIfNeeded(); _ = rich.desiredHeight(width: 420)
        rich.textView.drawsBackground = true; rich.textView.backgroundColor = .white
        try await Task.sleep(for: .milliseconds(80)); rich.layoutSubtreeIfNeeded()
        let viewport = try XCTUnwrap(rich.subviews.first as? RecordOutputViewport)
        let vertical = try XCTUnwrap(viewport.subviews.compactMap { $0 as? NSScroller }.first { $0.frame.height > $0.frame.width })
        let right = try XCTUnwrap(cells(rich.textView).first { $0.0.startingColumn == 2 }?.2)
        print("BORDER_SCROLL", "vertical", vertical.frame, vertical.isHidden, "right", right)
        XCTAssertLessThanOrEqual(right.maxX, vertical.frame.minX, "The outer border must remain outside the overlay scroller's strip")
        _ = try capture(rich, name: "long-table-viewport")
        _ = try capture(rich.textView, name: "long-table-text")
    }

    func testWideNativeTableBordersFitScrollableDocument() throws {
        let row = (0..<30).map { "<td>column\($0)_unbreakable</td>" }.joined()
        let output = RecordRichOutput(title: "wide", representations: [.init(mime: "text/html", text: "<table><tr>\(row)</tr></table>")])
        let rich = RecordRichOutputView(output: output, font: .systemFont(ofSize: 13))
        _ = rich.desiredHeight(width: 420)
        let layout = try cells(rich.textView)
        print("BORDER_WIDE", rich.textView.frame, "right", layout.map(\.2.maxX).max() ?? 0)
        XCTAssertLessThanOrEqual(layout.map(\.2.maxX).max() ?? 0, rich.textView.frame.width)
    }

    func testBorderCSSPreservesFunctionalColorsAndExplicitZeroOrNone() throws {
        let css = "border: 0.75pt solid rgba(200, 50, 25, 0.8); border-right: 2pt solid rgb(30, 120, 210); border-bottom: 0px solid red; border-top: none;"
        let output = RecordRichOutput(title: "CSS", representations: [.init(mime: "text/html", text: "<table><tr><td style='\(css)'>x</td></tr></table>")])
        let rich = RecordRichOutputView(output: output, font: .systemFont(ofSize: 13))
        _ = rich.desiredHeight(width: 420)
        let block = try XCTUnwrap(cells(rich.textView).first?.0)
        XCTAssertEqual(block.width(for: .border, edge: .minY), 0)
        XCTAssertEqual(block.width(for: .border, edge: .maxY), 0)
        XCTAssertEqual(block.width(for: .border, edge: .minX), 0.75)
        XCTAssertEqual(block.width(for: .border, edge: .maxX), 2)
        let left = try XCTUnwrap(block.borderColor(for: .minX)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(block.borderColor(for: .maxX)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(left.redComponent, 200.0 / 255, accuracy: 0.01)
        XCTAssertEqual(left.greenComponent, 50.0 / 255, accuracy: 0.01)
        XCTAssertEqual(left.alphaComponent, 0.8, accuracy: 0.01)
        XCTAssertEqual(right.blueComponent, 210.0 / 255, accuracy: 0.01)
    }

    private func redPixels(_ image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
            if let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent - c.greenComponent > 0.2, c.redComponent > 0.5 { count += 1 }
        } }
        return count
    }
    func testAllEdgesRepaintAtBothScalesWithAndWithoutSelectionInBothAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for fontSize in [11.0, 24] {
                let rich = RecordRichOutputView(output: output(), font: .systemFont(ofSize: fontSize))
                rich.appearance = NSAppearance(named: appearance)
                rich.textView.drawsBackground = true; rich.textView.backgroundColor = .white
                _ = rich.desiredHeight(width: 405.5)
                let text = rich.textView, layout = try cells(rich.textView)
                for selected in [false, true, false] {
                    // Select actual cell text, as in the reported repaint case.
                    // Selecting the final paragraph terminator intentionally
                    // paints AppKit's selection across the table's bottom edge.
                    text.setSelectedRange(NSRange(location: 0, length: selected ? 1 : 0))
                    for scale in [1, 2] {
                        for (index, cell) in layout.enumerated() {
                            let r = cell.2
                            let strips = [NSRect(x: r.minX - 1, y: r.minY + 4, width: 2, height: r.height - 8),
                                          NSRect(x: r.maxX - 1, y: r.minY + 4, width: 2, height: r.height - 8),
                                          NSRect(x: r.minX + 4, y: r.minY - 1, width: r.width - 8, height: 2),
                                          NSRect(x: r.minX + 4, y: r.maxY - 1, width: r.width - 8, height: 2)]
                            for (edge, strip) in strips.enumerated() {
                                let image = try capture(text, name: "\(appearance.rawValue)-\(fontSize)-\(selected)-\(scale)-\(index)-\(edge)", scale: scale, rect: strip)
                                XCTAssertGreaterThan(redPixels(image), image.pixelsWide * image.pixelsHigh / 10,
                                                     "\(appearance.rawValue) font=\(fontSize) selected=\(selected) scale=\(scale) cell=\(index) edge=\(edge)")
                            }
                        }
                    }
                }
            }
        }
    }
    func testMergedCellsPartialRepaintAndNativeClipboardStayIntact() throws {
        let html = "<table><tr><th colspan='2'>heading</th><th>C</th></tr><tr><td rowspan='2'>left<br/>second</td><td>b1</td><td>c1</td></tr><tr><td>b2</td><td>c2</td></tr></table>"
        let output = RecordRichOutput(title: "merged", representations: [.init(mime: "text/html", text: html)], styles: ["td,th{border:1pt solid rgba(224, 0, 64, 1);background-color:white}"])
        let rich = RecordRichOutputView(output: output, font: .systemFont(ofSize: 13))
        _ = rich.desiredHeight(width: 420)
        let text = rich.textView
        text.drawsBackground = true; text.backgroundColor = .white
        let layout = try cells(text), heading = try XCTUnwrap(layout.first { $0.0.columnSpan == 2 })
        XCTAssertEqual(layout.count, 7); XCTAssertTrue(layout.contains { $0.0.rowSpan == 2 })
        let strip = NSRect(x: heading.2.maxX - 1, y: heading.2.minY + 4, width: 2, height: heading.2.height - 8)
        let image = try capture(text, name: "merged-border-only", rect: strip)
        XCTAssertGreaterThan(redPixels(image), image.pixelsWide * image.pixelsHigh / 8)
        let internalX = try XCTUnwrap(layout.first { $0.0.startingRow == 1 && $0.0.startingColumn == 1 }?.2.minX)
        let blank = try capture(text, name: "merged-no-false-internal-edge", rect: NSRect(x: internalX - 1, y: heading.2.minY + 4, width: 2, height: heading.2.height - 8))
        XCTAssertEqual(redPixels(blank), 0, "A colspan must not acquire a synthetic grid divider")
        text.selectAll(nil)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(text.copySelection(to: pasteboard))
        let plain = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(plain.contains("heading\t\tC")); XCTAssertTrue(plain.contains("left\nsecond"))
        let rtf = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let copied = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var coloredBorder = false
        copied.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: copied.length)) { value, _, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock,
                  let color = block.borderColor(for: .maxX)?.usingColorSpace(.deviceRGB) else { return }
            if color.redComponent > 0.8 && color.greenComponent < 0.1 { coloredBorder = true }
        }
        XCTAssertTrue(coloredBorder, "Native RTF must retain authored border colors")
    }
    func testRichGutterMeasurementAndOtherResultViewportGeometryRemainConsistent() {
        let rich = RecordRichOutputView(output: output(), font: .systemFont(ofSize: 24))
        let measured = rich.desiredHeight(width: 320)
        let before = rich.textView.frame.size
        rich.frame = NSRect(x: 0, y: 0, width: 320, height: measured)
        rich.layoutSubtreeIfNeeded()
        XCTAssertEqual(rich.textView.frame.width, before.width, accuracy: 0.5)
        XCTAssertEqual(rich.textView.frame.height, before.height, accuracy: 0.5)
        let ordinary = RecordOutputViewport(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        ordinary.hasVerticalScroller = true; ordinary.layoutSubtreeIfNeeded()
        XCTAssertEqual(ordinary.verticalScrollerGutter, 0)
        XCTAssertEqual(ordinary.contentSize.width, 320)
        XCTAssertEqual(ordinary.contentView.frame.width, 320)
    }
}
