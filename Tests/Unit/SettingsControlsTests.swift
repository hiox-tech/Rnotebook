import AppKit
import SwiftUI
import XCTest
@testable import Rnotebook

@MainActor final class SettingsControlsTests: XCTestCase {
    func testNumericInputCommitsValidSizeAndRejectsIncompleteOrInvalidValues() {
        var stored = 13.0
        let control = FontSizeControl(value: Binding(get: { stored }, set: { stored = $0 }),
                                      range: 10...32, identifier: "test-size", label: "字号")
        control.field.stringValue = "18.5"
        control.field.sendAction(control.field.action, to: control.field.target)
        XCTAssertEqual(stored, 18.5)
        for text in ["", "-", "abc", "NaN", "inf", "9", "33"] {
            control.field.stringValue = text
            control.field.sendAction(control.field.action, to: control.field.target)
            XCTAssertEqual(stored, 18.5, text)
            XCTAssertEqual(control.stepper.doubleValue, 18.5)
        }
        control.stepper.doubleValue = 19.5
        control.stepper.sendAction(control.stepper.action, to: control.stepper.target)
        XCTAssertEqual(stored, 19.5)
        stored = 24
        control.refresh()
        XCTAssertEqual(control.field.stringValue, "24")
        XCTAssertEqual(control.stepper.doubleValue, 24)
        control.field.stringValue = "16"
        control.controlTextDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertEqual(stored, 24, "Typing is staged until committed")
        XCTAssertEqual(control.stepper.doubleValue, 16)
        control.stepper.doubleValue += 1
        control.stepper.sendAction(control.stepper.action, to: control.stepper.target)
        XCTAssertEqual(stored, 17, "Stepping continues from the typed value")
    }

    func testFontPreviewSurfaceUsesTheSameRoundedPanelAsSyntaxPreview() {
        let surface = SettingsPreviewSurface(frame: NSRect(x: 0, y: 0, width: 320, height: 82))
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.layer?.cornerRadius, 6)
        XCTAssertEqual(surface.layer?.cornerCurve, .continuous)
        XCTAssertEqual(surface.layer?.masksToBounds, true)
        XCTAssertEqual(surface.label.frame, surface.bounds.insetBy(dx: 12, dy: 10))
        XCTAssertNotNil(surface.layer?.backgroundColor)
    }

    func testHighlightingPaneOmitsCodeAppearanceControl() async throws {
        let suite = "SettingsControls." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let original = L10n.resources.language
        defer { L10n.configure(language: original); defaults.removePersistentDomain(forName: suite) }
        let language = LanguageSettings(defaults: defaults, systemLanguages: { ["en"] })
        let controller = NotebookSettingsController(language: language,
            source: .init(defaults: defaults), visual: .init(defaults: defaults),
            appearance: .init(defaults: defaults), behavior: .init(defaults: defaults))
        let window = controller.makeWindow(); defer { window.close() }
        controller.selectedTabViewItemIndex = try XCTUnwrap(NotebookSettingsPane.allCases.firstIndex(of: .highlighting))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(120))
        window.contentView?.layoutSubtreeIfNeeded()
        func find(_ view: NSView, _ identifier: String) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            for child in view.subviews { if let match = find(child, identifier) { return match } }
            return nil
        }
        func preview(_ view: NSView) -> Bool {
            if view is SyntaxPreviewSurface { return true }
            return view.subviews.contains { preview($0) }
        }
        XCTAssertNil(find(controller.view, "source-editor-theme"))
        XCTAssertTrue(preview(controller.view))
    }

    func testFormattingPaneGrowsOnlyWhileCustomOptionsAreVisible() async throws {
        let suite = "SettingsControls." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let original = L10n.resources.language
        defer { L10n.configure(language: original); defaults.removePersistentDomain(forName: suite) }
        let source = SourceEditorSettings(defaults: defaults)
        let controller = NotebookSettingsController(language: LanguageSettings(defaults: defaults, systemLanguages: { ["en"] }),
            source: source, visual: .init(defaults: defaults),
            appearance: .init(defaults: defaults), behavior: .init(defaults: defaults))
        controller.selectedTabViewItemIndex = try XCTUnwrap(NotebookSettingsPane.allCases.firstIndex(of: .formatting))
        let window = controller.makeWindow(); defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(140))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.height ?? 0, 96, accuracy: 2)
        source.formatMode = "custom"
        try await Task.sleep(for: .milliseconds(180))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.height ?? 0, 204, accuracy: 2)
        source.formatMode = "document"
        try await Task.sleep(for: .milliseconds(180))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.height ?? 0, 96, accuracy: 2)
    }

    func testEnvironmentSelectionRejectsDirectoriesAndNonExecutableFilesWithoutCreatingDefaults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("absent")
        XCTAssertNotNil(SettingsEnvironment.selectionError(missing, directory: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNotNil(SettingsEnvironment.selectionError(folder, directory: false))
        XCTAssertNil(SettingsEnvironment.selectionError(folder, directory: true))
        let file = folder.appendingPathComponent("Rscript")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertNotNil(SettingsEnvironment.selectionError(file, directory: false))
        XCTAssertNotNil(SettingsEnvironment.selectionError(file, directory: true))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        XCTAssertNil(SettingsEnvironment.selectionError(file, directory: false))
    }
}
