import AppKit
import Markdown
import XCTest
@testable import Rnotebook

@MainActor final class HelpCenterTests: XCTestCase {
    private let bundle = Bundle(for: RecordNativeEditorHost.self)
    private func context(_ languageID: String = "zh-Hans", register: @escaping (Bundle) -> Bool = { _ in true }, open: @escaping (String, String) -> Void = { _,_ in }, error: @escaping (Error) -> Void = { _ in }) throws -> (NotebookHelpCenter, LanguageSettings, UserDefaults) {
        let previous = L10n.resources.language
        addTeardownBlock { L10n.configure(language: previous) }
        let suite = "HelpCenterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(languageID, forKey: LanguageSettings.preferenceKey)
        let language = LanguageSettings(defaults: defaults)
        let help = NotebookHelpCenter(language: language, behavior: .init(defaults: defaults), bundle: bundle, registerBook: register, openAnchor: open, reportError: error)
        addTeardownBlock { @MainActor in
            help.guideWindows.values.forEach { $0.close() }; help.browserWindow?.close()
            defaults.removePersistentDomain(forName: suite)
        }
        NSApp.activate(ignoringOtherApps: true)
        return (help, language, defaults)
    }
    private func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    private func bookRoot() throws -> URL { try XCTUnwrap(bundle.resourceURL).appendingPathComponent(NotebookHelpCenter.folder) }

    func testDetailedArticlesAndNativeBookHaveMatchingAnchorsAndSafeLiteralSyntax() throws {
        let root = try bookRoot().appendingPathComponent("Contents/Resources")
        for language in AppLanguage.supported {
            for topic in NotebookHelpTopic.allCases {
                let content = try NotebookHelpContent.load(topic, language: language, bundle: bundle)
                XCTAssertTrue(content.markdown.hasPrefix("# ")); XCTAssertGreaterThan(content.markdown.count, 250)
                let html = try String(contentsOf: root.appendingPathComponent(language.id + ".lproj/" + topic.rawValue + ".html"), encoding: .utf8)
                XCTAssertTrue(html.contains("name=\"rnotebook-" + topic.rawValue + "\""))
                XCTAssertTrue(html.contains("lang=\"" + language.id + "\""))
                XCTAssertFalse(html.contains("<script")); XCTAssertFalse(html.contains("<iframe"))
                XCTAssertFalse(html.contains("rnotebook-help://"))
                if topic == .syntax {
                    for token in ["&lt;u&gt;", "&lt;kbd&gt;", "&lt;!--", "&lt;sup&gt;", "<table>", "#|", "[[", "mermaid", "^block-id", "[!TIP]-"] { XCTAssertTrue(html.contains(token), token) }
                }
            }
            let home = try String(contentsOf: root.appendingPathComponent(language.id + ".lproj/index.html"), encoding: .utf8)
            XCTAssertTrue(home.contains("name=\"rnotebook-home\""))
            for topic in NotebookHelpTopic.allCases { XCTAssertTrue(home.contains(topic.rawValue + ".html")) }
            for index in ["search.helpindex", "search.cshelpindex"] {
                XCTAssertGreaterThan(try Data(contentsOf: root.appendingPathComponent(language.id + ".lproj/" + index)).count, 1000)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("AppIcon.png").path))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: try bookRoot().appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, bundle.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String)
        XCTAssertEqual(plist["HPDBookType"] as? String, "3")
        XCTAssertEqual(plist["HPDBookCSIndexPath"] as? String, "search.cshelpindex")
    }

    func testQuickStartExampleHasOneRunnableBaseRChunkAndNativeBlocksPreserveLiteralSource() throws {
        for language in AppLanguage.supported {
            let content = try NotebookHelpContent.load(.quickStart, language: language, bundle: bundle)
            let blocks = NotebookHelpGuideBlock.parse(content.markdown)
            let samples = blocks.compactMap { block -> String? in if case .code = block.kind { return block.text }; return nil }
            XCTAssertEqual(samples.count, 1)
            let code = try XCTUnwrap(samples.first)
            XCTAssertTrue(code.hasPrefix("---\ntitle:")); XCTAssertTrue(code.contains("```{r}\nvalues <- c(12, 18, 24)"))
            let notebook = Document(parsing: code).children.compactMap { $0 as? CodeBlock }
            XCTAssertEqual(notebook.count, 1); XCTAssertEqual(notebook.first?.language, "{r}")
            XCTAssertEqual(notebook.first?.code, "values <- c(12, 18, 24)\nmean(values)\nplot(values, type = \"b\")\n")
        }
        let parsed = NotebookHelpGuideBlock.parse("# Test\n\n```html\n<script>alert('literal')</script>\n```\n\n| Syntax | Result |\n| --- | --- |\n| `<u>x</u>` | Underline |\n")
        XCTAssertEqual(parsed.count, 3); XCTAssertEqual(parsed[1].text, "<script>alert('literal')</script>\n")
        XCTAssertEqual(parsed[2].rows.count, 2); XCTAssertEqual(parsed[2].rows[1][0], "`<u>x</u>`")
    }

    func testOptionalSystemHelpUsesRegistrationAndNamedAnchors() throws {
        var registered: [Bundle] = [], opened: [(String,String)] = [], errors: [Error] = []
        let (help, _, _) = try context(register: { registered.append($0); return true }, open: { opened.append(($0,$1)) }, error: { errors.append($0) })
        help.openInSystemHelp(nil); help.openInSystemHelp(.syntax); help.openInSystemHelp(.quickStart); help.openInSystemHelp(.overview)
        XCTAssertEqual(registered.count, 4); XCTAssertTrue(registered.allSatisfy { $0 == bundle })
        XCTAssertEqual(opened.map(\.0), ["rnotebook-home", "rnotebook-syntax", "rnotebook-quick-start", "rnotebook-overview"])
        XCTAssertTrue(opened.allSatisfy { $0.1 == "org.hiox.Rnotebook.help" }); XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(help.guideWindows.isEmpty)
    }

    func testRegistrationFailureReportsErrorWithoutOpeningAnInvalidBook() throws {
        var opened = false, errors: [Error] = []
        let (help, _, _) = try context(register: { _ in false }, open: { _,_ in opened = true }, error: { errors.append($0) })
        help.openInSystemHelp(nil); XCTAssertFalse(opened); XCTAssertEqual(errors.count, 1)
        XCTAssertEqual((errors.first as NSError?)?.code, 12)
    }

    func testDirectGuidesAreIndependentReusableNativeWindowsWithoutDocumentsOrWebViews() throws {
        let (help, _, _) = try context("en")
        let count = NSDocumentController.shared.documents.count
        help.showArticle(.quickStart); help.showArticle(.syntax)
        let quick = try XCTUnwrap(help.guideWindows[.quickStart]?.window), syntax = try XCTUnwrap(help.guideWindows[.syntax]?.window)
        XCTAssertFalse(quick === syntax); XCTAssertEqual(help.guideWindows.count, 2)
        XCTAssertNil(quick.windowController?.document); XCTAssertNil(syntax.windowController?.document)
        XCTAssertEqual(syntax.tabbingMode, .disallowed); XCTAssertEqual(syntax.titleVisibility, .hidden)
        XCTAssertEqual(syntax.accessibilityIdentifier(), "notebook-guide-syntax")
        func hasWebView(_ view: NSView) -> Bool { String(describing: type(of: view)).contains("WKWebView") || view.subviews.contains(where: hasWebView) }
        XCTAssertFalse(hasWebView(try XCTUnwrap(syntax.contentView)))
        syntax.close(); help.showArticle(.syntax); XCTAssertTrue(help.guideWindows[.syntax]?.window === syntax)
        XCTAssertEqual(NSDocumentController.shared.documents.count, count)
    }

    func testLanguageUpdatesNativeGuideContentAndExistingWindow() async throws {
        let (help, language, _) = try context()
        let model = try NotebookHelpGuideModel(topic: .quickStart, language: .simplifiedChinese, bundle: bundle)
        model.observe(language); help.showArticle(.quickStart)
        let window = try XCTUnwrap(help.guideWindows[.quickStart]?.window)
        XCTAssertEqual(window.title, "快速开始"); XCTAssertEqual(model.blocks.first?.text, "快速开始")
        XCTAssertTrue(language.select("en"))
        for _ in 0..<20 { if window.title == "Quick Start" && model.blocks.first?.text == "Quick Start" { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(window.title, "Quick Start"); XCTAssertEqual(model.blocks.first?.text, "Quick Start")
        XCTAssertTrue(help.guideWindows[.quickStart]?.window === window)
    }

    func testNativeHelpMenuSearchShortcutTopicsAndOfficialLinksRemainAvailableWithoutDocument() throws {
        let previous = L10n.resources.language; defer { L10n.configure(language: previous) }
        L10n.configure(language: .english)
        let delegate = RnotebookDelegate(), main = RnotebookApp.makeMenu(commandTarget: delegate)
        let menu = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.identifier?.rawValue == "notebook-help-menu" })
        XCTAssertTrue(NSApp.helpMenu === menu); XCTAssertEqual(menu.title, "Help")
        for action in [#selector(RnotebookDelegate.showHelpCenter(_:)), #selector(RnotebookDelegate.showQuickStart(_:)), #selector(RnotebookDelegate.showSyntaxReference(_:))] {
            XCTAssertTrue(delegate.validateMenuItem(try XCTUnwrap(items(menu).first { $0.action == action })))
        }
        XCTAssertEqual(items(menu).first { $0.action == #selector(RnotebookDelegate.showQuickStart(_:)) }?.title, "Quick Start")
        XCTAssertEqual(items(menu).first { $0.action == #selector(RnotebookDelegate.showSyntaxReference(_:)) }?.title, "Quarto Syntax")
        let home = try XCTUnwrap(items(menu).first { $0.action == #selector(RnotebookDelegate.showHelpCenter(_:)) })
        XCTAssertEqual(home.keyEquivalent, "/"); XCTAssertEqual(home.keyEquivalentModifierMask, [.command, .shift])
        let rSearch = try XCTUnwrap(items(menu).first { $0.action == #selector(RnotebookDelegate.focusHelpSearch(_:)) })
        XCTAssertEqual(rSearch.keyEquivalent, "")
        XCTAssertEqual(Set(items(menu).compactMap { ($0.representedObject as? URL)?.absoluteString }), Set(NotebookHelpExternal.allCases.map { $0.url.absoluteString }))
    }

    func testMainHelpUsesReusableNativeSplitOutlineAndKeepsNavigationWhenReopened() throws {
        var systemCalls = 0
        let (help, _, _) = try context("en", register: { _ in systemCalls += 1; return true })
        let count = NSDocumentController.shared.documents.count
        help.showHome()
        let browser = try XCTUnwrap(help.browserWindow), window = try XCTUnwrap(browser.window)
        XCTAssertEqual(browser.split.splitViewItems.count, 2)
        XCTAssertTrue(browser.split.splitViewItems[0].behavior == .sidebar)
        func outline(_ view: NSView) -> NSOutlineView? { (view as? NSOutlineView) ?? view.subviews.compactMap(outline).first }
        let tree = try XCTUnwrap(outline(browser.split.splitViewItems[0].viewController.view))
        XCTAssertEqual(tree.numberOfRows, NotebookHelpTopic.allCases.count); XCTAssertEqual(tree.style, .sourceList)
        let syntax = try XCTUnwrap(browser.model.roots.first { $0.location.topic == .syntax })
        XCTAssertGreaterThan(syntax.children.count, 5)
        browser.model.navigate(try XCTUnwrap(syntax.children.last).location)
        window.close(); help.showHome()
        XCTAssertTrue(help.browserWindow?.window === window)
        XCTAssertEqual(browser.model.location.topic, .syntax); XCTAssertNotNil(browser.model.location.blockID)
        XCTAssertEqual(systemCalls, 0); XCTAssertEqual(NSDocumentController.shared.documents.count, count)
        XCTAssertNil(window.windowController?.document); XCTAssertEqual(window.tabbingMode, .disallowed)
    }

    func testHelpSidebarUsesItsSafeAreaAndTitleLivesInReaderToolbarSection() async throws {
        let (help, _, _) = try context("en"); help.showHome()
        let browser = try XCTUnwrap(help.browserWindow), window = try XCTUnwrap(browser.window)
        try await Task.sleep(for: .milliseconds(160)); window.contentView?.layoutSubtreeIfNeeded()
        func scroll(_ node: NSView) -> NSScrollView? { (node as? NSScrollView) ?? node.subviews.compactMap(scroll).first }
        let surface = try XCTUnwrap(scroll(browser.split.splitViewItems[0].viewController.view))
        let top = surface.convert(surface.bounds, to: nil).maxY
        XCTAssertLessThanOrEqual(top, window.contentLayoutRect.maxY + 1)
        XCTAssertEqual(window.titleVisibility, .hidden)
        let ids = try XCTUnwrap(window.toolbar).items.map(\.itemIdentifier.rawValue)
        let separator = try XCTUnwrap(ids.firstIndex(of: NSToolbarItem.Identifier.sidebarTrackingSeparator.rawValue))
        let toggle = try XCTUnwrap(ids.firstIndex(of: NSToolbarItem.Identifier.toggleSidebar.rawValue))
        let title = try XCTUnwrap(ids.firstIndex(of: "help-title"))
        XCTAssertGreaterThan(toggle, separator, "The sidebar toggle hugs the right edge of the outline panel")
        XCTAssertGreaterThan(title, separator)
    }

    func testSearchFindsBodyAndLiteralCodeAndClearsWithoutChangingArticle() throws {
        let (help, _, _) = try context("en"); help.showHome()
        let model = try XCTUnwrap(help.browserWindow?.model)
        let before = model.location
        model.search("mean(values)")
        let quick = try XCTUnwrap(model.roots.first { $0.location.topic == .quickStart })
        XCTAssertEqual(quick.children.count, 2)
        XCTAssertTrue(quick.children[0].title.contains("small example"))
        XCTAssertTrue(quick.children[1].title.contains("Run R code"))
        XCTAssertEqual(model.location, before)
        model.search("does-not-exist-" + UUID().uuidString); XCTAssertTrue(model.roots.isEmpty)
        model.search(""); XCTAssertEqual(model.roots.count, NotebookHelpTopic.allCases.count); XCTAssertEqual(model.location, before)
    }

    func testHelpHistoryNavigatesSubsectionsAndDiscardsForwardBranch() throws {
        let (help, _, _) = try context("en"); help.showHome()
        let model = try XCTUnwrap(help.browserWindow?.model)
        let target = try XCTUnwrap(model.roots.first { $0.location.topic == .syntax }?.children.last?.location)
        model.navigate(target); model.navigate(.init(topic: .files))
        XCTAssertTrue(model.canGoBack); XCTAssertFalse(model.canGoForward)
        model.back(); XCTAssertEqual(model.location, target); XCTAssertTrue(model.canGoForward)
        model.back(); XCTAssertEqual(model.location.topic, .overview)
        model.forward(); XCTAssertEqual(model.location, target)
        model.navigate(.init(topic: .shortcuts)); XCTAssertFalse(model.canGoForward)
        model.back(); XCTAssertEqual(model.location, target)
    }

    func testBrowserLanguageUpdatesOutlineAndArticleWithoutLosingLocationOrSearch() async throws {
        let (help, language, _) = try context(); help.showDetailed(.files)
        let browser = try XCTUnwrap(help.browserWindow), model = browser.model
        XCTAssertEqual(model.blocks.first?.text, "保存、恢复与设置")
        model.search("QMD")
        XCTAssertTrue(language.select("en"))
        for _ in 0..<20 { if model.blocks.first?.text == "Saving, Recovery and Settings" { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.blocks.first?.text, "Saving, Recovery and Settings")
        XCTAssertEqual(model.location.topic, .files); XCTAssertEqual(model.query, "QMD")
        XCTAssertEqual(model.roots.first?.title, "Meet Rnotebook")
    }

    func testReadingGuidesCannotRunOrFormatBackgroundDocument() async throws {
        let (help, _, defaults) = try context()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HelpDoc-" + UUID().uuidString)
        let document = QMDDocument(recoveryStore: .init(directory: root), behavior: .init(defaults: defaults))
        document.sourceSettings = .init(defaults: defaults); document.visual = .init(defaults: defaults); document.appearance = .init(defaults: defaults)
        document.model.source = "```{r}\nstop('must not execute')\n```\n"; document.makeWindowControllers()
        defer { document.close(); try? FileManager.default.removeItem(at: root) }
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        help.showDetailed(.syntax); try await Task.sleep(for: .milliseconds(100))
        let delegate = RnotebookDelegate(), main = RnotebookApp.makeMenu(commandTarget: delegate)
        let run = try XCTUnwrap(items(main).first { $0.action == #selector(RnotebookDelegate.runAll(_:)) })
        XCTAssertFalse(delegate.validateMenuItem(run)); XCTAssertNil(NotebookCommandContext.shared.target)
        let find = try XCTUnwrap(items(main).first { $0.action == #selector(RnotebookDelegate.findInDocument(_:)) && $0.tag == NSTextFinder.Action.showFindInterface.rawValue })
        // This delegate owns a separate help center; use its browser for command routing.
        delegate.helpCenter.showHome()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(delegate.validateMenuItem(find)); delegate.findInDocument(find)
        XCTAssertTrue(delegate.helpCenter.browserWindow?.window?.firstResponder is NSTextView)
        delegate.helpCenter.browserWindow?.close()
        XCTAssertEqual(document.model.source, "```{r}\nstop('must not execute')\n```\n")
        XCTAssertEqual(document.model.notebook.state, .notStarted)
    }
}
