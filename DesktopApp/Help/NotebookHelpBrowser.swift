import AppKit
import Combine
import SwiftUI

struct NotebookHelpLocation: Equatable {
    var topic: NotebookHelpTopic
    var blockID: Int?
}

final class NotebookHelpOutlineNode: NSObject {
    let location: NotebookHelpLocation
    let title: String
    let children: [NotebookHelpOutlineNode]
    var id: String { location.topic.rawValue + ":" + (location.blockID.map(String.init) ?? "top") }
    init(location: NotebookHelpLocation, title: String, children: [NotebookHelpOutlineNode] = []) {
        self.location = location; self.title = title; self.children = children
    }
}

/// Entirely local help navigation. Reading/searching never touches a document or R.
@MainActor final class NotebookHelpBrowserModel: ObservableObject {
    @Published private(set) var location = NotebookHelpLocation(topic: .overview)
    @Published private(set) var roots: [NotebookHelpOutlineNode] = []
    @Published private(set) var revision = 0
    private(set) var query = ""
    private(set) var articles: [NotebookHelpTopic: [NotebookHelpGuideBlock]] = [:]
    private var sources: [NotebookHelpTopic: String] = [:]
    private var history = [NotebookHelpLocation(topic: .overview)]
    private var historyIndex = 0
    private let bundle: Bundle
    private var languageChanges: AnyCancellable?
    var blocks: [NotebookHelpGuideBlock] { articles[location.topic] ?? [] }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }

    init(language: LanguageSettings, bundle: Bundle) throws {
        self.bundle = bundle
        try load(language.language)
        languageChanges = language.$language.dropFirst().sink { [weak self] value in
            Task { @MainActor in try? self?.load(value) }
        }
    }
    private func load(_ language: AppLanguage) throws {
        var loaded: [NotebookHelpTopic: [NotebookHelpGuideBlock]] = [:], text: [NotebookHelpTopic: String] = [:]
        for topic in NotebookHelpTopic.allCases {
            let content = try NotebookHelpContent.load(topic, language: language, bundle: bundle)
            loaded[topic] = NotebookHelpGuideBlock.parse(content.markdown); text[topic] = content.markdown
        }
        articles = loaded; sources = text; rebuildOutline(); revision += 1
    }
    func navigate(_ destination: NotebookHelpLocation) {
        guard destination != location else { return }
        history.removeSubrange((historyIndex + 1)..<history.count)
        history.append(destination); historyIndex = history.count - 1
        location = destination
    }
    func back() { guard canGoBack else { return }; historyIndex -= 1; location = history[historyIndex] }
    func forward() { guard canGoForward else { return }; historyIndex += 1; location = history[historyIndex] }
    func search(_ value: String) { query = value; rebuildOutline() }
    private func rebuildOutline() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ text: String) -> Bool { text.localizedStandardContains(term) }
        roots = NotebookHelpTopic.allCases.compactMap { topic in
            let blocks = articles[topic] ?? []
            let headingIndices = blocks.indices.filter { if case .heading(2) = blocks[$0].kind { return true }; return false }
            let title = blocks.first?.text ?? topic.title
            let titleMatches = term.isEmpty || matches(title)
            let children = headingIndices.enumerated().compactMap { offset, index -> NotebookHelpOutlineNode? in
                let end = offset + 1 < headingIndices.count ? headingIndices[offset + 1] : blocks.count
                let section = blocks[index..<end].map { $0.text + $0.rows.flatMap { $0 }.joined(separator: " ") }.joined(separator: "\n")
                guard titleMatches || matches(section) else { return nil }
                return .init(location: .init(topic: topic, blockID: blocks[index].id), title: blocks[index].text)
            }
            guard titleMatches || !children.isEmpty || matches(sources[topic] ?? "") else { return nil }
            return .init(location: .init(topic: topic), title: title, children: children)
        }
    }
}

@MainActor final class NotebookHelpBrowserWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    let model: NotebookHelpBrowserModel
    let split = NSSplitViewController()
    private let sidebar: NotebookHelpOutlineController
    private let search = NSSearchField()
    private var placement: NotebookWindowPlacement?
    private var changes: AnyCancellable?
    private let openSystem: (NotebookHelpTopic) -> Void
    private var toolbarItems: [String: NSToolbarItem] = [:]

    init(language: LanguageSettings, behavior: DocumentBehaviorSettings, bundle: Bundle, openSystem: @escaping (NotebookHelpTopic) -> Void) throws {
        model = try NotebookHelpBrowserModel(language: language, bundle: bundle)
        sidebar = NotebookHelpOutlineController(model: model)
        self.openSystem = openSystem
        let host = NSHostingController(rootView: NotebookHelpBrowserArticle(model: model).appAppearance(NotebookPreferences.appearance))
        let left = NSSplitViewItem(sidebarWithViewController: sidebar)
        left.minimumThickness = 200; left.maximumThickness = 350; left.preferredThicknessFraction = 0.25
        left.allowsFullHeightLayout = true
        split.addSplitViewItem(left); split.addSplitViewItem(NSSplitViewItem(viewController: host))
        let window = NSWindow(contentViewController: split)
        window.title = L10n.string("Rnotebook 帮助"); window.setContentSize(NSSize(width: 960, height: 720))
        window.minSize = NSSize(width: 700, height: 450); window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false; window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView); window.titlebarAppearsTransparent = false
        window.setAccessibilityIdentifier("notebook-help-browser")
        super.init(window: window); shouldCascadeWindows = false
        window.center()
        search.delegate = self; search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        search.setAccessibilityIdentifier("help-search")
        let toolbar = NSToolbar(identifier: "notebook-help-toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unified
        placement = NotebookWindowPlacement(window: window, behavior: behavior) { "window.help.browser" }
        changes = model.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ topic: NotebookHelpTopic? = nil) {
        if let topic { model.search(""); search.stringValue = ""; model.navigate(.init(topic: topic)) }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func focusSearch() {
        if split.splitViewItems[0].isCollapsed { split.splitViewItems[0].isCollapsed = false }
        window?.makeFirstResponder(search)
    }
    func controlTextDidChange(_ notification: Notification) { model.search(search.stringValue) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The sidebar toggle sits at the right edge of the outline panel, just
        // past the tracking separator, rather than in the window's far corner.
        [.sidebarTrackingSeparator, .toggleSidebar, .init("help-history"), .init("help-home"), .init("help-title"), .flexibleSpace, .init("help-system"), .init("help-search")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .sidebarTrackingSeparator { return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0) }
        if id == .toggleSidebar {
            let item = makeButton(id.rawValue, "显示或隐藏目录", "sidebar.left", #selector(toggleContents(_:)))
            return item
        }
        if id.rawValue == "help-title" {
            let item = NSToolbarItem(itemIdentifier: id)
            let label = NSTextField(labelWithString: L10n.string("Rnotebook 帮助"))
            label.font = .systemFont(ofSize: 13, weight: .semibold); label.setAccessibilityIdentifier("help-window-title")
            item.view = label; item.visibilityPriority = .low; toolbarItems[id.rawValue] = item; return item
        }
        if id.rawValue == "help-search" {
            let item = NSSearchToolbarItem(itemIdentifier: id); item.searchField = search
            item.visibilityPriority = .high; toolbarItems[id.rawValue] = item; return item
        }
        if id.rawValue == "help-history" {
            let group = NSToolbarItemGroup(itemIdentifier: id); group.isBordered = true; group.controlRepresentation = .expanded
            group.subitems = [makeButton("help-back", "上一页", "chevron.backward", #selector(back(_:))), makeButton("help-forward", "下一页", "chevron.forward", #selector(forward(_:)))]
            return group
        }
        if id.rawValue == "help-home" { return makeButton(id.rawValue, "帮助首页", "house", #selector(home(_:))) }
        if id.rawValue == "help-system" { return makeButton(id.rawValue, "在提示中打开", "questionmark.circle", #selector(systemHelp(_:))) }
        return nil
    }
    private func makeButton(_ id: String, _ title: String.LocalizationValue, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init(id)); item.label = L10n.string(title); item.toolTip = item.label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.target = self; item.action = action; item.autovalidates = false
        toolbarItems[id] = item; return item
    }
    private func refresh() {
        window?.title = L10n.string("Rnotebook 帮助")
        (toolbarItems["help-title"]?.view as? NSTextField)?.stringValue = L10n.string("Rnotebook 帮助")
        search.placeholderString = L10n.string("搜索帮助")
        for (id, title) in [("help-back", String.LocalizationValue("上一页")), ("help-forward", "下一页"), ("help-home", "帮助首页"), ("help-system", "在提示中打开"), (NSToolbarItem.Identifier.toggleSidebar.rawValue, "显示或隐藏目录")] {
            toolbarItems[id]?.label = L10n.string(title); toolbarItems[id]?.toolTip = L10n.string(title)
        }
        toolbarItems["help-back"]?.isEnabled = model.canGoBack; toolbarItems["help-forward"]?.isEnabled = model.canGoForward
    }
    @objc private func toggleContents(_ sender: Any?) { split.toggleSidebar(sender) }
    @objc private func back(_ sender: Any?) { model.back() }
    @objc private func forward(_ sender: Any?) { model.forward() }
    @objc private func home(_ sender: Any?) { model.search(""); search.stringValue = ""; model.navigate(.init(topic: .overview)) }
    @objc private func systemHelp(_ sender: Any?) { openSystem(model.location.topic) }
}

@MainActor private final class NotebookHelpOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let model: NotebookHelpBrowserModel
    let outline = NSOutlineView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var changes: AnyCancellable?
    private var refreshing = false
    init(model: NotebookHelpBrowserModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let material = NSVisualEffectView(); material.material = .sidebar; material.blendingMode = .behindWindow
        view = material
        let column = NSTableColumn(identifier: .init("help-topic")); column.resizingMask = .autoresizingMask
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
        outline.style = .sourceList; outline.rowSizeStyle = .default; outline.rowHeight = 28
        outline.backgroundColor = .clear; outline.focusRingType = .none; outline.dataSource = self; outline.delegate = self
        outline.setAccessibilityIdentifier("help-contents")
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        empty.alignment = .center; empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 12)
        empty.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(empty)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), empty.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40), empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)])
        changes = model.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }
    private func refresh() {
        guard isViewLoaded else { return }
        refreshing = true; defer { refreshing = false }
        let expanded = Set((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? NotebookHelpOutlineNode }.filter { outline.isItemExpanded($0) }.map(\.id))
        outline.reloadData()
        for root in model.roots where expanded.contains(root.id) || !model.query.isEmpty || root.location.topic == model.location.topic && model.location.blockID != nil { outline.expandItem(root) }
        let selected = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? NotebookHelpOutlineNode)?.location == model.location }
        if let selected { outline.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        else { outline.deselectAll(nil) }
        empty.stringValue = L10n.string("未找到相关帮助"); empty.isHidden = !model.roots.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? NotebookHelpOutlineNode)?.children.count ?? model.roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? NotebookHelpOutlineNode)?.children[index] ?? model.roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? NotebookHelpOutlineNode)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NotebookHelpOutlineNode else { return nil }
        let label = NSTextField(labelWithString: node.title); label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingTail
        label.toolTip = node.title; label.setAccessibilityIdentifier("help-topic-" + node.id)
        let cell = NSTableCellView(); cell.textField = label; cell.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, let node = outline.item(atRow: outline.selectedRow) as? NotebookHelpOutlineNode else { return }
        model.navigate(node.location)
    }
}

private struct NotebookHelpBrowserArticle: View {
    @ObservedObject var model: NotebookHelpBrowserModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Color.clear.frame(height: 1).id("article-top")
                    ForEach(model.blocks) { block in NotebookHelpBlockView(block: block).id(block.id) }
                    Divider().padding(.top, 20)
                    HStack(spacing: 18) {
                        ForEach(NotebookHelpExternal.allCases, id: \.rawValue) { link in Link(link.title, destination: link.url) }
                    }.font(.system(size: 12))
                }.font(.system(size: 13)).lineSpacing(3).padding(.horizontal, 42).padding(.vertical, 32)
                    .frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
                    .id(model.location.topic)
            }.background(Color(nsColor: .windowBackgroundColor)).modifier(HelpArticleScrollEdges()).accessibilityIdentifier("help-article")
                .id(model.location.topic.rawValue + (model.location.blockID == nil ? ":top" : ":section"))
                .onChange(of: model.location) { _, _ in scroll(proxy) }
                .onChange(of: model.revision) { _, _ in scroll(proxy) }
                .onAppear { scroll(proxy) }
        }.environment(\.openURL, OpenURLAction { url in
            if url.scheme == "https" { NSWorkspace.shared.open(url) }
            else if url.scheme == "rnotebook-help", url.host == "article", let topic = NotebookHelpTopic(rawValue: String(url.path.dropFirst())) { model.navigate(.init(topic: topic)) }
            return .handled
        })
    }
    private func scroll(_ proxy: ScrollViewProxy) {
        let destination = model.location
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            guard model.location == destination else { return }
            if let block = destination.blockID { proxy.scrollTo(block, anchor: UnitPoint(x: 0, y: 0.2)) }
        }
    }
}


private struct HelpArticleScrollEdges: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        // The native ScrollView owns toolbar safe-area avoidance and its edge
        // effect. Do not add a second inset or a handmade material overlay.
        if #available(macOS 26.0, *) { content.scrollEdgeEffectStyle(.soft, for: .top) }
        else { content }
    }
}
