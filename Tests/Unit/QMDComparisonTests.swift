import AppKit
import SwiftUI
import XCTest
@testable import Rnotebook

@MainActor final class QMDComparisonTests: XCTestCase {
    func testCanonicalUnicodeDifferencesRemainVisibleInBothDiffPaths() {
        for padding in [0, 12_001] {
            let tail = String(repeating: "\nline", count: padding)
            let left = "caf\u{e9}" + tail, right = "cafe\u{301}" + tail
            let diff = QMDComparison(editor: left, external: right)
            XCTAssertEqual(diff.changes, [0])
            XCTAssertTrue(diff.rows[0].changed)
            XCTAssertEqual(Data(diff.rows.compactMap { $0.editor?.text }.joined(separator: "\n").utf8), Data(left.utf8))
            XCTAssertEqual(Data(diff.rows.compactMap { $0.external?.text }.joined(separator: "\n").utf8), Data(right.utf8))
        }
    }
    func testAlignedDiffPreservesFullSourceLineNumbersAndIndependentChangeGroups() {
        let versions = ["", "\n", "a", "a\n", "a\na\nb", "\na\n\nb\n", "中文\r\n重复\r\n", "x\ny\nz\n", "a\nINSERT\nb", "a\n中文 👋\nb\n"]
        for a in versions { for b in versions {
            let diff = QMDComparison(editor: a, external: b)
            XCTAssertEqual(diff.rows.compactMap { $0.editor?.text }.joined(separator: "\n"), a)
            XCTAssertEqual(diff.rows.compactMap { $0.external?.text }.joined(separator: "\n"), b)
            XCTAssertEqual(diff.rows.compactMap { $0.editor?.number }, Array(1...a.components(separatedBy: "\n").count))
            XCTAssertEqual(diff.rows.compactMap { $0.external?.number }, Array(1...b.components(separatedBy: "\n").count))
            for row in diff.rows where !row.changed { XCTAssertEqual(row.editor?.text, row.external?.text) }
            XCTAssertEqual(diff.changes.isEmpty, a == b)
        } }
        let diff = QMDComparison(editor: "a\nB\nc\nd\nE\nf", external: "a\nb\nc\nd\ne\nf")
        XCTAssertEqual(diff.changes, [1, 4]); XCTAssertFalse(diff.simplified)
    }

    func testLargeComparisonKeepsCompleteContentWithBoundedFallback() {
        let a = (0..<13_000).map { "line \($0)" }.joined(separator: "\n")
        let diff = QMDComparison(editor: a, external: "external")
        XCTAssertTrue(diff.simplified); XCTAssertEqual(diff.rows.count, 13_000)
        XCTAssertEqual(diff.rows.compactMap { $0.editor?.text }.joined(separator: "\n"), a)
        XCTAssertEqual(diff.rows.compactMap { $0.external?.text }.joined(separator: "\n"), "external")
        XCTAssertEqual(diff.changes, [0])
    }

    func testNavigationToAnEmptyTerminalLineRevealsDocumentEnd() async throws {
        let source = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let comparison = QMDComparison(editor: source, external: source + "\n"), scroll = QMDComparisonScroll()
        let view = HStack {
            QMDComparisonPane(comparison: comparison, editorSide: true, scroll: scroll)
            QMDComparisonPane(comparison: comparison, editorSide: false, scroll: scroll)
        }.frame(width: 760, height: 330)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.makeKeyAndOrderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(comparison.changes, [100])
        scroll.reveal(row: 100)
        XCTAssertGreaterThan(scroll.external?.contentView.bounds.minY ?? 0, 1000)
        XCTAssertGreaterThan(scroll.editor?.contentView.bounds.minY ?? 0, 1000)
    }

    func testNativeAlignedPanesCopyOriginalWithoutAlignmentPaddingAndSynchronizeScroll() async throws {
        let originalPasteboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            NSPasteboard.general.clearContents()
            let restored = originalPasteboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            NSPasteboard.general.writeObjects(restored)
        }
        let a = "start\neditor\n" + (0..<100).map { "same \($0)" }.joined(separator: "\n") + "\n末尾"
        let b = "start\nexternal\ninsert\n" + (0..<100).map { "same \($0)" }.joined(separator: "\n") + "\n"
        let comparison = QMDComparison(editor: a, external: b), scroll = QMDComparisonScroll()
        let view = HStack(spacing: 1) {
            QMDComparisonPane(comparison: comparison, editorSide: true, scroll: scroll)
            QMDComparisonPane(comparison: comparison, editorSide: false, scroll: scroll)
        }.frame(width: 760, height: 330)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let left = try XCTUnwrap(scroll.editor), right = try XCTUnwrap(scroll.external)
        let leftText = try XCTUnwrap(left.documentView as? QMDComparisonTextView)
        let rightText = try XCTUnwrap(right.documentView as? QMDComparisonTextView)
        XCTAssertFalse(leftText.isEditable); XCTAssertTrue(leftText.isSelectable)
        XCTAssertTrue(left.rulersVisible); XCTAssertTrue(right.rulersVisible)
        XCTAssertEqual(leftText.rowRanges.count, comparison.rows.count)
        XCTAssertEqual(leftText.frame.height, rightText.frame.height, accuracy: 1)
        for (text, expected) in [(leftText, a), (rightText, b)] {
            text.selectAll(nil); text.copy(nil)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
        }
        left.contentView.scroll(to: NSPoint(x: 0, y: 500)); scroll.moved(left)
        XCTAssertEqual(left.contentView.bounds.minY, right.contentView.bounds.minY, accuracy: 1)
        scroll.synchronized = false
        left.contentView.scroll(to: NSPoint(x: 0, y: 700)); scroll.moved(left)
        XCTAssertEqual(right.contentView.bounds.minY, 500, accuracy: 1)
        scroll.synchronized = true; scroll.reveal(row: comparison.changes.last ?? 0)
        XCTAssertEqual(left.contentView.bounds.minY, right.contentView.bounds.minY, accuracy: 1)
        let changed = leftText.rowRanges[comparison.changes[0]]
        XCTAssertNotNil(leftText.textStorage?.attribute(.backgroundColor, at: changed.location, effectiveRange: nil))
        // A populated text storage is insufficient: verify actual painted glyphs.
        leftText.setSelectedRange(NSRange(location: 0, length: 0))
        left.contentView.scroll(to: .zero)
        let visible = NSRect(x: leftText.textContainerOrigin.x + 4, y: leftText.textContainerOrigin.y, width: 130, height: 36)
        let bitmap = try XCTUnwrap(leftText.bitmapImageRepForCachingDisplay(in: visible))
        leftText.cacheDisplay(in: visible, to: bitmap)
        var darkPixels = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.5, color.greenComponent < 0.5, color.blueComponent < 0.5 { darkPixels += 1 }
        } }
        XCTAssertGreaterThan(darkPixels, 25, "Actual native text must be painted")
        // Exercise the ruler with an oversized dirty rectangle, as AppKit does.
        // Layer-backed scroll cacheDisplay does not composite its child layers.
        let ruler = try XCTUnwrap(left.verticalRulerView)
        let canvas = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 250,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: canvas))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 400, height: 250).fill()
        ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: 0, width: 400, height: 250))
        NSGraphicsContext.restoreGraphicsState()
        let untouched = try XCTUnwrap(canvas.colorAt(x: 200, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(untouched.redComponent, 0.25, accuracy: 0.01)
        XCTAssertEqual(untouched.greenComponent, 0.5, accuracy: 0.01)
        XCTAssertEqual(untouched.blueComponent, 0.75, accuracy: 0.01)
    }
}
