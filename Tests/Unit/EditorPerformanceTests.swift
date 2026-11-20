import AppKit
import CryptoKit
import ImageIO
import XCTest
@testable import EdmundCore
@testable import Rnotebook

@MainActor final class EditorPerformanceTests: XCTestCase {
    private func host(_ source: String) throws -> RecordNativeEditorHost {
        let suite = "EditorPerformance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = SourceEditorSettings(defaults: defaults)
        settings.completionEnabled = false
        let model = RecordLayoutModel(visualDefaults: defaults, initialSource: source, usesProcessArguments: false)
        model.sourceOnly = true
        let host = RecordNativeEditorHost(model: model, sourceSettings: settings)
        addTeardownBlock { @MainActor in host.detach(); defaults.removePersistentDomain(forName: suite) }
        return host
    }
    func testLongCodeLocalRecolorAndAppearanceKeepAllScopesWithoutChangingSource() throws {
        let source = "# Unicode \u{4e2d}\u{6587}\u{1f642}\n\n" + (0..<260).map {
            "```{r}\nf_\($0) <- function(x) mean(x + \($0))\n```\n\n"
        }.joined()
        let host = try host(source), storage = try XCTUnwrap(host.editor.textStorage)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance)
            host.editor.rerenderStyles()
            for index in [0, 127, 129, 259] {
                let token = (source as NSString).range(of: "mean(x + \(index))")
                let function = NSRange(location: token.location, length: 4)
                storage.addAttribute(.foregroundColor, value: NSColor.magenta, range: function)
                XCTAssertEqual(storage.attribute(RecordRSyntaxAdapter.scopeKey, at: function.location, effectiveRange: nil) as? String, "function")
                XCTAssertEqual(storage.attribute(.foregroundColor, at: function.location, effectiveRange: nil) as? NSColor, NSColor(srgbRed: appearance == .darkAqua ? 0x61 / 255.0 : 0x42 / 255.0, green: appearance == .darkAqua ? 0xaf / 255.0 : 0x71 / 255.0, blue: appearance == .darkAqua ? 0xef / 255.0 : 0xae / 255.0, alpha: 1))
            }
            XCTAssertEqual(Data(host.editor.string.utf8), Data(source.utf8))
            XCTAssertEqual(host.model.notebook.state, .notStarted)
        }
    }
    func testCompiledColorsInvalidateForChangedSourceAndEquivalentUnicodeBytes() async throws {
        let original = "# caf\u{e9}\n\n```{r}\nmean(1)\n```\n"
        let host = try host(original)
        for source in [original.replacingOccurrences(of: "mean(1)", with: "sum(123)"),
                       original.replacingOccurrences(of: "\u{e9}", with: "e\u{301}")] {
            try await Task.sleep(for: .milliseconds(30))
            host.model.source = source; host.update()
            let storage = try XCTUnwrap(host.editor.textStorage)
            let number = (source as NSString).range(of: source.contains("123") ? "123" : "1")
            XCTAssertEqual(storage.attribute(RecordRSyntaxAdapter.scopeKey, at: number.location, effectiveRange: nil) as? String, "number")
            XCTAssertEqual(Data(host.editor.rawSource.utf8), Data(source.utf8))
            host.model.sourceOnly = false; host.update()
            host.model.sourceOnly = true; host.update()
            XCTAssertEqual(Data(host.editor.string.utf8), Data(source.utf8))
        }
    }
    func testLargeCodePresentationHasNoDeferredRenderedBlocksAndKeepsSelectionAndFonts() throws {
        let source = "# Source presentation\n\n" + (0..<260).map {
            "```{r}\nx_\($0) <- mean(1:10)\n```\n\n"
        }.joined()
        let host = try host(source)
        host.sourceSettings.fontSize = 18
        let selection = (source as NSString).range(of: "mean(1:10)", options: .backwards)
        host.editor.setSelectedRange(selection)
        for code in [false, true, false, true] {
            host.model.sourceOnly = code; host.update()
            XCTAssertEqual(Data(host.editor.string.utf8), Data(source.utf8))
            XCTAssertEqual(host.editor.selectedRange(), selection)
            if code {
                XCTAssertEqual(host.editor.unstyledBlockCount, 0, "Code must not queue a whole-document rendered-block drain")
                let storage = try XCTUnwrap(host.editor.textStorage)
                let font = try XCTUnwrap(storage.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)
                XCTAssertEqual(font.pointSize, 18)
                for token in ["```{r}", "x_259"] {
                    let range = (source as NSString).range(of: token)
                    XCTAssertNil(storage.attribute(.fragmentOverlay, at: range.location, effectiveRange: nil))
                    XCTAssertNil(storage.attribute(.blockDecoration, at: range.location, effectiveRange: nil))
                }
            }
        }
        XCTAssertEqual(host.model.notebook.state, .notStarted)
    }
    func testLongDocumentSwitchToFirstNativePaintAndWarmReturn() async throws {
        let source = "# Native switch latency\n\n" + (0..<700).map {
            "## Section \($0)\n\n" + String(repeating: "Measured paragraph with Unicode \u{4e2d}\u{6587}. ", count: 8)
            + "\n\n```{r}\nx_\($0) <- seq_len(100)\nmean(x_\($0))\n```\n\n"
        }.joined()
        let host = try host(source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        var times: [[String: Any]] = []
        for round in 0..<3 {
            for code in [false, true] {
                let start = ProcessInfo.processInfo.systemUptime
                host.model.sourceOnly = code; host.update()
                host.layoutSubtreeIfNeeded()
                host.editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                window.displayIfNeeded()
                let duration = ProcessInfo.processInfo.systemUptime - start
                times.append(["round": round, "mode": code ? "Code" : "Visual", "nativePaintSeconds": duration])
                XCTAssertLessThan(duration, code || round > 0 ? 1 : 3,
                                  "700-block presentation must paint promptly; full drain time is not the latency")
                XCTAssertEqual(Data(host.editor.string.utf8), Data(source.utf8))
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".local/validation/editor-performance-2026-11-15/native-switch-times.json")
        try JSONSerialization.data(withJSONObject: times, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
    func testSection300RoundTripsKeepVisibleCaretAtTheSameReadingPosition() async throws {
        let document = QMDDocument()
        let suite = "ModeReadingPosition." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        document.sourceSettings = SourceEditorSettings(defaults: defaults)
        document.sourceSettings.completionEnabled = false
        document.visual = VisualEditorSettings(defaults: defaults)
        document.appearance = AppearanceSettings(defaults: defaults)
        let source = "# Reading position\n\n" + (0..<700).map {
            "## Section \($0)\n\n" + String(repeating: "Long paragraph with Unicode \u{4e2d}\u{6587}. ", count: 8)
            + "\n\n```{r}\nx_\($0) <- seq_len(100)\nmean(x_\($0))\n```\n\n"
        }.joined()
        document.model.source = source
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.makeKeyAndOrderFront(nil)
        let host = try XCTUnwrap(document.model.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)
        let editor = host.editor, scroll = try XCTUnwrap(editor.enclosingScrollView)
        addTeardownBlock { @MainActor in
            document.updateChangeCount(.changeCleared); document.close(); defaults.removePersistentDomain(forName: suite)
        }
        window.makeFirstResponder(editor)
        let initialDeadline = Date(timeIntervalSinceNow: 6)
        while editor.unstyledBlockCount > 0, Date() < initialDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(editor.unstyledBlockCount, 0)
        host.outputs.apply()
        try await Task.sleep(for: .milliseconds(100))
        let location = (source as NSString).range(of: "## Section 300\n").location
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.scrollCharacterToTop(location)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(400))
        let baseline = editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        XCTAssertGreaterThan(baseline.height, 0)
        var trace: [[String: Any]] = []
        for round in 0..<6 {
            for code in [true, false] {
                document.model.sourceOnly = code; host.update()
                for tick in 0..<10 {
                    try await Task.sleep(for: .milliseconds(25))
                    let rect = editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
                    trace.append(["round": round, "code": code, "tick": tick, "caretY": rect.minY,
                                  "baselineY": baseline.minY, "height": rect.height, "scrollY": scroll.contentView.bounds.minY])
                    XCTAssertEqual(editor.selectedRange(), NSRange(location: location, length: 0))
                    XCTAssertGreaterThan(rect.height, 0, "Section300 caret disappeared; round \(round), Code=\(code)")
                    // Font/ruler reflow may move within the current screen at
                    // first paint; it must settle without cumulative drift.
                    XCTAssertEqual(rect.minY, baseline.minY, accuracy: tick < 4 ? 64 : 2,
                                   "Round \(round), Code=\(code), tick=\(tick)")
                }
            }
        }
        let beforePage = scroll.contentView.bounds.minY
        editor.scrollPageDown(nil)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertGreaterThan(abs(scroll.contentView.bounds.minY - beforePage), 100, "User paging must release mode anchoring")
        let destination = (source as NSString).range(of: "## Section 600\n").location
        editor.scrollCharacterToTop(destination)
        try await Task.sleep(for: .milliseconds(150))
        func visibleSection() -> Int {
            let offset = editor.topmostVisibleCharacterOffset() ?? 0
            let prefix = (source as NSString).substring(to: min(offset, source.utf16.count))
            return prefix.components(separatedBy: "## Section ").last.flatMap { Int($0.prefix { $0.isNumber }) } ?? -1
        }
        let readingSection = visibleSection()
        XCTAssertGreaterThanOrEqual(readingSection, 599)
        for code in [true, false, true, false] {
            document.model.sourceOnly = code; host.update()
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertLessThanOrEqual(abs(visibleSection() - readingSection), 1, "An offscreen caret must not pull reading back from Section600")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: location, length: 0))
        }
        XCTAssertEqual(Data(editor.string.utf8), Data(source.utf8))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".local/validation/editor-performance-2026-11-15/section300-trace.json")
        try JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EditorImages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func bitmap(width: Int = 3072, height: Int = 1536, red: CGFloat = 0.8, alpha: CGFloat = 0.5) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.1, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func write(_ image: CGImage, to url: URL, type: CFString = "public.png" as CFString,
                       properties: CFDictionary? = nil, frames: Int = 1) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type, frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func preview(_ editor: EditorTextView, _ url: URL, width: Int) throws -> NSImage {
        guard case .image(let image) = editor.imageDisplay(destination: url.absoluteString, width: width) else {
            XCTFail("Local image must still render"); throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }
    private func pixels(_ image: NSImage) throws -> CGImage {
        try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
    func testLargeRasterUsesDisplayPixelsRetainsTransparencyAndOriginalBytesAcrossWidths() throws {
        let url = try directory().appendingPathComponent("large.png")
        try write(bitmap(), to: url)
        let before = SHA256.hash(data: try Data(contentsOf: url))
        let original = try XCTUnwrap(NSImage(contentsOf: url))
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 1400, height: 600))
        editor.textContainer?.containerSize = NSSize(width: 1400, height: CGFloat.greatestFiniteMagnitude)
        let small = try preview(editor, url, width: 180), smallPixels = try pixels(small)
        XCTAssertEqual(small.size, original.size)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        XCTAssertLessThanOrEqual(smallPixels.width, Int(ceil(180 * scale / 64) * 64))
        XCTAssertLessThan(smallPixels.width, 3072)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: smallPixels).colorAt(x: 5, y: 5))
        XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.02)
        let large = try preview(editor, url, width: 900)
        XCTAssertGreaterThan(try pixels(large).width, smallPixels.width)
        XCTAssertEqual(large.size, original.size)
        let smaller = try preview(editor, url, width: 120)
        XCTAssertLessThan(try pixels(smaller).width, try pixels(large).width)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), before)
        let overlay = try XCTUnwrap(editor.imageOverlay(destination: url.absoluteString, width: 200))
        XCTAssertEqual(overlay.bounds.width, 200, accuracy: 0.01)
        XCTAssertEqual(overlay.bounds.height, 100, accuracy: 0.01)
    }
    func testLocalImageCacheReloadsAtomicReplacementAndRetainsDPIAndOrientationGeometry() throws {
        let url = try directory().appendingPathComponent("photo.jpg")
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
                                        kCGImagePropertyOrientation: 6]
        try write(bitmap(alpha: 1), to: url, type: "public.jpeg" as CFString, properties: properties as CFDictionary)
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let first = try preview(editor, url, width: 180)
        XCTAssertEqual(first.size, try XCTUnwrap(NSImage(contentsOf: url)).size)
        let pixel = try pixels(first)
        XCTAssertGreaterThan(pixel.height, pixel.width, "EXIF orientation must be applied to decoded pixels")
        XCTAssertEqual(CGFloat(pixel.width) / CGFloat(pixel.height), first.size.width / first.size.height, accuracy: 0.02)
        let replacement = url.appendingPathExtension("replacement")
        try write(bitmap(width: 2400, height: 1200, red: 0.1, alpha: 1), to: replacement, type: "public.jpeg" as CFString)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        let second = try preview(editor, url, width: 180)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.size, try XCTUnwrap(NSImage(contentsOf: url)).size)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: pixels(second)).colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(color.redComponent, 0.2)
    }
    func testVectorAndAnimatedImagesRetainRepresentationsAndRemotePolicy() throws {
        let directory = try directory(), svg = directory.appendingPathComponent("vector.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"600\" height=\"300\"><rect width=\"600\" height=\"300\" fill=\"red\"/></svg>".write(to: svg, atomically: true, encoding: .utf8)
        let gif = directory.appendingPathComponent("animation.gif")
        try write(bitmap(width: 40, height: 20, alpha: 1), to: gif, type: "com.compuserve.gif" as CFString,
                  properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary, frames: 2)
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let vector = try preview(editor, svg, width: 200)
        XCTAssertEqual(vector.size, NSSize(width: 600, height: 300))
        let animation = try preview(editor, gif, width: 100)
        let rep = try XCTUnwrap(animation.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        XCTAssertEqual((rep.value(forProperty: .frameCount) as? NSNumber)?.intValue, 2)
        editor.allowRemoteImages = false
        guard case .blocked(.blockedBySetting) = editor.imageDisplay(destination: "https://example.com/test.png") else {
            return XCTFail("The local optimization must not bypass remote policy")
        }
        guard case .blocked(.httpUnsupported) = editor.imageDisplay(destination: "http://example.com/test.png") else {
            return XCTFail("HTTP policy must remain intact")
        }
    }
    func testNativeImageResizeAndCodeVisualRoundTripKeepSourceAndPixelDetail() async throws {
        let url = try directory().appendingPathComponent("window.png")
        try write(bitmap(), to: url)
        let source = "# Native image window\n\n![Image](" + url.absoluteString + ")\n\nEnd.\n"
        let host = try host(source)
        host.model.sourceOnly = false; host.update()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        let scale = window.backingScaleFactor
        var widths: [Int] = []
        for width in [720, 1100, 540] {
            window.setContentSize(NSSize(width: width, height: 620))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            let storage = try XCTUnwrap(host.editor.textStorage)
            let location = (source as NSString).range(of: "![Image]").location
            let overlay = try XCTUnwrap(storage.attribute(.fragmentOverlay, at: location, effectiveRange: nil) as? FragmentOverlay)
            let image = try pixels(XCTUnwrap(overlay.image))
            widths.append(image.width)
            XCTAssertLessThanOrEqual(overlay.bounds.width, host.editor.availableContentWidth + 1)
            XCTAssertGreaterThanOrEqual(CGFloat(image.width), overlay.bounds.width * scale - 2)
            XCTAssertLessThanOrEqual(CGFloat(image.width), ceil(overlay.bounds.width * scale / 64) * 64 + 2)
            XCTAssertEqual(Data(host.editor.rawSource.utf8), Data(source.utf8))
            if width == 720 {
                let rect = host.visibleRect
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
                host.cacheDisplay(in: rect, to: rep)
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let folder = root.appendingPathComponent(".local/validation/editor-performance-2026-11-15")
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("native-image.png"))
            }
        }
        XCTAssertGreaterThan(widths[1], widths[0]); XCTAssertLessThan(widths[2], widths[1])
        for code in [true, false, true, false] {
            host.model.sourceOnly = code; host.update()
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(Data(host.editor.string.utf8), Data(source.utf8))
        }
        XCTAssertEqual(host.model.notebook.state, .notStarted)
    }

}
