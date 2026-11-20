import SwiftUI
import AppKit
import Combine

enum NotebookSettingsPane: String, CaseIterable {
    case general, documents, fonts, highlighting, completion, formatting, environment

    static let contentWidth: CGFloat = 640

    var title: String {
        switch self {
        case .general: return L10n.string("通用")
        case .documents: return L10n.string("文档")
        case .fonts: return L10n.string("字体")
        case .highlighting: return L10n.string("高亮")
        case .completion: return L10n.string("补全")
        case .formatting: return L10n.string("格式化")
        case .environment: return L10n.string("环境")
        }
    }

    var contentHeight: CGFloat {
        switch self {
        case .general: return 208
        case .documents: return 248
        case .fonts: return 424
        case .highlighting: return 276
        case .completion: return 244
        case .formatting: return 204
        case .environment: return 280
        }
    }

    /// Formatting hides its custom fields while following the document, so the
    /// page itself shrinks instead of leaving a large empty band below one row.
    func preferredHeight(formatMode: String) -> CGFloat {
        self == .formatting ? (formatMode == "custom" ? contentHeight : 96) : contentHeight
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .documents: return "doc.text"
        case .fonts: return "textformat"
        case .highlighting: return "paintpalette"
        case .completion: return "text.cursor"
        case .formatting: return "text.alignleft"
        case .environment: return "terminal"
        }
    }
}

/// AppKit owns the preference toolbar, selection, title and keyboard navigation.
@MainActor final class NotebookSettingsController: NSTabViewController {
    private var languageChanges: AnyCancellable?
    private var formatModeChanges: AnyCancellable?
    private let behavior: DocumentBehaviorSettings
    private let source: SourceEditorSettings
    private var placement: NotebookWindowPlacement?

    init(language: LanguageSettings = NotebookPreferences.language,
         source: SourceEditorSettings = NotebookPreferences.source,
         visual: VisualEditorSettings = NotebookPreferences.visual,
         appearance: AppearanceSettings = NotebookPreferences.appearance,
         behavior: DocumentBehaviorSettings = NotebookPreferences.documents) {
        self.behavior = behavior
        self.source = source
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        for pane in NotebookSettingsPane.allCases {
            let view = SettingsPaneView(pane: pane, settings: language)
                .environmentObject(behavior)
                .environmentObject(source)
                .environmentObject(visual)
                .appAppearance(appearance)
            let host = NSHostingController(rootView: view)
            host.title = pane.title
            host.preferredContentSize = NSSize(width: NotebookSettingsPane.contentWidth,
                                               height: pane.preferredHeight(formatMode: source.formatMode))
            let item = NSTabViewItem(viewController: host)
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
        preferredContentSize = NSSize(width: NotebookSettingsPane.contentWidth, height: NotebookSettingsPane.general.contentHeight)
        let raw = behavior.defaults.string(forKey: "settings.selectedPane")
        let restored: NotebookSettingsPane?
        if raw == "editor" {
            let legacyPage = behavior.defaults.string(forKey: "settings.editorPage")
            restored = [.highlighting, .completion, .formatting].first { $0.rawValue == legacyPage } ?? .fonts
        } else {
            restored = raw.flatMap(NotebookSettingsPane.init(rawValue:))
        }
        behavior.defaults.removeObject(forKey: "settings.editorPage")
        if let pane = restored, let index = NotebookSettingsPane.allCases.firstIndex(of: pane) {
            selectedTabViewItemIndex = index
            behavior.defaults.set(pane.rawValue, forKey: "settings.selectedPane")
        }
        languageChanges = language.$language.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refreshLanguage() }
        }
        formatModeChanges = source.$formatMode.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refreshFormattingHeight() }
        }
    }

    private func refreshFormattingHeight() {
        guard let index = NotebookSettingsPane.allCases.firstIndex(of: .formatting),
              let item = tabViewItems.indices.contains(index) ? tabViewItems[index] : nil,
              let host = item.viewController else { return }
        let height = NotebookSettingsPane.formatting.preferredHeight(formatMode: source.formatMode)
        host.preferredContentSize = NSSize(width: NotebookSettingsPane.contentWidth, height: height)
        guard selectedTabViewItemIndex == index else { return }
        resizeWindow(to: host.preferredContentSize)
    }

    private func resizeWindow(to size: NSSize) {
        preferredContentSize = size
        guard let window = viewIfLoaded?.window else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        if let frame = NotebookWindowState.visibleFrame(window.frame, screens: NSScreen.screens.map(\.visibleFrame), minimum: .zero) {
            window.setFrame(frame, display: true)
        }
    }

    private func refreshLanguage() {
        for (pane, item) in zip(NotebookSettingsPane.allCases, tabViewItems) {
            item.label = pane.title
            item.viewController?.title = pane.title
        }
        for item in view.window?.toolbar?.items ?? [] {
            if let index = tabViewItems.firstIndex(where: { ($0.identifier as? String) == item.itemIdentifier.rawValue }) {
                item.label = NotebookSettingsPane.allCases[index].title
            } else if let index = view.window?.toolbar?.items.filter({ $0.itemIdentifier != .flexibleSpace }).firstIndex(of: item), index < NotebookSettingsPane.allCases.count {
                item.label = NotebookSettingsPane.allCases[index].title
            }
        }
        if selectedTabViewItemIndex >= 0 { view.window?.title = NotebookSettingsPane.allCases[selectedTabViewItemIndex].title }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + super.toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace]
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let identifier = tabViewItem?.identifier as? String { behavior.defaults.set(identifier, forKey: "settings.selectedPane") }
        guard let identifier = tabViewItem?.identifier as? String,
              let pane = NotebookSettingsPane(rawValue: identifier) else { return }
        let size = NSSize(width: NotebookSettingsPane.contentWidth,
                          height: pane.preferredHeight(formatMode: source.formatMode))
        tabViewItem?.viewController?.preferredContentSize = size
        resizeWindow(to: size)
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: self)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.toolbar?.displayMode = .iconAndLabel
        window.toolbar?.allowsUserCustomization = false
        window.tabbingMode = .disallowed
        window.setContentSize(preferredContentSize)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("notebook-settings-window")
        window.center()
        placement = NotebookWindowPlacement(window: window, behavior: behavior, remembersSize: false) { "window.settings" }
        return window
    }
}

private struct SettingsPaneView: View {
    let pane: NotebookSettingsPane
    @ObservedObject var settings: LanguageSettings
    @EnvironmentObject private var sourceEditor: SourceEditorSettings
    @EnvironmentObject private var visualEditor: VisualEditorSettings
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var behavior: DocumentBehaviorSettings

    @AppStorage("notebook.rscript") private var rscript = ""
    @State private var cleaningCache = false
    @State private var cacheResult: String?
    @State private var rscriptError: String?
    @AppStorage("notebook.quarto") private var quarto = ""
    @State private var quartoError: String?
    @AppStorage("notebook.packageLibrary") private var packageLibrary = ""
    @State private var libraryError: String?
    @ObservedObject private var dependencies = EnvironmentDependencies.shared
    @State private var showingDependencyLog = false

    var body: some View {
        Form {
            switch pane {
            case .general:
                Section { settingsGrid { generalSettings } }
                Section { settingsGrid { storageSettings } }
            case .documents: documentSettings
            case .fonts:
                Section("Code") { settingsGrid { codeSettings } }
                Section("Visual") { settingsGrid { visualSettings } }
            case .highlighting: Section { settingsGrid { highlightingSettings } }
            case .completion: Section { settingsGrid { completionSettings } }
            case .formatting: Section { settingsGrid { formattingSettings } }
            case .environment:
                Section { settingsGrid { environmentSettings } }
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: NotebookSettingsPane.contentWidth,
               height: pane.preferredHeight(formatMode: sourceEditor.formatMode))
        .environment(\.locale, settings.locale)
        .tint(nil)
        .task(id: dependencyConfiguration) {
            if pane == .environment { dependencies.check(dependencyConfiguration) }
        }
        .alert(L10n.string("缓存清理"), isPresented: Binding(get: { cacheResult != nil }, set: { if !$0 { cacheResult = nil } })) {
            Button(L10n.string("确定")) { cacheResult = nil }
        } message: { Text(cacheResult ?? "") }
        .sheet(isPresented: $showingDependencyLog) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("依赖安装日志")).font(.headline)
                ScrollView {
                    Text(dependencies.log.isEmpty ? L10n.string("暂无日志") : dependencies.log)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if dependencies.isBusy { ProgressView().controlSize(.small); Button(L10n.string("取消")) { dependencies.cancel() } }
                    Spacer()
                    Button(L10n.string("关闭")) { showingDependencyLog = false }.keyboardShortcut(.cancelAction)
                }
            }.padding(20).frame(width: 500, height: 360)
        }
    }

    @ViewBuilder private var generalSettings: some View {
        settingsRow(L10n.string("界面语言")) {
            SettingsMenu(selection: Binding(get: { settings.preference }, set: { settings.select($0) }),
                         options: [(L10n.string("跟随系统"), LanguageSettings.system)] + AppLanguage.supported.map { ($0.nativeName, $0.id) },
                         identifier: "interface-language-picker")
        }
        settingsRow(L10n.string("界面外观")) {
            Picker(L10n.string("界面外观"), selection: $appearance.interface) {
                ForEach(InterfaceAppearance.allCases) { style in Text(style.label).tag(style) }
            }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                .id(settings.language.id)
                .accessibilityIdentifier("interface-appearance")
        }
        settingsRow(L10n.string("主题色")) {
            SettingsMenu(selection: $appearance.accent, options: AppAccent.allCases.map { ($0.label, $0) },
                         identifier: "app-accent-color", colors: AppAccent.allCases.map(\.color))
        }
    }

    @ViewBuilder private var storageSettings: some View {
        settingsRow(L10n.string("存储")) {
            HStack(spacing: 8) {
                Button(L10n.string("清理缓存…")) {
                    cleaningCache = true
                    Task {
                        do {
                            let result = try await Task.detached(priority: .utility) {
                                try NotebookCacheStore().sweep(removeAllFinished: true)
                            }.value
                            cacheResult = String(format: L10n.string("已清理 %ld 个任务缓存（%@）。"), result.removed,
                                ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
                        } catch { cacheResult = error.localizedDescription }
                        cleaningCache = false
                    }
                }.disabled(cleaningCache).accessibilityIdentifier("settings-clear-cache")
                    .help(L10n.string("只清理已结束的任务，保留运行中的任务、恢复草稿和已安装的包。"))
                Button(L10n.string("管理恢复草稿…")) {
                    NSApp.sendAction(#selector(RnotebookDelegate.recoverDocuments(_:)), to: NSApp.delegate, from: nil)
                }.accessibilityIdentifier("settings-manage-recovery")
                if cleaningCache { ProgressView().controlSize(.small) }
            }.controlSize(.small)
        }
    }

    @ViewBuilder private var documentSettings: some View {
        Section {
            settingsGrid {
                settingsRow(L10n.string("自动保存")) {
                    Toggle(L10n.string("自动保存已命名文档"), isOn: $behavior.autosaveEnabled)
                        .accessibilityIdentifier("documents-autosave")
                }
                settingsRow(L10n.string("停笔后")) {
                    SettingsMenu(selection: $behavior.idleDelay,
                                 options: DocumentBehaviorSettings.idleOptions.map { (seconds($0), $0) }, identifier: "documents-autosave-idle", width: 140)
                        .disabled(!behavior.autosaveEnabled)
                }
                settingsRow(L10n.string("持续输入时")) {
                    HStack(spacing: 8) {
                        Text(L10n.string("最长间隔"))
                        SettingsMenu(selection: $behavior.maximumDelay,
                                     options: DocumentBehaviorSettings.maximumOptions.map { (seconds($0), $0) }, identifier: "documents-autosave-maximum", width: 100)
                    }.disabled(!behavior.autosaveEnabled)
                }
            }
        }
        Section {
            settingsGrid {
                settingsRow(L10n.string("外部修改")) {
                    Toggle(L10n.string("自动加载与合并无冲突的修改"), isOn: $behavior.automaticallyReload)
                        .accessibilityIdentifier("documents-external-reload")
                }
            }
        }
        Section {
            settingsGrid {
                settingsRow(L10n.string("窗口")) {
                    Toggle(L10n.string("记住大小、位置与检查器宽度"), isOn: $behavior.rememberWindows)
                        .accessibilityIdentifier("windows-remember")
                }
            }
        }
    }

    private func seconds(_ value: Double) -> String { String(format: L10n.string("%@ 秒"), value.formatted(.number.locale(settings.locale))) }

    @ViewBuilder private var completionSettings: some View {
        settingsRow(L10n.string("R 代码补全")) {
            Toggle(L10n.string("启用代码补全"), isOn: $sourceEditor.completionEnabled)
                .toggleStyle(.checkbox).accessibilityIdentifier("r-completion-enabled")
        }
        settingsRow(L10n.string("自动触发")) {
            HStack(spacing: 12) {
                Toggle(L10n.string("自动弹出"), isOn: $sourceEditor.completionAutomatic)
                    .accessibilityIdentifier("r-completion-automatic")
                SettingsMenu(selection: $sourceEditor.completionDelay,
                    options: [100, 220, 400, 600].map { ("\($0) ms", $0) }, identifier: "r-completion-delay", width: 100)
                    .disabled(!sourceEditor.completionAutomatic)
            }.disabled(!sourceEditor.completionEnabled)
        }
        settingsRow(L10n.string("最少字符数")) {
            HStack(spacing: 12) {
                SettingsMenu(selection: $sourceEditor.completionMinimum, options: (1...3).map { (String($0), $0) },
                    identifier: "r-completion-minimum", width: 62)
                    .disabled(!sourceEditor.completionAutomatic)
                Text(L10n.string("候选上限")).foregroundStyle(.secondary)
                SettingsMenu(selection: $sourceEditor.completionLimit, options: [20, 40, 80].map { (String($0), $0) },
                    identifier: "r-completion-limit", width: 66)
            }.disabled(!sourceEditor.completionEnabled)
        }
        settingsRow(L10n.string("提示内容")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.string("参数名补全"), isOn: $sourceEditor.completionParameters).accessibilityIdentifier("r-completion-parameters")
                Toggle(L10n.string("函数签名提示"), isOn: $sourceEditor.completionSignature).accessibilityIdentifier("r-completion-signature")
                Toggle(L10n.string("当前 R 会话中的对象"), isOn: $sourceEditor.completionRuntime).accessibilityIdentifier("r-completion-runtime")
            }.disabled(!sourceEditor.completionEnabled)
        }
        settingsRow(L10n.string("确认候选")) {
            Toggle(L10n.string("Return 接受候选"), isOn: $sourceEditor.completionReturn)
                .accessibilityIdentifier("r-completion-return").disabled(!sourceEditor.completionEnabled)
                .help(L10n.string("Tab 始终可确认，Esc 关闭；关闭自动弹出后仍可按 Control-Space 手动补全。"))
        }
    }

    @ViewBuilder private var highlightingSettings: some View {
        settingsRow(L10n.string("语法高亮")) {
            Toggle(L10n.string("启用语法高亮"), isOn: $sourceEditor.syntaxEnabled).accessibilityIdentifier("syntax-enabled")
        }
        settingsRow(L10n.string("配色方案")) {
            SettingsMenu(selection: $sourceEditor.syntaxPalette,
                options: [(L10n.string("默认"), "default"), (L10n.string("海洋"), "ocean"), (L10n.string("森林"), "forest"), (L10n.string("暖色"), "warm")],
                identifier: "syntax-palette")
                .disabled(!sourceEditor.syntaxEnabled)
                .help(L10n.string("每套配色均适配浅色和深色；Code 与 Visual 代码块共用。"))
        }
        settingsRow(L10n.string("强调样式")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.string("注释斜体"), isOn: $sourceEditor.syntaxItalicComments).accessibilityIdentifier("syntax-italic-comments")
                Toggle(L10n.string("关键字加粗"), isOn: $sourceEditor.syntaxBoldKeywords).accessibilityIdentifier("syntax-bold-keywords")
            }.disabled(!sourceEditor.syntaxEnabled)
        }
        settingsRow(L10n.string("预览")) {
            RecordSyntaxPreview(preferences: RecordSyntaxPreferences(sourceEditor))
                .frame(height: 82).accessibilityIdentifier("syntax-preview")
        }
    }

    @ViewBuilder private var formattingSettings: some View {
        settingsRow(L10n.string("R 代码格式化")) {
            SettingsMenu(selection: $sourceEditor.formatMode,
                options: [(L10n.string("跟随文稿配置"), "document"), (L10n.string("自定义"), "custom")], identifier: "r-format-mode")
                .help(L10n.string("跟随文稿附近的 air.toml；未配置时使用 Air 默认样式。Code 和 Visual 共用。"))
        }
        if sourceEditor.formatMode == "custom" {
            settingsRow(L10n.string("首选行宽")) {
                SettingsMenu(selection: $sourceEditor.formatLineWidth,
                    options: Array(Set([60, 80, 100, 120, 160, sourceEditor.formatLineWidth])).sorted().map { (String($0), $0) },
                    identifier: "r-format-line-width", width: 100)
            }
            settingsRow(L10n.string("缩进空格")) {
                SettingsMenu(selection: $sourceEditor.formatIndentWidth,
                    options: Array(Set([2, 4, 8, sourceEditor.formatIndentWidth])).sorted().map { (String($0), $0) },
                    identifier: "r-format-indent-width", width: 100)
            }
            settingsRow(L10n.string("换行倾向")) {
                Toggle(L10n.string("保留多行函数调用"), isOn: $sourceEditor.formatPersistentBreaks)
                    .accessibilityIdentifier("r-format-persistent-breaks")
                    .help(L10n.string("关闭后，能在首选行宽内放下的调用会尽量合并。"))
            }
        }
    }
    @ViewBuilder private var codeSettings: some View {
        settingsRow(L10n.string("字体与字号")) {
            fontRow(font: $sourceEditor.fontName, size: $sourceEditor.fontSize,
                    options: SourceEditorSettings.fonts, range: 10...32, prefix: "source-editor")
        }
        settingsRow("") {
            RecordFontPreview(lines: [
                ("mean(c(12, 18, 24))", NotebookFontCatalog.font(sourceEditor.fontName, size: sourceEditor.fontSize, code: true)),
                ("median(c(1, 2, 3))", NotebookFontCatalog.font(sourceEditor.fontName, size: sourceEditor.fontSize, code: true))
            ]).frame(height: 82).accessibilityIdentifier("source-font-preview")
        }
    }
    @ViewBuilder private var visualSettings: some View {
        settingsRow(L10n.string("正文字体")) {
            HStack(spacing: 8) {
                SettingsMenu(selection: $visualEditor.bodyFont,
                             options: NotebookFontCatalog.options(including: visualEditor.bodyFont).map { ($0 == "system" ? L10n.string("系统默认") : $0, $0) },
                             identifier: "visual-body-font", width: 250)
                SettingsFontSize(value: $visualEditor.bodySize, range: 10...28, identifier: "visual-body-size", label: L10n.string("Visual 正文字号"))
            }
        }
        settingsRow(L10n.string("代码字体")) {
            fontRow(font: $visualEditor.codeFont, size: $visualEditor.codeSize,
                    options: VisualEditorSettings.codeFonts, range: 10...24, prefix: "visual-code")
        }
        settingsRow("") {
            RecordFontPreview(lines: [
                (L10n.string("用文字讲述数据。"), NotebookFontCatalog.font(visualEditor.bodyFont, size: visualEditor.bodySize, code: false)),
                ("summary(data)", NotebookFontCatalog.font(visualEditor.codeFont, size: visualEditor.codeSize, code: true))
            ]).frame(height: 82).accessibilityIdentifier("visual-font-preview")
        }
    }

    @ViewBuilder private var environmentSettings: some View {
        environmentPath("Rscript", url: rscriptURL, custom: !rscript.isEmpty,
                        identifier: "notebook-rscript-path", buttonID: "notebook-select-r",
                        title: L10n.string("选择 Rscript"), directory: false,
                        fallback: "/Library/Frameworks/R.framework/Resources/bin",
                        reset: { rscript = ""; rscriptError = nil }) { url in
            rscriptError = SettingsEnvironment.selectionError(url, directory: false)
            if rscriptError == nil { rscript = url.path }
        }
        if let rscriptError { settingsRow("") { errorNote(rscriptError) } }
        environmentPath("Quarto", url: quartoURL, custom: !quarto.isEmpty,
                        identifier: "notebook-quarto-path", buttonID: "notebook-select-quarto",
                        title: L10n.string("选择 Quarto 可执行文件"), directory: false,
                        fallback: "/Applications/quarto/bin",
                        reset: { quarto = ""; quartoError = nil }) { url in
            quartoError = SettingsEnvironment.selectionError(url, directory: false)
            if quartoError == nil { quarto = url.path }
        }
        if let quartoError { settingsRow("") { errorNote(quartoError) } }
        environmentPath(L10n.string("R 包目录"), url: libraryURL, custom: !packageLibrary.isEmpty,
                        identifier: "notebook-library-path", buttonID: "notebook-select-library",
                        title: L10n.string("选择 R 包安装目录"), directory: true, fallback: NSHomeDirectory(),
                        reset: { packageLibrary = ""; libraryError = nil }) { url in
            libraryError = SettingsEnvironment.selectionError(url, directory: true)
            if libraryError == nil { packageLibrary = url.path }
        }
        if let libraryError { settingsRow("") { errorNote(libraryError) } }
        settingsRow("") {
            Text(L10n.string("R 与包目录更改后需重启 R。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        settingsRow(L10n.string("必要依赖")) {
            VStack(alignment: .leading, spacing: 8) {
                if dependencies.isBusy {
                    HStack { ProgressView().controlSize(.small); Text(dependencies.isInstalling ? L10n.string("正在安装缺失依赖…") : L10n.string("正在检测…")) }
                } else if let report = dependencies.report {
                    Text(report.ready ? L10n.string("环境已就绪") : L10n.string("环境需要处理"))
                        .foregroundStyle(report.ready ? Color.secondary : Color.primary)
                    Text("R: " + (report.rVersion ?? "—") + "\nQuarto: " + (report.quartoVersion ?? "—"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    if report.packagesChecked, !report.missing.isEmpty {
                        Text(L10n.string("缺失：") + report.missing.joined(separator: ", ")).font(.caption)
                    }
                    if !report.errors.isEmpty {
                        Text(report.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.red)
                    }
                }
                HStack(spacing: 12) {
                    Button(L10n.string("重新检测")) { dependencies.check(dependencyConfiguration) }
                        .disabled(dependencies.isBusy).accessibilityIdentifier("dependencies-check")
                    Button(L10n.string("一键安装")) { dependencies.installMissing(dependencyConfiguration); showingDependencyLog = true }
                        .disabled(dependencies.isBusy || dependencies.report?.packagesChecked != true || dependencies.report?.missing.isEmpty != false || dependencies.report?.rVersion == nil)
                        .accessibilityIdentifier("dependencies-install")
                    if dependencies.isBusy { Button(L10n.string("取消")) { dependencies.cancel() }.accessibilityIdentifier("dependencies-cancel") }
                    if !dependencies.log.isEmpty { Button(L10n.string("日志")) { showingDependencyLog = true }.accessibilityIdentifier("dependencies-log") }
                }.controlSize(.small)
                if dependencyConfiguration.rscript == nil || dependencyConfiguration.quarto == nil {
                    HStack {
                        if dependencyConfiguration.rscript == nil { Link(L10n.string("下载 R"), destination: URL(string: "https://cran.r-project.org/bin/macosx/")!) }
                        if dependencyConfiguration.quarto == nil { Link(L10n.string("下载 Quarto"), destination: URL(string: "https://quarto.org/docs/get-started/")!) }
                    }.font(.caption)
                }
            }.help(L10n.string("evaluate、jsonlite、rlang、knitr、rmarkdown；仅安装缺失包及其必要依赖。"))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("dependencies-status")
        }
    }

    private var dependencyConfiguration: DependencyConfiguration {
        DependencyConfiguration(rscript: rscriptURL, quarto: quartoURL, library: libraryURL)
    }

    private var rscriptURL: URL? {
        rscript.isEmpty ? NotebookRExecutable.locate(selected: nil) : URL(fileURLWithPath: rscript)
    }
    private var quartoURL: URL? {
        quarto.isEmpty ? QuartoExecutable.locate() : URL(fileURLWithPath: quarto)
    }
    private var libraryURL: URL { packageLibrary.isEmpty ? NotebookLibrary.defaultURL : URL(fileURLWithPath: packageLibrary) }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.9)
                .frame(width: 170, alignment: .trailing).help(label)
            content().frame(width: 390, alignment: .leading)
        }
    }

    private func settingsGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func errorNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }

    private func fontRow(font: Binding<String>, size: Binding<Double>, options: [String], range: ClosedRange<Double>, prefix: String) -> some View {
        HStack(spacing: 8) {
            SettingsMenu(selection: font, options: NotebookFontCatalog.options(including: font.wrappedValue).map { ($0 == "system" ? L10n.string("系统默认") : $0, $0) },
                         identifier: prefix + "-font", width: 250)
            SettingsFontSize(value: size, range: range, identifier: prefix == "visual-code" ? "visual-code-size" : "source-editor-size", label: prefix == "visual-code" ? L10n.string("Visual 代码字号") : L10n.string("源码字号"))
        }
    }

    private func environmentPath(_ label: String, url: URL?, custom: Bool, identifier: String, buttonID: String,
                                 title: String, directory: Bool, fallback: String, reset: @escaping () -> Void,
                                 selected: @escaping (URL) -> Void) -> some View {
        settingsRow(label) {
            HStack(spacing: 8) {
                SettingsPath(url: url, identifier: identifier, source: custom ? L10n.string("自定义") : (directory ? L10n.string("默认目录") : L10n.string("自动查找")))
                    .frame(width: 288, height: 24)
                SettingsFileButton(title: title, directory: directory, current: url,
                                   fallback: URL(fileURLWithPath: fallback), identifier: buttonID, selected: selected)
                    .frame(width: 62, height: 24)
                Button(action: reset) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless).frame(width: 24, height: 24)
                .disabled(!custom)
                .help(directory ? L10n.string("恢复默认目录") : L10n.string("恢复自动查找"))
                .accessibilityLabel(directory ? L10n.string("恢复默认目录") : L10n.string("恢复自动查找"))
                .accessibilityIdentifier(identifier + "-reset")
            }.disabled(dependencies.isInstalling)
        }
    }
}

/// AppKit owns menu geometry, focus, colors and keyboard interaction.
private struct SettingsMenu<Value: Equatable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [(String, Value)]
    let identifier: String
    var width: CGFloat = 300
    var colors: [NSColor] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != options.map(\.0) {
            button.removeAllItems(); button.addItems(withTitles: options.map(\.0))
        }
        for (index, color) in colors.enumerated() where index < button.numberOfItems {
            button.item(at: index)?.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
            }
        }
        if let index = options.firstIndex(where: { $0.1 == selection }) { button.selectItem(at: index) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SettingsMenu
        init(_ parent: SettingsMenu) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.options[sender.indexOfSelectedItem].1
        }
    }
}
