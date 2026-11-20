import AppKit

extension RnotebookApp {
    static func makeMenu(commandTarget: RnotebookDelegate? = nil) -> NSMenu {
        let target = commandTarget ?? delegate
        let main = NSMenu()
        func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
            let child = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = child; parent.addItem(item)
            return child
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 _ flags: NSEvent.ModifierFlags = .command, to receiver: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags; item.target = receiver
            return item
        }
        func command(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                     _ flags: NSEvent.ModifierFlags = .command) {
            add(menu, title, action, key, flags, to: target)
        }
        func format(_ menu: NSMenu, _ title: String, _ value: RecordVisualCommand, _ key: String = "",
                    _ flags: NSEvent.ModifierFlags = .command) {
            let item = add(menu, title, #selector(RnotebookDelegate.formatDocument(_:)), key, flags, to: target)
            item.representedObject = value
        }
        func tools(_ menu: NSMenu, _ ids: [String]) {
            let available = RecordVisualTool.common + RecordVisualTool.extended
            for id in ids {
                if let tool = available.first(where: { $0.id == id }) {
                    format(menu, tool.title, tool.command)
                }
            }
        }

        let app = submenu(main, "Rnotebook")
        command(app, L10n.string("关于 Rnotebook"), #selector(RnotebookDelegate.showAbout(_:)))
        app.addItem(.separator())
        command(app, L10n.string("设置…"), #selector(RnotebookDelegate.showSettings(_:)), ",")
        app.addItem(.separator())
        NSApp.servicesMenu = submenu(app, L10n.string("服务"))
        app.addItem(.separator())
        add(app, L10n.string("隐藏 Rnotebook"), #selector(NSApplication.hide(_:)), "h")
        add(app, L10n.string("隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, L10n.string("全部显示"), #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, L10n.string("退出 Rnotebook"), #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(main, L10n.string("文件")); file.delegate = target
        add(file, L10n.string("新建"), #selector(NSDocumentController.newDocument(_:)), "n", to: NSDocumentController.shared)
        command(file, L10n.string("打开…"), #selector(RnotebookDelegate.openExistingDocument(_:)), "o")
        let recent = submenu(file, L10n.string("最近文档"))
        recent.identifier = .init("recent-documents"); recent.delegate = target
        command(file, L10n.string("恢复未保存文档…"), #selector(RnotebookDelegate.recoverDocuments(_:)))
        file.addItem(.separator())
        add(file, L10n.string("关闭"), #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        add(file, L10n.string("保存"), #selector(NSDocument.save(_:)), "s")
        add(file, L10n.string("另存为…"), #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, L10n.string("恢复到已保存版本…"), #selector(NSDocument.revertToSaved(_:)))
        let synchronization = submenu(file, L10n.string("文档同步"))
        command(synchronization, L10n.string("检查外部修改"), #selector(RnotebookDelegate.checkExternalChanges(_:)))
        command(synchronization, L10n.string("比对版本…"), #selector(RnotebookDelegate.compareVersions(_:)))
        synchronization.addItem(.separator())
        command(synchronization, L10n.string("文档设置…"), #selector(RnotebookDelegate.showDocumentSettings(_:)))
        command(file, L10n.string("在访达中显示文档"), #selector(RnotebookDelegate.revealDocument(_:)))
        file.addItem(.separator())
        command(file, L10n.string("Quarto 渲染导出…"), #selector(RnotebookDelegate.render(_:)), "e", [.command, .shift])

        let edit = submenu(main, L10n.string("编辑")); edit.delegate = target
        add(edit, L10n.string("撤销"), Selector(("undo:")), "z")
        add(edit, L10n.string("重做"), Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, L10n.string("剪切"), #selector(NSText.cut(_:)), "x")
        add(edit, L10n.string("复制"), #selector(NSText.copy(_:)), "c")
        add(edit, L10n.string("粘贴"), #selector(NSText.paste(_:)), "v")
        add(edit, L10n.string("删除"), #selector(NSText.delete(_:)))
        edit.addItem(.separator())
        add(edit, L10n.string("全选"), #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = submenu(edit, L10n.string("查找"))
        for (title, action, key, flags) in [
            (L10n.string("查找…"), NSTextFinder.Action.showFindInterface, "f", NSEvent.ModifierFlags.command),
            (L10n.string("查找并替换…"), .showReplaceInterface, "f", [.command, .option]),
            (L10n.string("查找下一个"), .nextMatch, "g", .command),
            (L10n.string("查找上一个"), .previousMatch, "g", [.command, .shift])
        ] {
            let item = add(find, title, #selector(RnotebookDelegate.findInDocument(_:)), key, flags, to: target)
            item.tag = action.rawValue
        }
        find.addItem(.separator())
        let useSelection = add(find, L10n.string("使用选中内容查找"), #selector(RnotebookDelegate.findInDocument(_:)), "e", to: target)
        useSelection.tag = NSTextFinder.Action.setSearchString.rawValue

        edit.addItem(.separator())
        command(edit, L10n.string("补全 R 代码"), #selector(RnotebookDelegate.completeRCode(_:)), " ", .control)
        command(edit, L10n.string("格式化 R 代码块"), #selector(RnotebookDelegate.formatRBlock(_:)), "i", [.command, .shift])

        let style = submenu(main, L10n.string("格式"))
        let heading = submenu(style, L10n.string("标题级别"))
        format(heading, L10n.string("正文"), .heading(0), "0", [.command, .option])
        heading.addItem(.separator())
        for level in 1...6 { format(heading, L10n.string("标题 \(String(level))"), .heading(level), String(level), [.command, .option]) }
        heading.addItem(.separator())
        format(heading, L10n.string("提升标题级别"), .headingIncrease)
        format(heading, L10n.string("降低标题级别"), .headingDecrease)
        style.addItem(.separator())
        format(style, L10n.string("加粗"), .bold, "b")
        format(style, L10n.string("斜体"), .italic, "i")
        format(style, L10n.string("下划线"), .underline, "u")
        tools(style, ["strike", "highlight", "inline-code", "superscript", "subscript", "keyboard"])
        style.addItem(.separator())
        let lists = submenu(style, L10n.string("列表"))
        tools(lists, ["bullet", "numbered"])
        lists.addItem(.separator()); tools(lists, ["task"])
        tools(style, ["quote"])

        let insert = submenu(main, L10n.string("插入"))
        format(insert, L10n.string("链接"), .link, "k")
        tools(insert, ["wikilink", "footnote"])
        insert.addItem(.separator())
        tools(insert, ["image"])
        command(insert, L10n.string("链接插入图片…"), #selector(RnotebookDelegate.insertLinkedImage(_:)))
        command(insert, L10n.string("插入表格…"), #selector(RnotebookDelegate.insertTable(_:)))
        insert.addItem(.separator())
        let code = submenu(insert, L10n.string("代码块"))
        tools(code, ["r-code"]); code.addItem(.separator()); tools(code, ["text-code", "code"])
        let math = submenu(insert, L10n.string("公式"))
        tools(math, ["inline-math"]); math.addItem(.separator()); tools(math, ["math"])
        let mermaid = submenu(insert, L10n.string("Mermaid图形"))
        for diagram in RecordMermaidDiagram.all { format(mermaid, diagram.title, .mermaid(diagram.id)) }
        insert.addItem(.separator())
        let callout = submenu(insert, L10n.string("提示块"))
        for (index, entry) in RecordVisualTool.callouts.enumerated() {
            if index == 5 { callout.addItem(.separator()) }
            format(callout, entry.1, .callout(entry.0))
        }
        tools(insert, ["comment", "rule"])

        let view = submenu(main, L10n.string("视图"))
        command(view, L10n.string("源代码视图"), #selector(RnotebookDelegate.showCode(_:)), "1", [.command, .control])
        command(view, L10n.string("可视化视图"), #selector(RnotebookDelegate.showVisual(_:)), "2", [.command, .control])
        view.addItem(.separator())
        command(view, L10n.string("折叠当前区域"), #selector(RnotebookDelegate.toggleFold(_:)))
        command(view, L10n.string("折叠所有代码块"), #selector(RnotebookDelegate.foldCodeBlocks(_:)))
        command(view, L10n.string("折叠所有章节"), #selector(RnotebookDelegate.foldSections(_:)))
        command(view, L10n.string("展开全部"), #selector(RnotebookDelegate.unfoldAll(_:)))
        view.addItem(.separator())
        command(view, L10n.string("放大文字"), #selector(RnotebookDelegate.increaseTextSize(_:)), "+")
        command(view, L10n.string("缩小文字"), #selector(RnotebookDelegate.decreaseTextSize(_:)), "-")
        command(view, L10n.string("恢复默认字号"), #selector(RnotebookDelegate.resetTextSize(_:)), "0")
        view.addItem(.separator())
        add(view, L10n.string("进入全屏幕"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        view.delegate = target

        let notebook = submenu(main, L10n.string("笔记本"))
        command(notebook, L10n.string("运行当前代码块"), #selector(RnotebookDelegate.runCurrent(_:)), "\r")
        command(notebook, L10n.string("运行选中代码"), #selector(RnotebookDelegate.runSelection(_:)), "\r", [.command, .option])
        notebook.addItem(.separator())
        command(notebook, L10n.string("运行以上代码块"), #selector(RnotebookDelegate.runAbove(_:)))
        command(notebook, L10n.string("运行以下代码块"), #selector(RnotebookDelegate.runBelow(_:)))
        command(notebook, L10n.string("运行全部代码块"), #selector(RnotebookDelegate.runAll(_:)), "\r", [.command, .shift])
        command(notebook, L10n.string("重启 R 并运行全部…"), #selector(RnotebookDelegate.restartAndRunAll(_:)))
        notebook.addItem(.separator())
        command(notebook, L10n.string("停止运行"), #selector(RnotebookDelegate.interruptR(_:)), ".")

        let r = submenu(main, L10n.string("R 会话"))
        command(r, L10n.string("启动 R"), #selector(RnotebookDelegate.startR(_:)))
        command(r, L10n.string("停止 R…"), #selector(RnotebookDelegate.stopR(_:)))
        command(r, L10n.string("重启 R…"), #selector(RnotebookDelegate.restartR(_:)))
        r.addItem(.separator())
        command(r, L10n.string("刷新变量与已安装包"), #selector(RnotebookDelegate.refreshInspector(_:)))
        command(r, L10n.string("清空变量…"), #selector(RnotebookDelegate.clearVariables(_:)))
        command(r, L10n.string("安装 R 包…"), #selector(RnotebookDelegate.installPackages(_:)))
        r.addItem(.separator())
        command(r, L10n.string("保存 R 工作区…"), #selector(RnotebookDelegate.saveR(_:)))

        let window = submenu(main, L10n.string("窗口"))
        add(window, L10n.string("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, L10n.string("缩放"), #selector(NSWindow.performZoom(_:)))
        command(window, L10n.string("恢复默认布局"), #selector(RnotebookDelegate.resetWindowLayout(_:)))
        window.addItem(.separator())
        add(window, L10n.string("前置全部窗口"), #selector(NSApplication.arrangeInFront(_:)))
        window.delegate = target; NSApp.windowsMenu = window

        // AppKit owns the standard Help search; Apple Help opens in the system viewer.
        let help = submenu(main, L10n.string("帮助")); help.delegate = target
        help.identifier = .init("notebook-help-menu")
        NSApp.helpMenu = help
        command(help, L10n.string("Rnotebook 帮助"), #selector(RnotebookDelegate.showHelpCenter(_:)), "/", [.command, .shift])
        command(help, NotebookHelpTopic.quickStart.title, #selector(RnotebookDelegate.showQuickStart(_:)))
        command(help, NotebookHelpTopic.syntax.title, #selector(RnotebookDelegate.showSyntaxReference(_:)))
        help.addItem(.separator())
        command(help, L10n.string("搜索 R 帮助…"), #selector(RnotebookDelegate.focusHelpSearch(_:)))
        help.addItem(.separator())
        for link in NotebookHelpExternal.allCases {
            let item = add(help, link.title, #selector(RnotebookDelegate.openDocumentation(_:)), to: target)
            item.representedObject = link.url
        }
        return main
    }
}

extension RnotebookDelegate {
    @objc func showHelpCenter(_ sender: Any?) { helpCenter.showHome() }
    @objc func showQuickStart(_ sender: Any?) { helpCenter.showArticle(.quickStart) }
    @objc func showSyntaxReference(_ sender: Any?) { helpCenter.showArticle(.syntax) }
    @objc func checkExternalChanges(_ sender: Any?) { NotebookCommandContext.shared.target?.document?.synchronization.checkExternalChanges() }
    @objc func compareVersions(_ sender: Any?) { NotebookCommandContext.shared.target?.document?.synchronization.requestComparison() }
    @objc func revealDocument(_ sender: Any?) {
        guard let url = NotebookCommandContext.shared.target?.document?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc func resetWindowLayout(_ sender: Any?) { NotebookCommandContext.shared.target?.document?.windowPlacement?.reset() }
    @objc func increaseTextSize(_ sender: Any?) { changeTextSize(1) }
    @objc func decreaseTextSize(_ sender: Any?) { changeTextSize(-1) }
    @objc func resetTextSize(_ sender: Any?) { changeTextSize(nil) }
    private func changeTextSize(_ delta: Double?) {
        guard let model = NotebookCommandContext.shared.target, let document = model.document else { return }
        if model.sourceOnly { document.sourceSettings.fontSize = delta.map { min(32, max(10, document.sourceSettings.fontSize + $0)) } ?? 12 }
        else {
            document.visual.bodySize = delta.map { min(28, max(10, document.visual.bodySize + $0)) } ?? 12
            document.visual.codeSize = delta.map { min(24, max(10, document.visual.codeSize + $0)) } ?? 12
        }
    }
    @objc func formatDocument(_ item: NSMenuItem) {
        guard let command = item.representedObject as? RecordVisualCommand else { return }
        NotebookCommandContext.shared.target?.format(command)
    }
    private var folding: RecordCodeFolding? {
        (NotebookCommandContext.shared.target?.activeEditor?.enclosingScrollView?.superview as? RecordNativeEditorHost)?.folding
    }
    @objc func toggleFold(_ sender: Any?) {
        guard let model = NotebookCommandContext.shared.target, let folding else { return }
        let offset = model.activeEditor?.selectedRange().location ?? 0
        let region = folding.structure.regions.last { $0.header.location <= offset && $0.hidden.upperBound > offset }
        if let region { folding.toggle(region.key) }
    }
    @objc func foldCodeBlocks(_ sender: Any?) { folding?.setAll(collapsed: true, kind: .fence) }
    @objc func foldSections(_ sender: Any?) { folding?.setAll(collapsed: true, kind: .heading) }
    @objc func unfoldAll(_ sender: Any?) { folding?.setAll(collapsed: false) }
    @objc func showCode(_ sender: Any?) { NotebookCommandContext.shared.target?.sourceOnly = true }
    @objc func showVisual(_ sender: Any?) { NotebookCommandContext.shared.target?.sourceOnly = false }
    @objc func findInDocument(_ item: NSMenuItem) {
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        if helpCenter.browserWindow?.window === NSApp.keyWindow {
            if action == .showFindInterface { helpCenter.browserWindow?.focusSearch() }
            return
        }
        NotebookCommandContext.shared.target?.findInDocument(action: action)
    }
    @objc func refreshInspector(_ sender: Any?) { NotebookCommandContext.shared.target?.notebook.manage(.init(operation: .snapshot)) }
    @objc func clearVariables(_ sender: Any?) { NotebookCommandContext.shared.target?.requestClearVariables() }
    @objc func installPackages(_ sender: Any?) { NotebookCommandContext.shared.target?.presentPackageInstall() }
    @objc func revealDirectory(_ sender: Any?) { NotebookCommandContext.shared.target?.notebook.revealWorkingDirectory() }
    @objc func insertTable(_ sender: Any?) {
        guard let model = NotebookCommandContext.shared.target, let anchor = model.captureVisualInsertion(for: .table) else { return }
        model.menuInsertion = .table(anchor)
    }
    @objc func insertLinkedImage(_ sender: Any?) {
        guard let model = NotebookCommandContext.shared.target, let anchor = model.captureVisualInsertion(for: .imageReference) else { return }
        model.menuInsertion = .image(anchor)
    }
    @objc func focusHelpSearch(_ sender: Any?) { NotebookCommandContext.shared.target?.helpSearchRequest = UUID() }
    @objc func openDocumentation(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        let global: Set<Selector> = [#selector(showAbout(_:)), #selector(showSettings(_:)), #selector(openExistingDocument(_:)),
            #selector(recoverDocuments(_:)), #selector(openRecent(_:)), #selector(openDocumentation(_:)), #selector(showDocumentSettings(_:)),
            #selector(showHelpCenter(_:)), #selector(showQuickStart(_:)), #selector(showSyntaxReference(_:))]
        if global.contains(action) { return true }
        if action == #selector(findInDocument(_:)), helpCenter.browserWindow?.window === NSApp.keyWindow {
            return item.tag == NSTextFinder.Action.showFindInterface.rawValue
        }
        guard let model = NotebookCommandContext.shared.target else { item.state = .off; return false }
        let session = model.notebook
        let canRun = !session.isBusy && !session.needsRestart && !session.hasPendingRSelection
        switch action {
        case #selector(checkExternalChanges(_:)): return model.document?.fileURL != nil && session.window?.attachedSheet == nil
        case #selector(compareVersions(_:)): return model.document?.synchronization.conflict != nil && session.window?.attachedSheet == nil
        case #selector(revealDocument(_:)): return model.document?.fileURL != nil
        case #selector(resetWindowLayout(_:)): return model.document?.windowPlacement != nil && session.window?.styleMask.contains(.fullScreen) != true
        case #selector(increaseTextSize(_:)), #selector(decreaseTextSize(_:)), #selector(resetTextSize(_:)):
            return model.activeEditor != nil && session.window?.attachedSheet == nil
        case #selector(completeRCode(_:)): return model.activeEditor?.isEditable == true
        case #selector(formatRBlock(_:)): return model.activeEditor?.isEditable == true
        case #selector(toggleFold(_:)), #selector(foldCodeBlocks(_:)), #selector(foldSections(_:)), #selector(unfoldAll(_:)):
            return model.sourceOnly && model.activeEditor?.hasMarkedText() == false
        case #selector(showCode(_:)): item.state = model.sourceOnly ? .on : .off; return true
        case #selector(showVisual(_:)): item.state = model.sourceOnly ? .off : .on; return true
        case #selector(formatDocument(_:)):
            guard let command = item.representedObject as? RecordVisualCommand else { return false }
            item.state = .off
            if case .heading(let level) = command {
                let context = model.activeEditor.map { RecordVisualEditing.context($0.string, selection: $0.selectedRange()) }
                item.state = context?.heading == level ? .on : .off
            } else if model.visualContext.activeActions.contains(command.selector) { item.state = .on }
            return model.canFormat(command)
        case #selector(insertTable(_:)), #selector(insertLinkedImage(_:)):
            return model.activeEditor?.isEditable == true && session.window?.attachedSheet == nil
        case #selector(findInDocument(_:)): return model.activeEditor != nil
        case #selector(startR(_:)): return session.canStart
        case #selector(stopR(_:)): return session.canStop && session.window?.attachedSheet == nil
        case #selector(interruptR(_:)): return session.isBusy && !session.isStopping
        case #selector(restartR(_:)): return !session.isBusy && session.state != .notStarted && session.window?.attachedSheet == nil
        case #selector(restartAndRunAll(_:)): return !session.isBusy && session.window?.attachedSheet == nil
        case #selector(saveR(_:)): return session.canSaveWorkspace
        case #selector(render(_:)): return !model.exporter.isRunning && session.window?.attachedSheet == nil
        case #selector(refreshInspector(_:)): return canRun
        case #selector(clearVariables(_:)): return canRun && session.state == .ready && session.window?.attachedSheet == nil
        case #selector(installPackages(_:)): return canRun && session.window?.attachedSheet == nil
        case #selector(revealDirectory(_:)): return session.workingDirectoryURL != nil
        case #selector(focusHelpSearch(_:)): return true
        default: return canRun
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // AppKit owns the native window list. Keep system command titles in the
        // selected app language, and never offer native document tabbing.
        if menu === NSApp.windowsMenu {
            let tabs: Set<Selector> = [#selector(NSWindow.toggleTabBar(_:)), #selector(NSWindow.toggleTabOverview(_:)),
                #selector(NSWindow.mergeAllWindows(_:)), #selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.selectPreviousTab(_:)),
                #selector(NSWindow.moveTabToNewWindow(_:))]
            for item in menu.items where item.action.map(tabs.contains) == true { menu.removeItem(item) }
        }
        localizeSystemItems(in: menu)
    }

    /// AppKit builds these commands in its launch language. Relabel the actual
    /// items when they open, retaining their native actions and validation.
    private func localizeSystemItems(in menu: NSMenu) {
        let commands: [String: String.LocalizationValue] = [
            "undo:": "撤销", "redo:": "重做", "undoSource:": "撤销", "redoSource:": "重做",
            "newDocument:": "新建", "performClose:": "关闭", "closeAll:": "全部关闭", "saveAllDocuments:": "全部保存",
            NSStringFromSelector(#selector(NSDocument.save(_:))): "保存",
            NSStringFromSelector(#selector(NSDocument.saveAs(_:))): "另存为…",
            NSStringFromSelector(#selector(NSDocument.revertToSaved(_:))): "恢复到已保存版本…",
            "performMiniaturize:": "最小化", "miniaturizeAll:": "全部最小化",
            "performZoom:": "缩放", "zoomAll:": "全部缩放", "_zoomFill:": "填充", "_zoomCenter:": "居中",
            "_zoomLeft:": "左半部分", "_zoomRight:": "右半部分", "_zoomTop:": "上半部分", "_zoomBottom:": "下半部分",
            "_zoomTopLeft:": "左上角", "_zoomTopRight:": "右上角", "_zoomBottomLeft:": "左下角", "_zoomBottomRight:": "右下角",
            "_zoomLeftAndRight:": "左侧与右侧", "_zoomLeftThreeUp:": "左侧与四分之一",
            "_zoomRightAndLeft:": "右侧与左侧", "_zoomRightThreeUp:": "右侧与四分之一",
            "_zoomTopAndBottom:": "顶部与底部", "_zoomTopThreeUp:": "顶部与四分之一",
            "_zoomBottomAndTop:": "底部与顶部", "_zoomBottomThreeUp:": "底部与四分之一",
            "_zoomQuarters:": "四等分", "_zoomUntile:": "恢复先前大小",
            "_tileLeft:": "屏幕左侧", "_tileRight:": "屏幕右侧",
            "arrangeInFront:": "前置全部窗口", "alternateArrangeInFront:": "排列到前面",
            "_removeWindowFromStageManagerSet:": "从组合中移除窗口",
            "_handleInsertFromContactsCommand:": "联系人…", "_handleInsertFromPasswordsCommand:": "密码…",
            "_handleInsertFromCreditCardsCommand:": "信用卡…", "startDictation:": "开始听写",
            "stopDictation:": "停止听写", "orderFrontCharacterPalette:": "表情与符号"
        ]
        let headings: [(names: Set<String>, key: String.LocalizationValue)] = [
            (["Move & Resize", "移动与调整大小"], "移动与调整大小"),
            (["Full Screen Tile", "全屏幕拼贴"], "全屏幕拼贴"),
            (["Halves", "二等分"], "二等分"), (["Quarters", "四等分"], "四等分"),
            (["Arrange", "排列"], "排列"), (["AutoFill", "自动填充"], "自动填充")
        ]
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem {
            if item.action == #selector(NSWindow.toggleFullScreen(_:)) {
                item.title = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true ? L10n.string("退出全屏幕") : L10n.string("进入全屏幕")
            } else if let action = item.action, let key = commands[NSStringFromSelector(action)] {
                item.title = L10n.string(key)
            } else if item.identifier?.rawValue == "_NSMenuItemAutoFillIdentifier" {
                item.title = L10n.string("自动填充")
            } else if let child = item.submenu {
                let actions = Set(child.items.compactMap { $0.action.map(NSStringFromSelector) })
                if actions.contains("_zoomLeft:") { item.title = L10n.string("移动与调整大小") }
                else if actions.contains("_tileLeft:") { item.title = L10n.string("全屏幕拼贴") }
                else if let heading = headings.first(where: { $0.names.contains(item.title) }) { item.title = L10n.string(heading.key) }
            } else if !item.isEnabled && item.action == nil {
                let next = menu.items.dropFirst(index + 1).first { !$0.isSeparatorItem }?.action.map(NSStringFromSelector)
                switch next {
                case "_zoomLeft:": item.title = L10n.string("二等分")
                case "_zoomTopLeft:": item.title = L10n.string("四等分")
                case "_zoomLeftAndRight:": item.title = L10n.string("排列")
                default:
                    if let heading = headings.first(where: { $0.names.contains(item.title) }) { item.title = L10n.string(heading.key) }
                }
            }
            if let child = item.submenu { localizeSystemItems(in: child) }
        }
    }

}

extension RecordLayoutModel {
    func findInDocument(action: NSTextFinder.Action = .showFindInterface) {
        guard let editor = activeEditor else { return }
        if let host = editor.enclosingScrollView?.superview as? RecordNativeEditorHost {
            host.documentFinder.perform(action)
        }
    }
}

extension RecordLayoutModel {
    func presentPackageInstall() {
        let present = { [weak self] in self?.showingPackageInstall = true }
        if let document { document.ensureSaved { present() } }
        else { present() }
    }
    func requestClearVariables() {
        guard !notebook.isBusy, notebook.state == .ready, !notebook.needsRestart, !notebook.hasPendingRSelection else { return }
        inspectorActionSession = notebook.sessionID; showingClearVariables = true
    }
}
