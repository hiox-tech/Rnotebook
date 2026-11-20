import AppKit
import EdmundCore
import XCTest
@testable import Rnotebook

@MainActor final class LanguagePreferencesTests: XCTestCase {
    private func settings() throws -> SourceEditorSettings {
        let suite = "LanguagePreferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SourceEditorSettings(defaults: defaults)
    }
    private func fixture(_ source: String, settings: SourceEditorSettings) -> (RecordLayoutModel, RecordNativeEditorHost, NSWindow) {
        let model = RecordLayoutModel(visualDefaults: settings.defaults, initialSource: source, usesProcessArguments: false)
        let host = RecordNativeEditorHost(model: model, sourceSettings: settings, appearanceSettings: .init(defaults: settings.defaults))
        let window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(host.editor); host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in host.detach(); window.close(); await model.notebook.shutdown() }
        return (model, host, window)
    }
    func testLanguagePreferencesPersistAndInvalidStoredChoicesFallBack() throws {
        let value = try settings()
        XCTAssertTrue(value.completionAutomatic); XCTAssertEqual(value.completionDelay, 220)
        XCTAssertEqual(value.completionMinimum, 1); XCTAssertEqual(value.completionLimit, 80)
        value.syntaxPalette = "ocean"; value.syntaxEnabled = false
        value.syntaxItalicComments = true; value.syntaxBoldKeywords = true
        value.completionAutomatic = false; value.completionDelay = 600; value.completionMinimum = 3
        value.completionLimit = 20; value.completionSignature = false; value.completionParameters = false
        value.completionRuntime = false; value.completionReturn = false
        let restored = SourceEditorSettings(defaults: value.defaults)
        XCTAssertEqual(RecordSyntaxPreferences(restored), RecordSyntaxPreferences(value))
        XCTAssertEqual(RCompletionPreferences(restored), RCompletionPreferences(value))
        value.defaults.set("missing", forKey: "syntax.palette")
        value.defaults.set(-50, forKey: "completion.delay"); value.defaults.set(999, forKey: "completion.minimum")
        value.defaults.set(999, forKey: "completion.limit")
        let valid = SourceEditorSettings(defaults: value.defaults)
        XCTAssertEqual(valid.syntaxPalette, "default"); XCTAssertEqual(valid.completionDelay, 220)
        XCTAssertEqual(valid.completionMinimum, 1); XCTAssertEqual(valid.completionLimit, 80)
    }
    func testAutomaticCompletionThresholdAndManualOverrideRespectPreferences() throws {
        let value = try settings(); value.completionMinimum = 3
        var policy = RCompletionPreferences(value)
        XCTAssertFalse(policy.shouldTrigger(manual: false, prefix: "me", preceding: "e"))
        XCTAssertTrue(policy.shouldTrigger(manual: false, prefix: "mea", preceding: "a"))
        for trigger in ["$", "@", ":", "(", ","] {
            XCTAssertTrue(policy.shouldTrigger(manual: false, prefix: "", preceding: trigger))
        }
        value.completionAutomatic = false; policy = RCompletionPreferences(value)
        XCTAssertFalse(policy.shouldTrigger(manual: false, prefix: "mean", preceding: "n"))
        XCTAssertFalse(policy.shouldTrigger(manual: false, prefix: "", preceding: "("))
        XCTAssertTrue(policy.shouldTrigger(manual: true, prefix: "", preceding: " "))
    }
    func testPalettesAndEmphasisUpdateActualCodeAndVisualTokensWithoutSourceOrUndoChanges() async throws {
        let source = "# Heading\n\n```{r}\nif (TRUE) { # comment\n  mean(c(12, 18))\n}\n```\n\n```python\nif True: # Python comment\n    print(12)\n```\n"
        let value = try settings(); value.completionEnabled = false
        let (model, host, window) = fixture(source, settings: value)
        let keyword = (source as NSString).range(of: "if (").location
        let comment = (source as NSString).range(of: "# comment").location
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for code in [true, false] {
                model.sourceOnly = code
                for palette in RecordSyntaxPreferences.palettes {
                    value.syntaxPalette = palette; value.syntaxBoldKeywords = true; value.syntaxItalicComments = true
                    host.update(); try await Task.sleep(for: .milliseconds(35))
                    let attrs = try XCTUnwrap(host.editor.textStorage)
                    let expected = RecordSyntaxPreferences(value)
                    XCTAssertEqual(attrs.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor,
                        expected.color(.keyword, dark: appearance == .darkAqua))
                    let keyFont = try XCTUnwrap(attrs.attribute(.font, at: keyword, effectiveRange: nil) as? NSFont)
                    let commentFont = try XCTUnwrap(attrs.attribute(.font, at: comment, effectiveRange: nil) as? NSFont)
                    XCTAssertTrue(NSFontManager.shared.traits(of: keyFont).contains(.boldFontMask))
                    XCTAssertTrue(NSFontManager.shared.traits(of: commentFont).contains(.italicFontMask))
                    if !code {
                        let python = (source as NSString).range(of: "if True:").location
                        XCTAssertEqual(attrs.attribute(.foregroundColor, at: python, effectiveRange: nil) as? NSColor,
                            expected.color(.keyword, dark: appearance == .darkAqua))
                    }
                }
                value.syntaxEnabled = false; host.update(); try await Task.sleep(for: .milliseconds(35))
                let plain = RecordSyntaxPreferences(value).color(.plain, dark: appearance == .darkAqua)
                XCTAssertEqual(host.editor.textStorage?.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor, plain)
                XCTAssertEqual(host.editor.textStorage?.attribute(.foregroundColor, at: comment, effectiveRange: nil) as? NSColor, plain)
                value.syntaxEnabled = true; value.syntaxBoldKeywords = false; value.syntaxItalicComments = false
                host.update(); try await Task.sleep(for: .milliseconds(35))
                let restored = try XCTUnwrap(host.editor.textStorage?.attribute(.font, at: keyword, effectiveRange: nil) as? NSFont)
                XCTAssertFalse(NSFontManager.shared.traits(of: restored).contains(.boldFontMask))
                XCTAssertEqual(host.editor.string, source); XCTAssertFalse(host.editor.canUndoSource)
            }
        }
        XCTAssertEqual(model.source, source); XCTAssertEqual(model.notebook.state, .notStarted)
    }
    func testManualCompletionWorksWithAutomaticOffAndHonorsLimitAndTabOnlyAcceptance() async throws {
        let value = try settings(); value.completionAutomatic = false
        value.completionLimit = 20; value.completionReturn = false; value.completionSignature = false
        value.completionParameters = false; value.completionRuntime = false
        let source = "```{r}\n" + (1...60).map { String(format: "prefs_item_%03d <- 1\n", $0) }.joined() + "prefs_\n```\n"
        let (model, host, window) = fixture(source, settings: value)
        model.sourceOnly = true; host.update()
        let cursor = (source as NSString).range(of: "prefs_\n").upperBound - 1
        host.editor.setSelectedRange(NSRange(location: cursor, length: 0))
        host.editor.scrollRangeToVisible(host.editor.selectedRange()); window.makeFirstResponder(host.editor)
        let controller = try XCTUnwrap(host.completion)
        controller.schedule(manual: false); try await Task.sleep(for: .milliseconds(300))
        let inactive = await controller.session.processID
        XCTAssertNil(inactive)
        func complete() async throws {
            controller.schedule(manual: true)
            for _ in 0..<200 { if controller.isPresented { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail("Manual completion did not present")
        }
        try await complete()
        XCTAssertEqual(controller.candidates.count, 20); XCTAssertNil(controller.signature)
        XCTAssertFalse(controller.candidates.contains(where: \.isParameter))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(controller.handle(enter)); XCTAssertFalse(controller.isPresented); XCTAssertEqual(host.editor.string, source)
        try await complete()
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertTrue(controller.handle(tab)); host.publishCommittedText()
        XCTAssertTrue(model.source.contains("\nprefs_item_001\n"))
        host.undoSource(nil); XCTAssertEqual(model.source, source)
        XCTAssertEqual(model.notebook.state, .notStarted)
        await controller.session.stop()
    }
}
