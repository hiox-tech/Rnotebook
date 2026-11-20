import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordPackageInstallSheet: View {
    @ObservedObject var model: RecordLayoutModel
    @ObservedObject var session: NotebookExecution
    @Environment(\.dismiss) private var dismiss
    @State private var spec: NotebookPackageInstallation
    @State private var query = ""
    @State private var candidates: [String] = []
    @State private var selected: [String] = []
    @State private var mirrors = InspectorMirrorCatalog.bundled
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchLog = ""
    @State private var submitted = false
    @State private var showingLog = false

    init(model: RecordLayoutModel, session: NotebookExecution) {
        self.model = model; self.session = session
        _spec = State(initialValue: .init(repository: InspectorCRANMirror.repositoryKey(session.inspectorSnapshot?.repositories.first ?? "https://cloud.r-project.org"), library: session.inspectorSnapshot?.installLibrary ?? NotebookLibrary.selected(defaults: model.visualDefaults).path))
    }
    private var request: NotebookPackageInstallation {
        var value = spec
        value.library = session.inspectorSnapshot?.installLibrary ?? NotebookLibrary.selected(defaults: model.visualDefaults).path
        value.includeSuggested = false
        if value.source == .repository { value.packages = selected; value.files = [] }
        else { value.packages = [] }
        return value
    }
    private var valid: Bool { request.isValid && !session.isBusy && !session.needsRestart && !session.hasPendingRSelection }
    private var installing: Bool { submitted && session.isBusy }
    private var candidateKey: String { spec.source.rawValue + "\n" + spec.repository + "\n" + query }
    private var logText: String {
        if submitted { return session.inspectorLog.isEmpty ? (session.inspectorMessage ?? L10n.string("等待安装…")) : session.inspectorLog }
        return searchLog.isEmpty ? L10n.string("尚未开始安装") : searchLog
    }
    private var status: String {
        if submitted { return session.inspectorActivity ?? session.inspectorMessage ?? L10n.string("等待安装结果…") }
        if let searchError { return searchError }
        if searching { return L10n.string("正在搜索…") }
        return L10n.string("准备安装")
    }
    private var sheetHeight: CGFloat {
        (spec.source == .repository ? 194 : 164) + (showingLog ? (submitted || !searchLog.isEmpty ? 126 : 48) : 0)
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.string("安装 R 包")).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            VStack(spacing: 8) {
                row(L10n.string("安装来源")) {
                    Picker(L10n.string("安装来源"), selection: $spec.source) {
                        Text("CRAN").tag(NotebookPackageInstallation.Source.repository)
                        Text(L10n.string("本地")).tag(NotebookPackageInstallation.Source.local)
                    }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                        .accessibilityIdentifier("record-package-install-source")
                    Spacer(minLength: 0)
                }
                if spec.source == .repository {
                    row(L10n.string("CRAN 镜像")) {
                        Picker(L10n.string("CRAN 镜像"), selection: $spec.repository) {
                            ForEach(mirrors) { Text($0.name).tag($0.url) }
                            if !mirrors.contains(where: { $0.url == spec.repository }) {
                                Text(L10n.string("当前仓库")).tag(spec.repository)
                            }
                        }.labelsHidden().frame(width: 330, alignment: .leading).help(spec.repository)
                            .accessibilityIdentifier("record-package-install-repository")
                        Spacer(minLength: 0)
                    }
                    row(L10n.string("R 包")) {
                        PackageSearchField(query: $query, candidates: candidates, choose: choosePackage)
                            .frame(width: 220, height: 22)
                        Menu {
                            ForEach(selected, id: \.self) { name in
                                Button(name, systemImage: "minus.circle") { selected.removeAll { $0 == name } }
                            }
                        } label: {
                            Text(selected.count == 1 ? selected[0] : L10n.string("已选 \(String(selected.count)) 个包"))
                                .lineLimit(1).truncationMode(.middle)
                        }.disabled(selected.isEmpty).frame(width: 138, alignment: .leading)
                            .help(selected.joined(separator: ", "))
                            .accessibilityIdentifier("record-package-install-selected")
                        Spacer(minLength: 0)
                    }
                } else {
                    row(L10n.string("本地文件")) {
                        Text(spec.files.isEmpty ? L10n.string("未选择文件") : spec.files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                            .lineLimit(1).truncationMode(.middle).help(spec.files.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("record-package-install-file-selection")
                        Button(L10n.string("选择…"), action: chooseFiles).accessibilityIdentifier("record-package-install-files")
                    }
                }
            }.padding(.horizontal, 20).font(.system(size: 12)).controlSize(.small)
                .disabled(session.isBusy)
            Spacer(minLength: 12)
            if showingLog {
                VStack(spacing: 6) {
                    Divider()
                    ScrollView([.vertical, .horizontal]) {
                        Text(logText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }.accessibilityIdentifier("record-package-install-log")
                }.padding(.horizontal, 20).padding(.bottom, 8)
                    .frame(height: submitted || !searchLog.isEmpty ? 118 : 40)
            }
            Divider()
            HStack(spacing: 12) {
                Button {
                    showingLog.toggle()
                } label: {
                    Label(L10n.string("日志"), systemImage: showingLog ? "chevron.up" : "chevron.down")
                }.buttonStyle(.borderless).accessibilityIdentifier("record-package-install-toggle-log")
                HStack(spacing: 6) {
                    if installing || searching { ProgressView().controlSize(.small) }
                    Text(status).font(.system(size: 11)).lineLimit(1).help(status)
                        .foregroundStyle(searchError != nil && !submitted ? Color.red : Color.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("record-package-install-status")
                Button(L10n.string("取消"), role: .cancel) {
                    if installing { session.interrupt() } else { dismiss() }
                }.disabled(installing && (session.isStopping || session.state == .interrupting))
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("record-package-install-cancel")
                Button(L10n.string("安装")) {
                    guard valid else { return }
                    submitted = true
                    session.manage(.init(operation: .installPackage, installation: request), expectedSession: session.sessionID)
                }.keyboardShortcut(.defaultAction).disabled(!valid).accessibilityIdentifier("record-package-install-confirm")
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(width: 540, height: sheetHeight, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(installing)
        .accessibilityElement(children: .contain).accessibilityIdentifier("record-package-install-sheet")
        .task { mirrors = await InspectorMirrorCatalog.shared.mirrors() }
        .task(id: candidateKey) {
            candidates = []; searching = false; searchError = nil
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard spec.source == .repository, term.count >= 2 else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            searching = true
            do {
                let values = try await InspectorPackageCatalog.shared.search(term, repository: spec.repository)
                guard !Task.isCancelled else { return }
                candidates = values; searching = false
            } catch {
                guard !Task.isCancelled else { return }
                searching = false; searchError = L10n.string("包列表读取失败")
                searchLog = error.localizedDescription
            }
        }
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            content()
        }.frame(minHeight: 22)
    }
    private func choosePackage(_ text: String) {
        let names = NotebookPackageInstallation.names(text)
        var combined = selected
        for name in names where !combined.contains(name) { combined.append(name) }
        var proposed = request; proposed.packages = combined; proposed.files = []
        guard !names.isEmpty else { return }
        guard proposed.isValid else {
            searchError = L10n.string("请输入有效包名，最多选择20个包。")
            return
        }
        selected = combined; query = ""; candidates = []; searchError = nil
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "gz"), UTType(filenameExtension: "tgz")].compactMap { $0 }
        if let window = session.window?.attachedSheet ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window) { result in
                guard result == .OK else { return }
                let files = panel.urls.map(\.path)
                var proposed = request; proposed.files = files
                guard proposed.isValid else {
                    searchError = L10n.string("请选择最多20个 .tar.gz 或 .tgz 安装包。")
                    return
                }
                spec.files = files; searchError = nil
            }
        }
    }
}

private struct PackageSearchField: NSViewRepresentable {
    @Binding var query: String
    let candidates: [String]
    let choose: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> PackageSearchContainer {
        let container = PackageSearchContainer()
        let field = NSTextField()
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 11); field.controlSize = .small
        field.focusRingType = .default
        field.lineBreakMode = .byClipping; field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.placeholderString = L10n.string("搜索或输入包名")
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("record-package-install-name")
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field); container.nextKeyView = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.field = field
        return container
    }
    func updateNSView(_ container: PackageSearchContainer, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        if let field = coordinator.field, field.stringValue != query { field.stringValue = query }
        coordinator.refresh()
    }
    static func dismantleNSView(_ container: PackageSearchContainer, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
        var parent: PackageSearchField
        weak var field: NSTextField?
        private var items: [String] = []
        private let table = NSTableView()
        private let panel = PackageSuggestionsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        private var monitor: Any?
        private var windowObserver: NSObjectProtocol?
        private var suppressedQuery: String?
        init(_ parent: PackageSearchField) {
            self.parent = parent; super.init()
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.hidesOnDeactivate = true; panel.becomesKeyOnlyIfNeeded = true; panel.worksWhenModal = true
            panel.isReleasedWhenClosed = false
            panel.setAccessibilityIdentifier("record-package-search-results")
            let background = NSVisualEffectView()
            background.material = .popover; background.blendingMode = .withinWindow; background.state = .active
            background.wantsLayer = true; background.layer?.cornerRadius = 6; background.layer?.masksToBounds = true
            let scroll = NSScrollView(); scroll.drawsBackground = false
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            table.headerView = nil; table.rowHeight = 22; table.intercellSpacing = .zero
            table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
            table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(pick(_:))
            let column = NSTableColumn(identifier: .init("package")); column.resizingMask = .autoresizingMask
            table.addTableColumn(column); table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.setAccessibilityIdentifier("record-package-search-list")
            scroll.documentView = table
            background.addSubview(scroll); panel.contentView = background
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
                scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
                scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
                scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4)
            ])
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            suppressedQuery = nil; parent.query = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) { suppressedQuery = nil; refresh() }
        func controlTextDidEndEditing(_ notification: Notification) { hide() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
                guard !items.isEmpty else { return false }
                suppressedQuery = nil; refresh()
                let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
                let row = table.selectedRow < 0 ? (delta > 0 ? 0 : items.count - 1) : min(max(0, table.selectedRow + delta), items.count - 1)
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let name = panel.isVisible && items.indices.contains(table.selectedRow) ? items[table.selectedRow] : items.first ?? parent.query
                commit(name); return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), panel.isVisible {
                suppressedQuery = parent.query; hide(); return true
            }
            return false
        }
        func refresh() {
            guard let field, let window = field.window, field.currentEditor() != nil,
                  !parent.query.isEmpty, parent.query != suppressedQuery, !parent.candidates.isEmpty else { hide(); return }
            if items != parent.candidates { items = parent.candidates; table.reloadData(); table.deselectAll(nil) }
            let bounds = window.convertToScreen(field.convert(field.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let width = max(220, bounds.width), height = CGFloat(min(items.count, 8)) * 22 + 8
            let x = min(max(bounds.minX, screen.minX + 4), screen.maxX - width - 4)
            let y = bounds.minY - height - 3 >= screen.minY ? bounds.minY - height - 3 : bounds.maxY + 3
            panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
            if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
            if !panel.isVisible { panel.orderFront(nil) }
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self, event.window !== self.panel else { return event }
                    if let field = self.field, event.window === field.window, field.convert(field.bounds, to: nil).contains(event.locationInWindow) { return event }
                    self.hide(); return event
                }
                windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hide() }
                }
            }
        }
        private func hide() {
            panel.orderOut(nil)
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        }
        func close() { hide(); panel.parent?.removeChildWindow(panel); panel.close() }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let label = NSTextField(labelWithString: items[row])
            label.font = .systemFont(ofSize: 11); label.lineBreakMode = .byTruncatingTail
            label.toolTip = items[row]
            return label
        }
        @objc private func pick(_ sender: NSTableView) {
            guard items.indices.contains(sender.clickedRow) else { return }
            commit(items[sender.clickedRow])
        }
        private func commit(_ name: String) {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            suppressedQuery = parent.query; hide(); parent.choose(name)
        }
    }
}

@MainActor private final class PackageSuggestionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Give AppKit a quiet initial responder instead of selecting the first editable field.
/// The field remains normally focusable by mouse and keyboard.
@MainActor private final class PackageSearchContainer: NSView {
    override var acceptsFirstResponder: Bool { true }
    private weak var configuredWindow: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configuredWindow !== window else { return }
        configuredWindow = window
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }
}
