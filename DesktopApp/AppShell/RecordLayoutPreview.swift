import AppKit
import Combine
import SwiftUI

/// Current Notebook source and result state. R execution is delegated to NotebookExecution.
@MainActor
final class RecordLayoutModel: ObservableObject {
    var requestRCompletion: (() -> Void)?
    @Published var source = "" { didSet { if !DocumentRevision.sameSource(oldValue, source) { persistPreviewDraft() } } }
    var documentURL: URL?
    weak var document: QMDDocument?
    var pendingViewState: DocumentViewState?
    @Published var windowTopInset: CGFloat = 0
    private var previewDraftURL: URL?
    let usesSampleOutputs: Bool
    private let notebookConfiguration: (() throws -> RuntimeConfiguration)?
    lazy var notebook = NotebookExecution(model: self, configuration: notebookConfiguration)
    lazy var exporter = RecordQuartoExporter(model: self)
    @Published var showingExport = false
    @Published var showingPackageInstall = false
    @Published var showingClearVariables = false
    var inspectorActionSession: UUID?
    @Published var helpSearchRequest = UUID()
    @Published var menuInsertion: RecordVisualPopover?
    var recordAssetsDirectory: URL?
    var notebookDirectory: URL? { documentURL?.deletingLastPathComponent() }
    @Published var outputRevision: UInt64 = 0
    weak var activeEditor: NSTextView?
    weak var visualToolbarCursorView: NSView?
    @Published var sourceOnly = false
    @Published var expandedOutputs: Set<String> = ["label:preview-data", "label:preview-summary"]
    @Published var notice: String?
    @Published private(set) var previewSaveStatus = L10n.string("尚未暂存")
    var fontSize: Double { get { visualSettings.bodySize } set { visualSettings.bodySize = newValue } }
    var visualFontName: String { get { visualSettings.bodyFont } set { visualSettings.bodyFont = newValue } }
    var visualCodeFontName: String { get { visualSettings.codeFont } set { visualSettings.codeFont = newValue } }
    var visualCodeFontSize: Double { get { visualSettings.codeSize } set { visualSettings.codeSize = newValue } }
    @Published var visualContext = RecordVisualContext()
    private(set) var visualSettings: VisualEditorSettings
    var visualDefaults: UserDefaults { visualSettings.defaults }
    private var visualSettingsChanges: AnyCancellable?
    private var languageChanges: AnyCancellable?
    var outputStates: [String: RecordOutputLayout.State] = [:]
    let visualBlocks = RecordVisualBlockIndex()
    var didSeedVisualOutputs = false
    @Published var packageQuery = ""
    @Published var helpQuery = ""

    init(previewDraftURL: URL? = nil, visualDefaults: UserDefaults = .standard, usesSampleOutputs: Bool = false, notebookConfiguration: (() throws -> RuntimeConfiguration)? = nil, initialSource: String? = nil, usesProcessArguments: Bool = true) {
        self.usesSampleOutputs = usesSampleOutputs
        self.notebookConfiguration = notebookConfiguration
        visualSettings = VisualEditorSettings(defaults: visualDefaults)
        let arguments = usesProcessArguments ? ProcessInfo.processInfo.arguments : []
        let draftArgument = arguments.first(where: { $0.hasPrefix("--preview-record-draft=") })
        self.previewDraftURL = previewDraftURL ?? draftArgument.map {
            URL(fileURLWithPath: String($0.dropFirst("--preview-record-draft=".count)))
        }
        if let url = self.previewDraftURL, let draft = try? String(contentsOf: url, encoding: .utf8) { source = draft }
        if let argument = arguments.first(where: { $0.hasPrefix("--preview-record-source=") }) {
            let path = String(argument.dropFirst("--preview-record-source=".count))
            if let draft = try? String(contentsOfFile: path, encoding: .utf8) { source = draft }
        }
        if arguments.contains("--record-simple-document") {
            source = L10n.string("# 分析记录\n\n原生编辑器界面评审，未连接 R。\n\n```{r}\n#| label: preview-data\nhead(data1)\n```\n")
        }
        if let initialSource { source = initialSource }
        persistPreviewDraft()
        observeVisualSettings()
        languageChanges = NotificationCenter.default.publisher(for: .notebookLanguageChanged).sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    func mirrorDraft(to url: URL?) {
        previewDraftURL = url
        persistPreviewDraft()
    }

    func useVisualSettings(_ settings: VisualEditorSettings) {
        guard visualSettings !== settings else { return }
        visualSettings = settings
        observeVisualSettings()
        objectWillChange.send()
    }

    private func observeVisualSettings() {
        visualSettingsChanges = visualSettings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func persistPreviewDraft() {
        guard let previewDraftURL else { return }
        do {
            try Data(source.utf8).write(to: previewDraftURL, options: .atomic)
            previewSaveStatus = L10n.string("本地已暂存")
        } catch {
            previewSaveStatus = L10n.string("暂存失败")
            notice = L10n.string("预览草稿暂存失败：") + error.localizedDescription
        }
    }

    func insert(_ text: String) {
        if let editor = activeEditor, editor.isEditable {
            guard !editor.hasMarkedText() else { notice = L10n.string("请先完成当前输入。"); return }
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            source += "\n" + text
        }
    }

    func preview(_ action: String) {
        notice = L10n.string("“\(String(action))”目前是界面评审入口，不会执行 R、渲染报告或更改包环境。")
    }
}

struct RecordEditorLayoutPreview: View {
    @ObservedObject var model: RecordLayoutModel
    @EnvironmentObject private var visualSettings: VisualEditorSettings
    @State private var activePopover: RecordVisualPopover?
    @State private var popoverOrigin = ""
    @State private var toolbarWidths: [String: CGFloat] = [:]
    @State private var hoveredToolbarEntry: String?

    var body: some View {
        GeometryReader { geometry in
            RecordNativeEditor(model: model)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .accessibilityIdentifier("record-native-host")
                .overlay(alignment: .top) {
                    if !model.sourceOnly {
                        let contentWidth = max(0, geometry.size.width - RecordNavigationGeometry.width(for: geometry.size.width))
                        editingToolbar
                            .frame(width: min(max(0, contentWidth - 32), preferredToolbarWidth))
                            .frame(width: contentWidth)
                            .frame(width: geometry.size.width, alignment: .leading)
                            .padding(.top, model.windowTopInset + RecordVisualToolbarGeometry.topGap)
                    }
                }
        }
        .alert(L10n.string("提示"), isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button(L10n.string("好")) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .sheet(item: $model.menuInsertion) { request in
            VStack(alignment: .leading, spacing: 12) {
                switch request {
                case .table(let anchor): RecordVisualTableInsertion(model: model, anchor: anchor) { model.menuInsertion = nil }
                case .image(let anchor): RecordVisualImageInsertion(model: model, anchor: anchor) { model.menuInsertion = nil }
                }
                Button(L10n.string("取消")) { model.menuInsertion = nil }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .onAppear { model.useVisualSettings(visualSettings) }
        .modifier(QMDSynchronizationOverlay(model: model))
    }

    private var preferredToolbarWidth: CGFloat {
        let entries = RecordVisualToolbarEntry.ordered
        return entries.reduce(CGFloat(24)) { $0 + (toolbarWidths[$1.id] ?? $1.estimatedWidth) }
            + CGFloat(max(0, entries.count - 1)) * 4
    }

    private var popoverArrowEdge: Edge {
        if case .table = activePopover { return .bottom }
        return .top
    }

    private var editingToolbar: some View {
        GeometryReader { geometry in
            let entries = RecordVisualToolbarEntry.ordered
            let widths = entries.map { toolbarWidths[$0.id] ?? $0.estimatedWidth }
            let visibleCount = RecordVisualToolbarGeometry.visibleCount(widths: widths, available: geometry.size.width,
                                                                         moreWidth: toolbarWidths["overflow"] ?? 28)
            HStack(spacing: 4) {
                ForEach(Array(entries.prefix(visibleCount))) { entry in
                    toolbarEntry(entry)
                        .fixedSize()
                        .background(GeometryReader { item in
                            Color.clear.preference(key: RecordVisualToolbarWidths.self, value: [entry.id: item.size.width])
                        })
                }
                if visibleCount < entries.count {
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(Array(entries.dropFirst(visibleCount))) { entry in
                            switch entry.kind {
                            case .command(let tool): menuCommand(tool)
                            case .table: Button(entry.title) { openTableInsertion(origin: "overflow") }
                            default:
                                Menu(entry.title) { menuContents(entry, origin: "overflow") }
                            }
                        }
                    } label: {
                        Image(nsImage: menuSymbolImage("ellipsis", color: hoveredToolbarEntry == "overflow" ? .controlAccentColor : .labelColor))
                            .renderingMode(.original).frame(width: 26, height: 26)
                    }
                    .menuIndicator(.hidden)
                    .background(RecordToolbarHoverRegion { setToolbarHover("overflow", entered: $0) })
                    .help(L10n.string("更多工具")).accessibilityLabel(L10n.string("更多工具")).accessibilityIdentifier("visual-overflow")
                    .popover(item: popoverBinding(for: "overflow"), arrowEdge: popoverArrowEdge) { popoverContents($0) }
                    .fixedSize()
                    .background(GeometryReader { item in
                        Color.clear.preference(key: RecordVisualToolbarWidths.self, value: ["overflow": item.size.width])
                    })
                }
            }
            .frame(width: geometry.size.width, height: RecordVisualToolbarGeometry.height, alignment: .center)
        }
        .frame(height: RecordVisualToolbarGeometry.height)
        .menuStyle(.borderlessButton).buttonStyle(.borderless)
        .tint(.primary).foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .modifier(RecordFloatingToolbarMaterial())
        .background(RecordToolbarCursorRegion(model: model))
        .contentShape(Capsule())
        .onPreferenceChange(RecordVisualToolbarWidths.self) { values in
            for (id, width) in values where abs((toolbarWidths[id] ?? 0) - width) > 0.5 { toolbarWidths[id] = width }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-editing-toolbar")
        .onDisappear { hoveredToolbarEntry = nil }
    }

    @ViewBuilder private func toolbarEntry(_ entry: RecordVisualToolbarEntry) -> some View {
        switch entry.kind {
        case .command(let tool): toolButton(tool)
        case .table:
            Button { openTableInsertion(origin: entry.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: entry.symbol).frame(width: 20, height: 20)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.frame(width: 40, height: 26)
                    .foregroundStyle(toolbarColor(entry.id))
            }
                .help(entry.title).accessibilityLabel(entry.title).accessibilityIdentifier("visual-table")
                .onHover { setToolbarHover(entry.id, entered: $0) }
                .popover(item: popoverBinding(for: entry.id), arrowEdge: popoverArrowEdge) { popoverContents($0) }
        default:
            Menu { menuContents(entry) } label: {
                menuIcon(entry)
            }
            .menuIndicator(.hidden)
            .frame(height: 26)
            .help(entry.title).accessibilityLabel(entry.title).accessibilityIdentifier("visual-" + entry.id)
            .accessibilityValue(entry.id == "paragraph" ? (model.visualContext.heading == 0 ? L10n.string("正文") : L10n.string("标题 \(String(model.visualContext.heading))")) : "")
            .background(RecordToolbarHoverRegion { setToolbarHover(entry.id, entered: $0) })
            .popover(item: popoverBinding(for: entry.id), arrowEdge: popoverArrowEdge) { popoverContents($0) }
        }
    }

    @ViewBuilder private func menuContents(_ entry: RecordVisualToolbarEntry, origin: String? = nil) -> some View {
        if case .paragraph = entry.kind {
            Picker("", selection: Binding(get: { model.visualContext.heading }, set: { model.format(.heading($0)) })) {
                ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { level in
                    Text(level == 0 ? L10n.string("正文") : "H\(level)")
                    .tag(level)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } else if case .image = entry.kind {
            Button(L10n.string("导入图片")) { model.format(.attachImage) }
            Button(L10n.string("链接插入")) {
                if let anchor = model.captureVisualInsertion(for: .imageReference) {
                    popoverOrigin = origin ?? entry.id; activePopover = .image(anchor)
                }
            }
        } else if case .other = entry.kind {
            ForEach(Array(entry.otherGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group) { tool in menuCommand(tool) }
            }
        } else {
            ForEach(entry.commands) { tool in menuCommand(tool) }
        }
    }

    private func openTableInsertion(origin: String) {
        if let anchor = model.captureVisualInsertion(for: .table) {
            popoverOrigin = origin; activePopover = .table(anchor)
        }
    }

    private func popoverBinding(for origin: String) -> Binding<RecordVisualPopover?> {
        Binding(get: { popoverOrigin == origin ? activePopover : nil },
                set: { if popoverOrigin == origin { activePopover = $0 } })
    }

    @ViewBuilder private func popoverContents(_ request: RecordVisualPopover) -> some View {
        switch request {
        case .table(let anchor): RecordVisualTableInsertion(model: model, anchor: anchor) { activePopover = nil }
        case .image(let anchor): RecordVisualImageInsertion(model: model, anchor: anchor) { activePopover = nil }
        }
    }

    private func menuCommand(_ tool: RecordVisualTool) -> some View {
        Button { model.format(tool.command) } label: {
            Label(tool.title, systemImage: model.visualContext.activeActions.contains(tool.command.selector) ? "checkmark" : tool.symbol)
        }
    }

    private func toolButton(_ tool: RecordVisualTool) -> some View {
        let active = model.visualContext.activeActions.contains(tool.command.selector)
        return Button { model.format(tool.command) } label: {
            Image(systemName: tool.symbol)
                .foregroundStyle(toolbarColor(tool.id))
                .frame(width: 26, height: 26)
                .background(active ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .help(tool.title).accessibilityLabel(tool.title)
        .accessibilityValue(active ? L10n.string("已应用") : L10n.string("未应用"))
        .accessibilityIdentifier("visual-" + tool.id)
        .onHover { setToolbarHover(tool.id, entered: $0) }
    }

    private func toolbarColor(_ id: String) -> Color {
        return hoveredToolbarEntry == id ? .accentColor : .primary
    }
    private func menuIcon(_ entry: RecordVisualToolbarEntry) -> some View {
        // Native borderless menus template SwiftUI symbol/text labels. Supply
        // an original-color image so their existing layout can retain tint.
        let color: NSColor = hoveredToolbarEntry == entry.id ? .controlAccentColor : .labelColor
        let image: NSImage
        if case .paragraph = entry.kind {
            image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
                let title = NSAttributedString(string: "H", attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: color])
                let size = title.size()
                title.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
                return true
            }
        } else {
            image = menuSymbolImage(entry.symbol, color: color)
        }
        image.isTemplate = false
        let arrow = menuSymbolImage("chevron.down", color: color,
                                    configuration: .init(pointSize: 9, weight: .semibold))
        let label = NSImage(size: NSSize(width: 31, height: 20), flipped: false) { _ in
            func fit(_ image: NSImage, in rect: NSRect) {
                let scale = min(1, rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
            fit(image, in: NSRect(x: 0, y: 0, width: 20, height: 20))
            fit(arrow, in: NSRect(x: 24, y: 0, width: 7, height: 20))
            return true
        }
        label.isTemplate = false
        return Image(nsImage: label).renderingMode(.original).frame(width: 31, height: 20)
    }
    private func menuSymbolImage(_ name: String, color: NSColor, configuration: NSImage.SymbolConfiguration? = nil) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 20, height: 20))
        let symbol = configuration.flatMap { base.withSymbolConfiguration($0) } ?? base
        // A symbol configuration still gets re-templated by the native menu.
        // Draw an ordinary original-color image, retaining the symbol's size.
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            guard let graphics = NSGraphicsContext.current else { return false }
            NSGraphicsContext.saveGraphicsState()
            graphics.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: rect)
            color.setFill(); rect.fill(using: .sourceIn)
            graphics.cgContext.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }
    private func setToolbarHover(_ id: String, entered: Bool) {
        if entered { hoveredToolbarEntry = id }
        else if hoveredToolbarEntry == id { hoveredToolbarEntry = nil }
    }
}

private struct RecordFloatingToolbarMaterial: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
        }
    }
}

extension RecordLayoutModel {
    static func fixtureHash(label: String?) -> String? {
        guard let label, ["preview-data", "preview-summary"].contains(label) else { return nil }
        let source = label == "preview-data" ? "#| label: preview-data\nhead(data1)\n" : "#| label: preview-summary\nsummary(data1)\n"
        return DocumentRevision(text: source).rawValue
    }
}
