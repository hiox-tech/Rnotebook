import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class SettingsCompletionTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "SettingsCompletion." + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }
    func testSystemFontAndTwelvePointDefaultsPreserveExplicitPreferences() throws {
        let preferences = try defaults()
        let source = SourceEditorSettings(defaults: preferences)
        let visual = VisualEditorSettings(defaults: preferences)
        XCTAssertEqual(source.fontName, "system"); XCTAssertEqual(source.fontSize, 12)
        XCTAssertEqual(visual.bodyFont, "system"); XCTAssertEqual(visual.bodySize, 12)
        XCTAssertEqual(visual.codeFont, "system"); XCTAssertEqual(visual.codeSize, 12)
        XCTAssertTrue(Set(NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }).isSubset(of: Set(NotebookFontCatalog.families)))
        source.fontName = "Monaco"; source.fontSize = 18.5
        visual.bodyFont = "Songti SC"; visual.bodySize = 16
        visual.codeFont = "Menlo"; visual.codeSize = 15
        XCTAssertEqual(SourceEditorSettings(defaults: preferences).fontName, "Monaco")
        XCTAssertEqual(SourceEditorSettings(defaults: preferences).fontSize, 18.5)
        XCTAssertEqual(VisualEditorSettings(defaults: preferences).bodyFont, "Songti SC")
        XCTAssertEqual(VisualEditorSettings(defaults: preferences).codeSize, 15)
        preferences.set("not-an-installed-font", forKey: "sourceEditor.font")
        preferences.set(Double.infinity, forKey: "sourceEditor.size")
        XCTAssertEqual(SourceEditorSettings(defaults: preferences).fontName, "system")
        XCTAssertEqual(SourceEditorSettings(defaults: preferences).fontSize, 12)
    }
    func testSystemDefaultsReachNativeCodeAndVisualText() throws {
        let preferences = try defaults()
        let model = RecordLayoutModel(visualDefaults: preferences, initialSource: "text\n\n```{r}\n1+1\n```\n", usesProcessArguments: false)
        let host = RecordNativeEditorHost(model: model, sourceSettings: SourceEditorSettings(defaults: preferences))
        defer { host.detach() }
        model.sourceOnly = true; host.update()
        let codeFont = try XCTUnwrap(host.editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(codeFont.pointSize, 12)
        XCTAssertEqual(codeFont.fontName, NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)
        model.sourceOnly = false; host.update()
        let bodyFont = try XCTUnwrap(host.editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(bodyFont.pointSize, 12)
        XCTAssertEqual(bodyFont.fontName, NSFont.systemFont(ofSize: 12).fontName)
    }
    func testChineseAndEnglishResourcesCoverEveryKeyAndFormatInterpolation() throws {
        let bundle = Bundle(for: RecordNativeEditorHost.self)
        let chineseURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "zh-Hans.lproj"))
        let englishURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"))
        let chinese = try XCTUnwrap(NSDictionary(contentsOf: chineseURL) as? [String: String])
        let english = try XCTUnwrap(NSDictionary(contentsOf: englishURL) as? [String: String])
        XCTAssertEqual(Set(chinese.keys), Set(english.keys))
        XCTAssertGreaterThan(english.count, 550)
        for (key, value) in english {
            XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, key)
            XCTAssertNil(value.range(of: "[\\p{Han}]", options: .regularExpression), key)
        }
        let englishResources = LocalizationResources(language: .english, bundle: bundle)
        XCTAssertEqual(englishResources.string("通用"), "General")
        XCTAssertEqual(englishResources.string("标题 \(String(3))"), "Heading 3")
        XCTAssertEqual(englishResources.string("R 通信操作失败：\(String("read")) (\(String(5)))"), "R communication failed: read (5)")
        XCTAssertEqual(AppLanguage.resolve(preferred: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferred: ["zh-CN"]), .simplifiedChinese)
    }
    func testLanguageSelectionPersistsAndUpdatesAppScopedNativePreference() throws {
        defer { L10n.configure(language: .simplifiedChinese) }
        let preferences = try defaults()
        let originalNativeLanguages = preferences.stringArray(forKey: "AppleLanguages")
        let settings = LanguageSettings(defaults: preferences, systemLanguages: { ["zh-Hans"] })
        XCTAssertTrue(settings.select("en"))
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(preferences.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertFalse(settings.select("fr"))
        XCTAssertEqual(settings.preference, "en")
        XCTAssertEqual(LanguageSettings(defaults: preferences).language, .english)
        XCTAssertTrue(settings.select("system"))
        XCTAssertEqual(settings.language, .simplifiedChinese)
        XCTAssertEqual(preferences.stringArray(forKey: "AppleLanguages"), originalNativeLanguages)
    }
    func testFollowSystemIgnoresCachedEnglishAndExplicitAppOverrideAcrossRestart() throws {
        let original = L10n.resources.language
        defer { L10n.configure(language: original) }
        let preferences = try defaults()
        preferences.set("en", forKey: LanguageSettings.preferenceKey)
        preferences.set(["en"], forKey: "AppleLanguages")
        let system = { SystemInterfaceLanguages.preferred(globalDomain: ["AppleLanguages": ["zh-Hans-CN"]], fallback: { ["en"] }) }
        let settings = LanguageSettings(defaults: preferences, systemLanguages: system)
        XCTAssertEqual(settings.language, .english)
        XCTAssertTrue(settings.select("system"))
        XCTAssertEqual(settings.language, .simplifiedChinese)
        XCTAssertEqual(settings.preference, "system")
        XCTAssertEqual(LanguageSettings(defaults: preferences, systemLanguages: system).language, .simplifiedChinese)
        XCTAssertTrue(settings.select("en")); XCTAssertEqual(settings.language, .english)
        XCTAssertTrue(settings.select("system")); XCTAssertEqual(settings.language, .simplifiedChinese)
        // A stale per-app native override must also be removed on system startup.
        preferences.set(["en"], forKey: "AppleLanguages")
        let restarted = LanguageSettings(defaults: preferences, systemLanguages: system)
        XCTAssertEqual(restarted.language, .simplifiedChinese)
        XCTAssertNotEqual(preferences.stringArray(forKey: "AppleLanguages"), ["en"])
    }

    func testDefaultFollowSystemReadsActualGlobalDomainWithoutChangingIt() throws {
        let original = L10n.resources.language
        defer { L10n.configure(language: original) }
        let globalBefore = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        let expected = AppLanguage.resolve(preferred: try XCTUnwrap(globalBefore))
        let preferences = try defaults()
        let settings = LanguageSettings(defaults: preferences)
        XCTAssertTrue(settings.select("en")); XCTAssertEqual(settings.language, .english)
        XCTAssertTrue(settings.select("system")); XCTAssertEqual(settings.language, expected)
        XCTAssertEqual(LanguageSettings(defaults: preferences).language, expected)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String], globalBefore)
    }

    func testDependencyReportsRequireEveryPackageAndRejectFailureAndIncompleteOutput() {
        let packages = DependencyService.requiredPackages
        func output(_ text: String, code: Int32 = 0, cancelled: Bool = false, timedOut: Bool = false) -> QuartoProcessOutput {
            .init(exitCode: code, stdout: Data(text.utf8), stderr: Data(), truncated: false, cancelled: cancelled, timedOut: timedOut)
        }
        let success = "RNOTEBOOK_R_VERSION\tR 4.6.1\n" + packages.map { "RNOTEBOOK_PACKAGE\t\($0)\tok\n" }.joined()
        let complete = DependencyService.parse(output(success))
        XCTAssertTrue(complete.packagesChecked); XCTAssertTrue(complete.missing.isEmpty)
        XCTAssertTrue(complete.errors.isEmpty); XCTAssertFalse(complete.ready, "Quarto has not been checked")
        let missing = DependencyService.parse(output(success.replacingOccurrences(of: "jsonlite\tok", with: "jsonlite\tmissing")))
        XCTAssertEqual(missing.missing, ["jsonlite"])
        XCTAssertTrue(missing.packagesChecked)
        XCTAssertFalse(DependencyService.parse(output("garbage")).packagesChecked)
        XCTAssertFalse(DependencyService.parse(output(success, code: 1)).errors.isEmpty)
        XCTAssertFalse(DependencyService.parse(output(success, cancelled: true)).errors.isEmpty)
        XCTAssertFalse(DependencyService.parse(output(success, timedOut: true)).errors.isEmpty)
    }
    func testRealBaseRDetectsAndInstallsMissingPackageInIsolatedLibraryFromLocalRepository() async throws {
        let executable = try XCTUnwrap(NotebookRExecutable.locate(selected: nil))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DependencyInstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("library with spaces'quoted")
        let package = "rnotebookdependencyfixture"
        let source = folder.appendingPathComponent(package)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("R"), withIntermediateDirectories: true)
        try Data("Package: \(package)\nVersion: 1.0.0\nTitle: Dependency Installation Fixture\nDescription: A local package for isolated dependency installation tests.\nAuthor: Rnotebook\nMaintainer: Rnotebook <test@example.invalid>\nLicense: MIT\n".utf8).write(to: source.appendingPathComponent("DESCRIPTION"))
        try Data("export(fixture)\n".utf8).write(to: source.appendingPathComponent("NAMESPACE"))
        try Data("fixture <- function() 12L\n".utf8).write(to: source.appendingPathComponent("R/fixture.R"))
        let repository = folder.appendingPathComponent("repository")
        let contrib = repository.appendingPathComponent("src/contrib")
        try FileManager.default.createDirectory(at: contrib, withIntermediateDirectories: true)
        let archive = contrib.appendingPathComponent(package + "_1.0.0.tar.gz")
        let tar = QuartoProcess()
        let packed = try await tar.run(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", archive.path, "-C", folder.path, package], directory: folder, environment: ProcessInfo.processInfo.environment, timeout: 15)
        XCTAssertEqual(packed.exitCode, 0)
        let index = try await QuartoProcess().run(executable: executable, arguments: ["--vanilla", "-e", "tools::write_PACKAGES(commandArgs(TRUE)[[1L]], type='source')", contrib.path], directory: folder, environment: ProcessInfo.processInfo.environment, timeout: 30)
        XCTAssertEqual(index.exitCode, 0)
        let configuration = DependencyConfiguration(rscript: executable, quarto: nil, library: library, repository: repository.absoluteString)
        let before = try await DependencyService.runR(configuration, install: false, process: QuartoProcess(), packages: [package])
        XCTAssertEqual(DependencyService.parse(before, packages: [package]).missing, [package])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path), "Checking does not create a library")
        let installed = try await QuartoProcess().run(executable: executable,
            arguments: ["--vanilla", "-e", "options(pkgType='source');" + DependencyService.script(install: true, packages: [package]), library.path, repository.absoluteString],
            directory: folder, environment: DependencyService.environment(configuration), timeout: 60)
        XCTAssertEqual(installed.exitCode, 0, String(decoding: installed.stderr, as: UTF8.self))
        let checked = try await DependencyService.runR(configuration, install: false, process: QuartoProcess(), packages: [package])
        let report = DependencyService.parse(checked, packages: [package])
        XCTAssertTrue(report.packagesChecked); XCTAssertTrue(report.missing.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent(package + "/DESCRIPTION").path))
    }
    func testMissingToolsAndCancellationDoNotRequireAnRSession() async throws {
        let manager = EnvironmentDependencies()
        let configuration = DependencyConfiguration(rscript: nil, quarto: nil, library: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        manager.check(configuration)
        for _ in 0..<100 where manager.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(manager.isBusy)
        XCTAssertEqual(manager.report?.errors.count, 2)
        manager.installMissing(configuration)
        XCTAssertFalse(manager.isInstalling)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.library.path))
        await manager.shutdown()
    }
}
