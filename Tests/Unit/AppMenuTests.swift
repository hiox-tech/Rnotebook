import AppKit
import XCTest
@testable import Rnotebook

@MainActor final class AppMenuTests: XCTestCase {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(220)) }
    private func entries(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(entries) ?? []) }
    }
    private func menu(_ delegate: RnotebookDelegate) -> NSMenu { RnotebookApp.makeMenu(commandTarget: delegate) }
    private func item(_ action: Selector, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(entries(menu).first { $0.action == action })
    }
    private func install(_ menu: NSMenu) {
        let previous = NSApp.mainMenu
        NSApp.mainMenu = menu
        addTeardownBlock { @MainActor in NSApp.mainMenu = previous }
    }
    private func document(_ source: String, saved: Bool = true) throws -> (QMDDocument, NSWindow) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppMenuTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferences = try XCTUnwrap(UserDefaults(suiteName: folder.lastPathComponent))
        let doc = QMDDocument(recoveryStore: .shared, behavior: DocumentBehaviorSettings(defaults: preferences))
        doc.sourceSettings = SourceEditorSettings(defaults: preferences)
        doc.visual = VisualEditorSettings(defaults: preferences)
        doc.appearance = AppearanceSettings(defaults: preferences)
        if saved {
            let url = folder.appendingPathComponent("Menu.qmd")
            try Data(source.utf8).write(to: url)
            try doc.read(from: url, ofType: "org.quarto.qmd"); doc.fileURL = url
        } else { doc.model.source = source }
        doc.makeWindowControllers()
        let window = try XCTUnwrap(doc.windowControllers.first?.window)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            await doc.model.notebook.shutdown()
            doc.model.menuInsertion = nil
            try? await Task.sleep(for: .milliseconds(100))
            doc.discardRecovery(); doc.updateChangeCount(.changeCleared); doc.close()
            preferences.removePersistentDomain(forName: folder.lastPathComponent)
            try? FileManager.default.removeItem(at: folder)
        }
        return (doc, window)
    }
    private func click(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }
    private func sheetButton(_ title: String, in window: NSWindow) throws -> NSButton {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let content = try XCTUnwrap(window.attachedSheet?.contentView)
        return try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    func testMenusSwitchLanguageIncludingPreviouslyCachedToolsAndGroupBoundaries() throws {
        defer { L10n.configure(language: .simplifiedChinese) }
        let delegate = RnotebookDelegate()
        for language in [AppLanguage.simplifiedChinese, .english, .simplifiedChinese] {
            L10n.configure(language: language)
            let main = menu(delegate)
            XCTAssertEqual(main.items.map(\.title), language == .english
                ? ["Rnotebook", "File", "Edit", "Format", "Insert", "View", "Notebook", "R Session", "Window", "Help"]
                : ["Rnotebook", "文件", "编辑", "格式", "插入", "视图", "笔记本", "R 会话", "窗口", "帮助"])
            if language == .english {
                for entry in entries(main) { XCTAssertNil(entry.title.range(of: "[\\p{Han}]", options: .regularExpression), entry.title) }
            }
            func check(_ menu: NSMenu) {
                XCTAssertNotEqual(menu.items.first?.isSeparatorItem, true, menu.title)
                XCTAssertNotEqual(menu.items.last?.isSeparatorItem, true, menu.title)
                for pair in zip(menu.items, menu.items.dropFirst()) { XCTAssertFalse(pair.0.isSeparatorItem && pair.1.isSeparatorItem, menu.title) }
                for item in menu.items { if let sub = item.submenu { check(sub) } }
            }
            check(main)
            XCTAssertTrue(main.items.compactMap(\.submenu).allSatisfy { $0.items.contains(where: \.isSeparatorItem) })
            XCTAssertEqual(RecordVisualTool.common.first?.title, language == .english ? "Bold" : "加粗")
            XCTAssertEqual(RecordMermaidDiagram.all.first?.title, language == .english ? "Flowchart" : "流程图")
        }
    }

    func testAllEditingCommandsHaveMenuEntriesAndShortcutsAreUnique() throws {
        let main = menu(RnotebookDelegate())
        let commands = Set(entries(main).compactMap { $0.representedObject as? RecordVisualCommand })
        let special: Set<RecordVisualCommand> = [.table, .imageReference]
        let expected = Set(RecordVisualToolbarEntry.ordered.flatMap(\.reachableCommands) + [.headingIncrease, .headingDecrease])
        XCTAssertEqual(commands.union(special), expected)
        var shortcuts = Set<String>()
        for entry in entries(main) where !entry.keyEquivalent.isEmpty {
            let key = entry.keyEquivalent.lowercased() + ":" + String(entry.keyEquivalentModifierMask.rawValue)
            XCTAssertTrue(shortcuts.insert(key).inserted, entry.title)
        }
        XCTAssertNotNil(try item(#selector(RnotebookDelegate.insertTable(_:)), in: main))
        XCTAssertNotNil(try item(#selector(RnotebookDelegate.insertLinkedImage(_:)), in: main))
        XCTAssertNotEqual(try item(#selector(RnotebookDelegate.stopR(_:)), in: main).action,
                          try item(#selector(RnotebookDelegate.interruptR(_:)), in: main).action)
    }

    func testDocumentSyncTextSizeAndLayoutMenuActionsUseActiveDocument() async throws {
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let (doc, window) = try document("menu content\n")
        try await settle()
        let increase = try item(#selector(RnotebookDelegate.increaseTextSize(_:)), in: main)
        let decrease = try item(#selector(RnotebookDelegate.decreaseTextSize(_:)), in: main)
        let reset = try item(#selector(RnotebookDelegate.resetTextSize(_:)), in: main)
        doc.model.sourceOnly = true; try await settle()
        XCTAssertTrue(delegate.validateMenuItem(increase)); try click(increase)
        XCTAssertEqual(doc.sourceSettings.fontSize, 13); XCTAssertEqual(doc.visual.bodySize, 12)
        try click(decrease); XCTAssertEqual(doc.sourceSettings.fontSize, 12)
        doc.model.sourceOnly = false; try await settle()
        try click(increase); XCTAssertEqual(doc.visual.bodySize, 13); XCTAssertEqual(doc.visual.codeSize, 13)
        try click(reset); XCTAssertEqual(doc.visual.bodySize, 12); XCTAssertEqual(doc.visual.codeSize, 12)
        let check = try item(#selector(RnotebookDelegate.checkExternalChanges(_:)), in: main)
        let compare = try item(#selector(RnotebookDelegate.compareVersions(_:)), in: main)
        XCTAssertTrue(delegate.validateMenuItem(check)); XCTAssertFalse(delegate.validateMenuItem(compare))
        let url = try XCTUnwrap(doc.fileURL)
        doc.behavior.automaticallyReload = false
        try Data("external menu content\n".utf8).write(to: url, options: .atomic)
        try click(check); try await settle()
        XCTAssertEqual(doc.model.source, "menu content\n"); XCTAssertNotNil(doc.synchronization.conflict)
        XCTAssertNotNil(window.attachedSheet)
        await doc.synchronization.resolve(.later); try await settle()
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(delegate.validateMenuItem(compare)); try click(compare); try await settle()
        XCTAssertNotNil(window.attachedSheet)
        await doc.synchronization.resolve(.external); try await settle()
        XCTAssertNil(doc.synchronization.conflict); XCTAssertEqual(doc.model.source, "external menu content\n")
        let layout = try item(#selector(RnotebookDelegate.resetWindowLayout(_:)), in: main)
        XCTAssertTrue(delegate.validateMenuItem(layout)); try click(layout)
        let split = try XCTUnwrap(window.contentViewController as? NotebookSplitController)
        XCTAssertEqual(split.inspectorWidth, 280, accuracy: 2)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
    }

    func testMenusFollowKeyDocumentForFormattingViewsAndFloatingFind() async throws {
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let (first, _) = try document("first first\n")
        try await settle()
        let (second, window) = try document("second second\n")
        try await settle()
        let editor = try XCTUnwrap(second.model.activeEditor)
        window.makeFirstResponder(editor)
        let code = try item(#selector(RnotebookDelegate.showCode(_:)), in: main)
        try click(code); try await settle()
        XCTAssertTrue(second.model.sourceOnly); XCTAssertTrue(delegate.validateMenuItem(code)); XCTAssertEqual(code.state, .on)
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        let bold = try XCTUnwrap(entries(main).first { ($0.representedObject as? RecordVisualCommand) == .bold })
        XCTAssertTrue(delegate.validateMenuItem(bold)); try click(bold); try await settle()
        XCTAssertEqual(second.model.source, "**second** second\n"); XCTAssertEqual(first.model.source, "first first\n")
        XCTAssertTrue(NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)); try await settle()
        XCTAssertEqual(second.model.source, "second second\n")
        editor.setSelectedRange(.init(location: 0, length: 6))
        let selectionFind = try XCTUnwrap(entries(main).first { $0.action == #selector(RnotebookDelegate.findInDocument(_:)) && $0.tag == NSTextFinder.Action.setSearchString.rawValue })
        try click(selectionFind); try await settle()
        let next = try XCTUnwrap(entries(main).first { $0.action == #selector(RnotebookDelegate.findInDocument(_:)) && $0.tag == NSTextFinder.Action.nextMatch.rawValue })
        try click(next); try await settle()
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 6))
        let showFind = try XCTUnwrap(entries(main).first { $0.tag == NSTextFinder.Action.showFindInterface.rawValue && $0.action == next.action })
        try click(showFind); try await settle()
        XCTAssertTrue((editor.enclosingScrollView?.superview as? RecordNativeEditorHost)?.documentFinder.isPresented == true)
        XCTAssertFalse(editor.enclosingScrollView?.isFindBarVisible == true)
        let visual = try item(#selector(RnotebookDelegate.showVisual(_:)), in: main)
        try click(visual); try await settle()
        XCTAssertFalse(second.model.sourceOnly); XCTAssertTrue(delegate.validateMenuItem(visual)); XCTAssertEqual(visual.state, .on)
        XCTAssertEqual(second.model.source, "second second\n")
    }

    func testRestartRunAllMenuCancelsAndRebuildsSourceAfterConfirmation() async throws {
        L10n.configure(language: .simplifiedChinese)
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let (doc, window) = try document("```{r setup}\nvalue <- 1L\n```\n")
        doc.model.runAllNotebookCells(); await doc.model.notebook.waitUntilIdle()
        let old = doc.model.notebook.sessionID
        _ = try await doc.model.notebook.runtime.evaluate(.init(cellID: "before", source: "old_only <- TRUE"))
        let restart = try item(#selector(RnotebookDelegate.restartAndRunAll(_:)), in: main)
        XCTAssertTrue(delegate.validateMenuItem(restart))
        try click(restart); try await settle()
        try sheetButton("取消", in: window).performClick(nil); try await settle()
        XCTAssertEqual(doc.model.notebook.sessionID, old)
        let retained = try await doc.model.notebook.runtime.evaluate(.init(cellID: "after-cancel", source: "stopifnot(value == 1L, old_only)"))
        XCTAssertEqual(retained.events.last?.payload.status, "completed")
        try click(restart); try await settle()
        let next = "```{r setup}\nvalue <- 42L\nstopifnot(!exists('old_only'))\n```\n"
        doc.model.source = next; doc.model.activeEditor?.string = next
        try sheetButton("重启并运行", in: window).performClick(nil); try await settle()
        await doc.model.notebook.waitUntilIdle()
        XCTAssertNotEqual(doc.model.notebook.sessionID, old)
        XCTAssertFalse(doc.model.outputStates["setup"]?.failed ?? true)
        let check = try await doc.model.notebook.runtime.evaluate(.init(cellID: "after-confirm", source: "stopifnot(value == 42L, !exists('old_only'))"))
        XCTAssertEqual(check.events.last?.payload.status, "completed")
    }

    func testAllSkippedUntitledToolbarDoesNotOpenSavePanelOrStartR() async throws {
        let (doc, window) = try document("```{r}\n#| eval: false\nstop('must not run')\n```\n", saved: false)
        try await settle()
        let run = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "run" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(run.action), to: run.target, from: run))
        try await settle()
        XCTAssertNil(window.attachedSheet); XCTAssertNil(doc.fileURL)
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
        XCTAssertEqual(doc.model.notebook.skippedCount, 1)
    }

    func testStartStopMenuSharesNativeConfirmationAndClearingIsNotImmediate() async throws {
        L10n.configure(language: .simplifiedChinese)
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let (doc, window) = try document("```{r}\nstop('menu start must not run code')\n```\n")
        try await settle()
        let start = try item(#selector(RnotebookDelegate.startR(_:)), in: main)
        let stop = try item(#selector(RnotebookDelegate.stopR(_:)), in: main)
        let interrupt = try item(#selector(RnotebookDelegate.interruptR(_:)), in: main)
        XCTAssertTrue(delegate.validateMenuItem(start)); XCTAssertFalse(delegate.validateMenuItem(stop))
        try click(start); await doc.model.notebook.waitUntilIdle()
        XCTAssertEqual(doc.model.notebook.state, .ready); XCTAssertTrue(doc.model.outputStates.isEmpty)
        XCTAssertFalse(delegate.validateMenuItem(start)); XCTAssertTrue(delegate.validateMenuItem(stop)); XCTAssertFalse(delegate.validateMenuItem(interrupt))
        let runtime = doc.model.notebook.runtime
        _ = try await runtime.evaluate(.init(cellID: "menu", source: "menu_value <- 42L"))
        let clear = try item(#selector(RnotebookDelegate.clearVariables(_:)), in: main)
        XCTAssertTrue(delegate.validateMenuItem(clear)); try click(clear); try await settle()
        XCTAssertTrue(doc.model.showingClearVariables)
        XCTAssertEqual(doc.model.inspectorActionSession, doc.model.notebook.sessionID)
        try sheetButton("取消", in: window).performClick(nil); try await settle()
        let retained = try await runtime.evaluate(.init(cellID: "check", source: "stopifnot(menu_value==42L)"))
        XCTAssertEqual(retained.events.last?.payload.status, "completed")
        try click(stop); try await settle()
        XCTAssertEqual(doc.model.notebook.state, .ready)
        try sheetButton("取消", in: window).performClick(nil); try await settle()
        XCTAssertEqual(doc.model.notebook.state, .ready)
        try click(stop); try await settle(); try sheetButton("停止", in: window).performClick(nil)
        try await settle(); await doc.model.notebook.waitUntilIdle()
        XCTAssertEqual(doc.model.notebook.state, .notStarted)
    }

    func testUnnamedRenderAndInstallMenusRequireSaveAndCancelDoesNotContinue() async throws {
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let (doc, window) = try document("Unstored source\n", saved: false)
        try await settle()
        for selector in [#selector(RnotebookDelegate.render(_:)), #selector(RnotebookDelegate.installPackages(_:))] {
            window.makeKeyAndOrderFront(nil)
            let command = try item(selector, in: main)
            XCTAssertTrue(delegate.validateMenuItem(command)); try click(command); try await settle()
            let save = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
            XCTAssertFalse(doc.model.showingExport); XCTAssertFalse(doc.model.showingPackageInstall)
            save.cancel(nil); try await settle()
            XCTAssertNil(doc.fileURL); XCTAssertEqual(doc.model.source, "Unstored source\n")
            XCTAssertFalse(doc.model.showingExport); XCTAssertFalse(doc.model.showingPackageInstall)
            XCTAssertEqual(doc.model.notebook.state, .notStarted)
        }
    }

    func testSettingsLanguageChangeRebuildsInstalledMenusWithoutRestart() async throws {
        let previousLanguage = L10n.resources.language
        defer { L10n.configure(language: previousLanguage) }
        let delegate = RnotebookDelegate(); install(menu(delegate))
        let suite = "MenuLanguage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = LanguageSettings(defaults: defaults, systemLanguages: { ["zh-Hans"] })
        for (identifier, title) in [("en", "File"), ("zh-Hans", "文件")] {
            XCTAssertTrue(language.select(identifier)); try await settle()
            let main = try XCTUnwrap(NSApp.mainMenu)
            XCTAssertEqual(main.items[0].title, "Rnotebook")
            XCTAssertEqual(main.items[1].title, title)
            let bold = try XCTUnwrap(entries(main).first { ($0.representedObject as? RecordVisualCommand) == .bold })
            XCTAssertEqual(bold.title, identifier == "en" ? "Bold" : "加粗")
        }
    }

    func testTableAndImageMenusReuseInsertionSheetsAndKeepSourceOnCancel() async throws {
        L10n.configure(language: .simplifiedChinese)
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let (doc, window) = try document("source\n")
        try await settle()
        doc.model.sourceOnly = true; try await settle()
        for action in [#selector(RnotebookDelegate.insertTable(_:)), #selector(RnotebookDelegate.insertLinkedImage(_:))] {
            window.makeKeyAndOrderFront(nil)
            let command = try item(action, in: main)
            XCTAssertTrue(delegate.validateMenuItem(command)); try click(command); try await settle()
            XCTAssertNotNil(doc.model.menuInsertion); XCTAssertNotNil(window.attachedSheet)
            XCTAssertEqual(doc.model.source, "source\n")
            let sheet = try XCTUnwrap(window.attachedSheet)
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            sheet.sendEvent(escape); try await settle()
            XCTAssertNil(doc.model.menuInsertion); XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(doc.model.source, "source\n")
        }
    }

    func testLateToolbarLayoutAfterDocumentDeallocationIsSafe() async throws {
        var document: QMDDocument? = QMDDocument()
        weak var released = document
        document?.makeWindowControllers()
        let window = try XCTUnwrap(document?.windowControllers.first?.window)
        let split = try XCTUnwrap(window.contentViewController as? NotebookSplitController)
        window.makeKeyAndOrderFront(nil); try await settle()
        document?.updateChangeCount(.changeCleared); document?.close(); document = nil
        try await settle(); XCTAssertNil(released)
        // Closing windows can retain their controllers until the final AppKit
        // display cycle. Reproduce the formerly crashing callback directly.
        split.viewDidLayout(); split.refreshToolbar()
    }

    func testSystemInsertedItemsSwitchLanguagesWithoutReplacingActions() throws {
        defer { L10n.configure(language: .simplifiedChinese) }
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let window = try XCTUnwrap(NSApp.windowsMenu)
        let move = NSMenuItem(title: "Move & Resize", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu(); move.submenu = moveMenu; window.addItem(move)
        let fill = moveMenu.addItem(withTitle: "Fill", action: Selector(("_zoomFill:")), keyEquivalent: "")
        let header = NSMenuItem(title: "Halves", action: nil, keyEquivalent: ""); header.isEnabled = false; moveMenu.addItem(header)
        let edit = try XCTUnwrap(main.items.first { $0.submenu?.items.contains { $0.action == #selector(NSText.cut(_:)) } == true }?.submenu)
        let dictation = edit.addItem(withTitle: "Start Dictation", action: Selector(("startDictation:")), keyEquivalent: "")
        let undo = try item(Selector(("undo:")), in: edit)
        let file = try XCTUnwrap(main.items.first { $0.submenu?.items.contains { $0.action == #selector(NSDocument.save(_:)) } == true }?.submenu)
        let save = try item(#selector(NSDocument.save(_:)), in: file)
        let closeAll = file.addItem(withTitle: "全部关闭", action: Selector(("closeAll:")), keyEquivalent: "")
        let help = try XCTUnwrap(main.items.first { $0.submenu?.identifier?.rawValue == "notebook-help-menu" }?.submenu)
        XCTAssertTrue(NSApp.helpMenu === help)
        XCTAssertNotNil(try item(#selector(RnotebookDelegate.focusHelpSearch(_:)), in: help))
        let action = fill.action
        for language in [AppLanguage.simplifiedChinese, .english, .simplifiedChinese] {
            L10n.configure(language: language)
            for menu in [window, edit, help, file] { delegate.menuWillOpen(menu) }
            XCTAssertEqual(move.title, language == .english ? "Move & Resize" : "移动与调整大小")
            XCTAssertEqual(fill.title, language == .english ? "Fill" : "填充")
            XCTAssertEqual(header.title, language == .english ? "Halves" : "二等分")
            XCTAssertEqual(dictation.title, language == .english ? "Start Dictation" : "开始听写")
            XCTAssertEqual(undo.title, language == .english ? "Undo" : "撤销")
            XCTAssertEqual(save.title, language == .english ? "Save" : "保存")
            XCTAssertEqual(closeAll.title, language == .english ? "Close All" : "全部关闭")
            XCTAssertEqual(fill.action, action)
        }
    }

    func testWindowMenuKeepsIndependentWindowsAndDocumentActionsDisableWithoutDocument() throws {
        let delegate = RnotebookDelegate(), main = menu(delegate); install(main)
        let windowMenu = try XCTUnwrap(NSApp.windowsMenu)
        windowMenu.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        delegate.menuWillOpen(windowMenu)
        XCTAssertFalse(entries(windowMenu).contains { $0.action == #selector(NSWindow.toggleTabBar(_:)) })
        XCTAssertTrue(entries(windowMenu).contains { $0.action == #selector(NSWindow.performZoom(_:)) })
        XCTAssertTrue(entries(windowMenu).contains { $0.action == #selector(NSApplication.arrangeInFront(_:)) })
        XCTAssertNil(NotebookCommandContext.shared.target)
        XCTAssertFalse(delegate.validateMenuItem(try item(#selector(RnotebookDelegate.runAll(_:)), in: main)))
        XCTAssertFalse(delegate.validateMenuItem(try item(#selector(RnotebookDelegate.showCode(_:)), in: main)))
        XCTAssertTrue(delegate.validateMenuItem(try item(#selector(RnotebookDelegate.openDocumentation(_:)), in: main)))
        XCTAssertTrue(delegate.validateMenuItem(try item(#selector(RnotebookDelegate.showSettings(_:)), in: main)))
    }
}
