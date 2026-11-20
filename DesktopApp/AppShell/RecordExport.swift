import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class RecordQuartoExporter: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = L10n.string("选择格式和输出位置")
    @Published private(set) var log = ""
    @Published private(set) var diagnostic: String?
    @Published private(set) var record: QuartoExportRecord?
    private weak var model: RecordLayoutModel?
    weak var window: NSWindow?
    private var operation: Task<Void, Never>?
    private var process: QuartoProcess?
    private var generation = UUID()
    var toolOverride: QuartoExportTools?
    var outputRoot: URL?
    var taskFilesURL: URL? {
        guard let directory = record?.directory,
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory
    }
    var openArtifact: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    init(model: RecordLayoutModel) {
        self.model = model; super.init()
        QuartoExports.register(self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
    }
    @objc private func windowClosed(_ note: Notification) {
        if note.object as? NSWindow === window { cancel() }
    }
    @discardableResult func present(window: NSWindow?) -> Bool {
        guard let model else { return false }
        if let document = model.document, document.fileURL == nil {
            document.ensureSaved { [weak self] in _ = self?.present(window: window) }; return true
        }
        guard model.activeEditor?.hasMarkedText() != true,
              model.activeEditor.map({ $0.string.utf8.elementsEqual(model.source.utf8) }) ?? true else {
            model.notice = L10n.string("请先完成当前输入，再导出。"); return false
        }
        self.window = window; model.showingExport = true; return true
    }
    func tools() throws -> QuartoExportTools {
        if let toolOverride { return toolOverride }
        guard let model, let quarto = QuartoExecutable.locate(selected: model.visualDefaults.string(forKey: "notebook.quarto")),
              let rscript = NotebookRExecutable.locate(selected: model.visualDefaults.string(forKey: "notebook.rscript")) else { throw QuartoExportError.missingTools }
        return QuartoExportTools(quarto: quarto, rscript: rscript)
    }
    func start(options: QuartoExportOptions, destination: URL, overwrite: Bool = false) {
        guard !isRunning, let model else { diagnostic = QuartoExportError.busy.localizedDescription; return }
        guard model.activeEditor?.hasMarkedText() != true,
              model.activeEditor.map({ $0.string.utf8.elementsEqual(model.source.utf8) }) ?? true else {
            diagnostic = L10n.string("请先完成当前输入，再导出。"); return
        }
        do { _ = try options.metadata() } catch { diagnostic = error.localizedDescription; return }
        let source = model.source, id = UUID()
        generation = id; log = ""; diagnostic = nil; record = nil
        status = L10n.string("正在准备渲染文档…")
        isRunning = true; model.objectWillChange.send()
        let runner = QuartoProcess(); process = runner
        operation = Task { [weak self] in
            guard let self else { return }
            defer { isRunning = false; operation = nil; process = nil; model.objectWillChange.send() }
            do {
                let selectedTools = try tools()
                let target = try QuartoDestination(destination, overwrite: overwrite)
                guard let documentURL = model.documentURL else { throw QuartoExportError.detail(L10n.string("请先保存 QMD 文档。")) }
                let store = outputRoot.map { NotebookCacheStore(root: $0) } ?? NotebookCacheStore()
                let lease = try store.create(.exports)
                let directory = lease.directory
                var cacheFinished = false
                defer { if !cacheFinished { try? lease.finish(failed: true) } }
                let input = QuartoExportInput(source: source, documentURL: documentURL)
                let result = await QuartoExportEngine.run(input: input, options: options, tools: selectedTools, destination: target, directory: directory,
                    process: runner, log: { [weak self] stream, bytes in
                        Task { @MainActor in self?.appendLog(stream, bytes: bytes, id: id) }
                    }, prepared: { [weak self] record in
                        Task { @MainActor in
                            guard let self, self.generation == id, self.isRunning else { return }
                            self.record = record; self.status = L10n.string("Quarto 正在导出…")
                        }
                    }, cacheLease: lease)
                var final = result
                final.sourceChanged = DocumentRevision(text: model.source).rawValue != final.sourceHash
                try? QuartoExportEngine.save(final)
                try? lease.finish(failed: final.status == .failed || final.status == .timedOut)
                cacheFinished = true
                record = final; diagnostic = final.diagnostic
                switch final.status {
                case .succeeded: status = L10n.string("导出完成")
                case .cancelled: status = L10n.string("已取消导出")
                case .timedOut: status = L10n.string("导出超时"); diagnostic = L10n.string("Quarto 超过任务时限，已停止本次导出；可查看日志。")
                default: status = L10n.string("导出失败")
                }
                if let artifact = final.artifact, options.openAfterExport {
                    if !openArtifact(artifact) { diagnostic = L10n.string("文件已导出，但未能自动打开。") }
                }
            } catch {
                status = Task.isCancelled || runner.isCancelled ? L10n.string("已取消导出") : L10n.string("导出失败")
                diagnostic = Task.isCancelled || runner.isCancelled ? nil : error.localizedDescription
            }
        }
    }
    private func appendLog(_ stream: Int, bytes: Data, id: UUID) {
        guard generation == id else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        let remaining = max(0, 2_097_152 - log.utf8.count)
        if remaining > 0 { log += String(decoding: Data(text.utf8).prefix(remaining), as: UTF8.self) }
    }
    func cancel() { process?.cancel(); operation?.cancel(); if isRunning { status = L10n.string("正在取消导出…") } }
    func waitUntilIdle() async { await operation?.value }
    func shutdown() async { cancel(); await operation?.value }
}
@MainActor enum QuartoExports {
    private final class Weak { weak var value: RecordQuartoExporter?; init(_ value: RecordQuartoExporter) { self.value = value } }
    private static var instances: [Weak] = []
    static func register(_ value: RecordQuartoExporter) { instances.removeAll { $0.value == nil }; instances.append(Weak(value)) }
    static var hasRunning: Bool { instances.contains { $0.value?.isRunning == true } }
    static func shutdownAll() async { for value in instances.compactMap(\.value) { await value.shutdown() } }
}

struct RecordExportSheet: View {
    @ObservedObject var model: RecordLayoutModel
    @ObservedObject var exporter: RecordQuartoExporter
    @Environment(\.dismiss) private var dismiss
    @State private var options = QuartoExportOptions()
    @State private var destination: URL?
    @State private var panelError: String?
    @State private var customTab = 0
    @State private var showingLog = false
    @State private var selectingDestination = false

    init(model: RecordLayoutModel, exporter: RecordQuartoExporter) {
        self.model = model; self.exporter = exporter
    }
    private var custom: Bool { options.parameterSource == .custom }
    private var customPanelHeight: CGFloat {
        switch customTab {
        case 1:
            switch options.format { case .docx: 98; case .typst: 136; case .html, .pdf: 186 }
        case 2: options.format == .html ? 252 : 224
        case 3: 234
        default: options.format == .typst ? 212 : 234
        }
    }
    private var baseHeight: CGFloat { custom ? customPanelHeight + 226 : 220 }
    private var logHeight: CGFloat { exporter.log.isEmpty && exporter.record == nil ? 40 : 116 }
    private var sheetHeight: CGFloat {
        let available = (exporter.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return min(baseHeight + (showingLog ? logHeight + 8 : 0), available - 100)
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string("Quarto 渲染")).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            VStack(spacing: 8) {
                row(L10n.string("输出格式")) {
                    Picker(L10n.string("输出格式"), selection: $options.format) {
                        ForEach(QuartoExportFormat.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().frame(width: 130, alignment: .leading)
                        .accessibilityIdentifier("quarto-format")
                    Toggle(L10n.string("渲染完成后打开文件"), isOn: $options.openAfterExport)
                        .font(.system(size: 11)).fixedSize().padding(.leading, 8)
                        .accessibilityIdentifier("quarto-open-after")
                    Spacer(minLength: 0)
                }
                row(L10n.string("输出位置")) {
                    SettingsPath(url: destination, identifier: "quarto-destination", source: L10n.string("输出位置"))
                        .frame(height: 24)
                    Button(L10n.string("选择…")) { chooseDestination() }
                        .accessibilityIdentifier("quarto-choose-destination")
                }
                row(L10n.string("参数设置")) {
                    Picker(L10n.string("参数设置"), selection: $options.parameterSource) {
                        ForEach(QuartoParameterSource.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                        .accessibilityIdentifier("quarto-parameter-source")
                    Spacer(minLength: 0)
                }
                row("") {
                    Toggle(L10n.string("兼容 Edmund 语法"), isOn: $options.edmundCompatibility)
                        .toggleStyle(.checkbox)
                        .help(L10n.string("导出时转换高亮、注释、提示块等扩展语法，不修改原文。"))
                        .accessibilityIdentifier("quarto-edmund-compatibility")
                    Spacer(minLength: 0)
                }
            }.padding(.horizontal, 20).font(.system(size: 12)).controlSize(.small)
                .disabled(exporter.isRunning || selectingDestination)
            if custom {
                customSettings.padding(.top, 10)
                    .disabled(exporter.isRunning || selectingDestination)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("quarto-custom-settings")
            } else { Spacer(minLength: 8) }
            if showingLog { logPanel.frame(height: logHeight) }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(width: 540, height: sheetHeight, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(exporter.isRunning)
        .onAppear { if destination == nil { destination = defaultDestination } }
        .onChange(of: options.format) { _, format in
            if let selected = destination { destination = selected.deletingPathExtension().appendingPathExtension(format.fileExtension) }
            else { destination = defaultDestination }
            panelError = nil
        }
        .onChange(of: options.parameterSource) { _, _ in panelError = nil }
        .accessibilityElement(children: .contain).accessibilityIdentifier("quarto-export-sheet")
    }
    private var defaultDestination: URL? { model.documentURL?.deletingPathExtension().appendingPathExtension(options.format.fileExtension) }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                .accessibilityHidden(label.isEmpty)
            content()
        }.frame(minHeight: 22)
    }
    private var customSettings: some View {
        QuartoParameterTabs(selection: $customTab, titles: [L10n.string("文档"), L10n.string("样式"), L10n.string("代码与图形"), L10n.string("更多参数")]) {
            Group {
                switch customTab {
                case 1: customStyle
                case 2: customCode
                case 3: customMore
                default: customDocument
                }
            }
            .font(.system(size: 11)).controlSize(.small).toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .appAppearance(NotebookPreferences.appearance)
        }
        .frame(maxWidth: .infinity).frame(height: customPanelHeight)
        .padding(.horizontal, 20).padding(.bottom, 12)
    }
    private var customDocument: some View {
        customForm {
            field(L10n.string("标题"), text: $options.title, identifier: "quarto-title")
            if options.format != .typst { field(L10n.string("副标题"), text: $options.subtitle) }
            field(L10n.string("作者"), text: $options.author, width: 180)
            parameterRow(L10n.string("日期")) {
                TextField(L10n.string("日期"), text: $options.date, prompt: Text("YYYY-MM-DD"))
                    .labelsHidden().frame(width: 110)
                Text(L10n.string("语言")).foregroundStyle(.secondary).padding(.leading, 6)
                TextField(L10n.string("语言"), text: $options.language, prompt: Text("zh-CN / en-US"))
                    .labelsHidden().frame(width: 90).accessibilityIdentifier("quarto-language")
                Spacer(minLength: 0)
            }
            parameterRow(L10n.string("摘要")) {
                TextField(L10n.string("摘要"), text: $options.abstract, prompt: Text(""), axis: .vertical)
                    .labelsHidden().lineLimit(2...2)
            }
            Divider().padding(.vertical, 2)
            parameterRow(L10n.string("结构")) {
                Toggle(L10n.string("目录"), isOn: flag($options.toc)).accessibilityIdentifier("quarto-toc")
                if options.toc == .yes {
                    Stepper(L10n.string("目录深度：\(String(options.tocDepth))"), value: $options.tocDepth, in: 1...6)
                        .fixedSize().padding(.horizontal, 6)
                }
                Toggle(L10n.string("章节编号"), isOn: flag($options.numbering))
                Spacer(minLength: 0)
            }
        }
    }
    private var customStyle: some View {
        customForm {
            if options.format == .html {
                parameterRow(L10n.string("主题")) {
                    valueMenu(L10n.string("主题"), selection: $options.htmlTheme, values: ["cosmo", "flatly", "litera", "lumen", "minty", "sandstone", "simplex", "sketchy", "slate", "solar", "superhero", "yeti", "zephyr"])
                        .frame(width: 130, alignment: .leading)
                    Spacer(minLength: 0)
                }
                parameterRow(L10n.string("页面布局")) {
                    Picker(L10n.string("页面布局"), selection: $options.pageLayout) {
                        Text(L10n.string("文章")).tag("article"); Text(L10n.string("全宽")).tag("full")
                    }.labelsHidden().frame(width: 110, alignment: .leading)
                    Text(L10n.string("目录位置")).foregroundStyle(.secondary).padding(.leading, 6)
                    Picker(L10n.string("目录位置"), selection: $options.tocLocation) {
                        Text(L10n.string("右侧")).tag("right"); Text(L10n.string("左侧")).tag("left"); Text(L10n.string("正文内")).tag("body")
                    }.labelsHidden().frame(width: 110, alignment: .leading).disabled(options.toc != .yes)
                    Spacer(minLength: 0)
                }
                fileField(L10n.string("CSS 样式"), path: $options.stylesheet, extensions: ["css"])
                Divider().padding(.vertical, 2)
            }
            if options.format == .docx {
                fileField(L10n.string("Word 样式模板"), path: $options.referenceDoc, extensions: ["docx"])
                    .accessibilityIdentifier("quarto-reference-doc")
                parameterRow(L10n.string("代码高亮")) {
                    codeThemeMenu.frame(width: 130, alignment: .leading)
                    Spacer(minLength: 0)
                }
            } else {
                parameterRow(L10n.string("主字体")) {
                    Picker(L10n.string("主字体"), selection: $options.pdfFont) {
                        Text(L10n.string("Quarto 默认字体")).tag("")
                        ForEach(NotebookFontCatalog.families.filter { $0 != "system" }, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 180, alignment: .leading).accessibilityIdentifier("quarto-pdf-font")
                    Text(L10n.string("字号")).foregroundStyle(.secondary).padding(.leading, 6)
                    numberInput(L10n.string("字号"), text: $options.fontSize, unit: "pt")
                    Spacer(minLength: 0)
                }
                parameterRow(L10n.string("行距")) {
                    numberInput(L10n.string("行距"), text: $options.lineStretch, unit: "×")
                    Text(L10n.string("代码高亮")).foregroundStyle(.secondary).padding(.leading, 6)
                    codeThemeMenu.frame(width: 120, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
            if options.format.isPDF {
                Divider().padding(.vertical, 2)
                parameterRow(L10n.string("纸张")) {
                    valueMenu(L10n.string("纸张"), selection: $options.paperSize, values: ["a4", "letter", "legal", "a5"])
                        .frame(width: 110, alignment: .leading)
                    Text(L10n.string("页边距")).foregroundStyle(.secondary).padding(.leading, 6)
                    numberInput(L10n.string("页边距"), text: $options.marginMM, unit: "mm")
                    Spacer(minLength: 0)
                }
                if options.format == .pdf {
                    parameterRow(L10n.string("排版引擎")) {
                        valueMenu(L10n.string("排版引擎"), selection: $options.pdfEngine, values: ["xelatex", "lualatex", "pdflatex", "tectonic"])
                            .frame(width: 110, alignment: .leading)
                        Text(L10n.string("文档类型")).foregroundStyle(.secondary).padding(.leading, 6)
                        valueMenu(L10n.string("文档类型"), selection: $options.documentClass, values: ["article", "report", "book", "scrartcl"])
                            .frame(width: 110, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    field(L10n.string("中文字体"), text: $options.cjkFont, width: 220)
                }
            }
        }
    }
    private var codeThemeMenu: some View {
        valueMenu(L10n.string("代码高亮"), selection: $options.codeTheme, values: ["pygments", "tango", "espresso", "zenburn", "monochrome", "breezedark", "none"])
    }
    private var customCode: some View {
        customForm {
            parameterRow(L10n.string("执行与输出")) {
                Toggle(L10n.string("运行代码"), isOn: Binding(get: { options.execution != .disabled }, set: { options.execution = $0 ? .fresh : .disabled }))
                    .accessibilityIdentifier("quarto-execution")
                Toggle(L10n.string("使用计算缓存"), isOn: $options.cache).disabled(options.execution == .disabled)
                Toggle(L10n.string("出错后继续"), isOn: flag($options.continueOnError))
                Spacer(minLength: 0)
            }
            parameterRow(L10n.string("显示")) {
                Toggle(L10n.string("显示源码"), isOn: flag($options.echo))
                Toggle(L10n.string("显示结果"), isOn: $options.output)
                Toggle(L10n.string("显示警告"), isOn: flag($options.warning))
                Toggle(L10n.string("显示消息"), isOn: $options.message)
                Spacer(minLength: 0)
            }
            Divider().padding(.vertical, 2)
            parameterRow(L10n.string("代码显示")) {
                Toggle(L10n.string("代码行号"), isOn: $options.codeLineNumbers)
                if options.format == .html {
                    Toggle(L10n.string("代码折叠"), isOn: flag($options.codeFold)).accessibilityIdentifier("quarto-code-fold")
                    Toggle(L10n.string("代码复制按钮"), isOn: flag($options.codeCopy))
                }
                Spacer(minLength: 0)
            }
            if options.format == .html {
                parameterRow(L10n.string("长代码行")) {
                    Picker(L10n.string("长代码行"), selection: $options.codeOverflow) {
                        Text(L10n.string("自动换行")).tag("wrap"); Text(L10n.string("横向滚动")).tag("scroll")
                    }.labelsHidden().frame(width: 130, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
            Divider().padding(.vertical, 2)
            parameterRow(L10n.string("图形尺寸")) {
                Text(L10n.string("图宽")).foregroundStyle(.secondary)
                numberInput(L10n.string("图宽"), text: $options.figureWidth, unit: "in", identifier: "quarto-figure-width")
                Text(L10n.string("图高")).foregroundStyle(.secondary).padding(.leading, 6)
                numberInput(L10n.string("图高"), text: $options.figureHeight, unit: "in")
                Spacer(minLength: 0)
            }
            parameterRow(L10n.string("图形输出")) {
                Text("DPI").foregroundStyle(.secondary)
                numberInput("DPI", text: $options.figureDPI, unit: "")
                Text(L10n.string("图形格式")).foregroundStyle(.secondary).padding(.leading, 6)
                Picker(L10n.string("图形格式"), selection: Binding(get: { options.effectiveFigureFormat }, set: { options.figureFormat = $0 })) {
                    ForEach(options.format.figureFormats, id: \.self) { Text($0.uppercased()).tag($0) }
                }.labelsHidden().frame(width: 110, alignment: .leading)
                Spacer(minLength: 0)
            }
            parameterRow(L10n.string("图形对齐")) {
                Picker(L10n.string("图形对齐"), selection: $options.figureAlign) {
                    Text(L10n.string("居中对齐")).tag("center"); Text(L10n.string("左对齐")).tag("left"); Text(L10n.string("右对齐")).tag("right")
                }.labelsHidden().frame(width: 110, alignment: .leading)
                Text(L10n.string("表格输出")).foregroundStyle(.secondary).padding(.leading, 6)
                Picker(L10n.string("表格输出"), selection: Binding(get: { options.effectiveTablePrint }, set: { options.tablePrint = $0 })) {
                    Text(L10n.string("普通表格")).tag("kable"); Text("tibble").tag("tibble"); Text("R print").tag("default")
                    if options.format == .html { Text(L10n.string("分页表格")).tag("paged") }
                }.labelsHidden().frame(width: 110, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }
    private var customMore: some View {
        customForm {
            fileField(L10n.string("参考文献"), path: $options.bibliography, extensions: ["bib", "json", "yaml", "yml"])
            fileField(L10n.string("引用样式"), path: $options.citationStyle, extensions: ["csl"])
            HStack {
                Text(L10n.string("其他 YAML 参数")).foregroundStyle(.secondary)
                Spacer()
                Link(L10n.string("参数参考"), destination: URL(string: "https://quarto.org/docs/reference/formats/" + options.format.rawValue + ".html")!)
            }.padding(.top, 4)
            TextEditor(text: Binding(get: { options.extraYAMLByFormat[options.format.rawValue] ?? "" },
                                     set: { options.extraYAMLByFormat[options.format.rawValue] = $0 }))
                .font(.system(size: 11, design: .monospaced)).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityIdentifier("quarto-extra-yaml")
        }
    }
    private func customForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
    }
    private func parameterRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 71, alignment: .trailing)
            content()
        }.frame(minHeight: 22)
    }
    private func field(_ label: String, text: Binding<String>, width: CGFloat = 280, prompt: String = "", identifier: String = "") -> some View {
        parameterRow(label) {
            TextField(label, text: text, prompt: Text(prompt)).labelsHidden().frame(width: width).accessibilityIdentifier(identifier)
            Spacer(minLength: 0)
        }
    }
    private func flag(_ value: Binding<QuartoOverride>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue == .yes }, set: { value.wrappedValue = $0 ? .yes : .no })
    }
    private func numberInput(_ label: String, text: Binding<String>, unit: String, identifier: String = "") -> some View {
        HStack(spacing: 4) {
            TextField(label, text: text).labelsHidden().textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing).frame(width: 54).accessibilityIdentifier(identifier)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false).frame(minWidth: 18, alignment: .leading) }
        }.fixedSize()
    }
    private func valueMenu(_ label: String, selection: Binding<String>, values: [String]) -> some View {
        Picker(label, selection: selection) { ForEach(values, id: \.self) { Text($0).tag($0) } }
            .labelsHidden()
    }
    private func fileField(_ label: String, path: Binding<String>, extensions: [String]) -> some View {
        parameterRow(label) {
            TextField(label, text: path, prompt: Text("")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 280)
            Button(L10n.string("选择…")) {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
                panel.allowsMultipleSelection = false
                if let parent = exporter.window?.attachedSheet ?? exporter.window {
                    panel.beginSheetModal(for: parent) { response in if response == .OK, let url = panel.url { path.wrappedValue = url.path } }
                }
            }
            Spacer(minLength: 0)
        }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showingLog.toggle()
            } label: {
                Label(L10n.string("日志"), systemImage: showingLog ? "chevron.up" : "chevron.down")
            }.buttonStyle(.borderless).accessibilityIdentifier("quarto-toggle-log")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if exporter.isRunning { ProgressView().controlSize(.small) }
                    Text(panelError ?? exporter.diagnostic ?? exporter.status)
                        .foregroundStyle(panelError != nil || exporter.diagnostic != nil ? Color.red : Color.secondary)
                        .lineLimit(1).help(panelError ?? exporter.diagnostic ?? exporter.status)
                }
                if let artifact = exporter.record?.artifact {
                    Button(artifact.lastPathComponent) { _ = exporter.openArtifact(artifact) }
                        .buttonStyle(.link).lineLimit(1).accessibilityIdentifier("quarto-open-file")
                }
            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("quarto-status")
            Button(L10n.string("取消"), role: .cancel) {
                if exporter.isRunning { exporter.cancel() } else { dismiss() }
            }.accessibilityIdentifier("quarto-cancel")
            Button(L10n.string("导出")) { begin() }
                .keyboardShortcut(.defaultAction).disabled(exporter.isRunning || selectingDestination)
                .accessibilityIdentifier("quarto-start")
        }
    }
    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let record = exporter.record {
                HStack {
                    if record.sourceChanged || record.dataChanged { Text(L10n.string("正文或数据已在导出期间变化；此文件基于开始时的快照。")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if exporter.taskFilesURL != nil {
                        Button(L10n.string("查看任务文件")) {
                            if let directory = exporter.taskFilesURL { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                        }.controlSize(.small)
                    }
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(exporter.log.isEmpty ? (panelError ?? exporter.diagnostic ?? L10n.string("尚无导出日志")) : exporter.log)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }.accessibilityIdentifier("quarto-log")
        }.padding(.horizontal, 20).padding(.bottom, 8)
    }
    private func begin() {
        do { _ = try options.metadata(); panelError = nil }
        catch { panelError = error.localizedDescription; return }
        guard let destination else { chooseDestination(); return }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let parent = exporter.window?.attachedSheet ?? exporter.window else { return }
            let alert = NSAlert(); alert.messageText = L10n.string("替换已有导出文件？")
            alert.informativeText = destination.path
            alert.addButton(withTitle: L10n.string("替换")); alert.addButton(withTitle: L10n.string("取消"))
            selectingDestination = true
            alert.beginSheetModal(for: parent) { response in
                selectingDestination = false
                if response == .alertFirstButtonReturn { exporter.start(options: options, destination: destination, overwrite: true) }
            }
        } else { exporter.start(options: options, destination: destination, overwrite: false) }
    }
    private func chooseDestination() {
        let panel = NSSavePanel(); panel.title = L10n.string("输出位置")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: options.format.fileExtension) ?? .data]
        panel.directoryURL = destination?.deletingLastPathComponent() ?? model.documentURL?.deletingLastPathComponent()
        let name = model.documentURL?.deletingPathExtension().lastPathComponent ?? "report"
        panel.nameFieldStringValue = destination?.lastPathComponent ?? name + "." + options.format.fileExtension
        selectingDestination = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            selectingDestination = false
            if response == .OK, let url = panel.url { destination = url }
        }
        if let parent = exporter.window?.attachedSheet ?? exporter.window { panel.beginSheetModal(for: parent, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

/// AppKit draws the top tabs and their continuous frame as one native control.
@MainActor private struct QuartoParameterTabs<Content: View>: NSViewRepresentable {
    @Binding var selection: Int
    let titles: [String]
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTabView {
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: 11)
        tabs.setAccessibilityIdentifier("quarto-custom-section")
        for (index, title) in titles.enumerated() {
            let item = NSTabViewItem(identifier: index)
            item.label = title; item.view = NSView()
            tabs.addTabViewItem(item)
        }
        tabs.delegate = context.coordinator
        return tabs
    }
    func updateNSView(_ tabs: NSTabView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self; coordinator.updating = true
        defer { coordinator.updating = false }
        for (index, title) in titles.enumerated() { tabs.tabViewItem(at: index).label = title }
        let index = min(max(0, selection), titles.count - 1)
        if tabs.indexOfTabViewItem(tabs.selectedTabViewItem ?? tabs.tabViewItem(at: index)) != index {
            tabs.selectTabViewItem(at: index)
        }
        coordinator.host.rootView = AnyView(content())
        coordinator.attach(to: tabs.tabViewItem(at: index))
    }
    @MainActor final class Coordinator: NSObject, NSTabViewDelegate {
        var parent: QuartoParameterTabs
        var updating = false
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        init(_ parent: QuartoParameterTabs) {
            self.parent = parent; super.init()
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
        }
        func attach(to item: NSTabViewItem) {
            guard let container = item.view, host.superview !== container else { return }
            host.removeFromSuperview(); container.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                host.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
            ])
        }
        func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
            guard !updating, let index = tabViewItem?.identifier as? Int else { return }
            parent.selection = index
        }
    }
}
