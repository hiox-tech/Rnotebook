import AppKit
import Combine
import SwiftUI

/// Local native help browser, with an optional standard Apple Help route.
/// The two short topic guides are separate native windows, like Notes' guides.
@MainActor final class NotebookHelpCenter {
    static let folder = "Rnotebook.help"
    private let language: LanguageSettings
    private let behavior: DocumentBehaviorSettings
    private let resourceBundle: Bundle
    private let registerBook: (Bundle) -> Bool
    private let openAnchor: (String, String) -> Void
    private let reportError: (Error) -> Void
    private var languageChanges: AnyCancellable?
    private(set) var browserWindow: NotebookHelpBrowserWindowController?
    private(set) var guideWindows: [NotebookHelpTopic: NSWindowController] = [:]

    init(language: LanguageSettings = NotebookPreferences.language, behavior: DocumentBehaviorSettings = NotebookPreferences.documents,
         bundle: Bundle = .main, registerBook: @escaping (Bundle) -> Bool = { NSHelpManager.shared.registerBooks(in: $0) },
         openAnchor: @escaping (String, String) -> Void = { NSHelpManager.shared.openHelpAnchor($0, inBook: $1) },
         reportError: @escaping (Error) -> Void = { NSApp.presentError($0) }) {
        self.language = language; self.behavior = behavior; resourceBundle = bundle
        self.registerBook = registerBook; self.openAnchor = openAnchor; self.reportError = reportError
        languageChanges = language.$language.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.refreshGuides() }
        }
    }
    func showHome() { showDetailed() }
    func showDetailed(_ topic: NotebookHelpTopic? = nil) {
        do {
            if browserWindow == nil {
                browserWindow = try NotebookHelpBrowserWindowController(language: language, behavior: behavior, bundle: resourceBundle, openSystem: { [weak self] in self?.openInSystemHelp($0) })
            }
            browserWindow?.show(topic)
        } catch { reportError(error) }
    }
    func showArticle(_ topic: NotebookHelpTopic) {
        guard topic == .quickStart || topic == .syntax else { showDetailed(topic); return }
        do {
            if guideWindows[topic] == nil {
                let model = try NotebookHelpGuideModel(topic: topic, language: language.language, bundle: resourceBundle)
                model.observe(language)
                let host = NSHostingController(rootView: NotebookHelpGuideView(model: model, learnMore: { [weak self] in self?.showDetailed(topic) }, openArticle: { [weak self] in self?.showDetailed($0) })
                    .appAppearance(NotebookPreferences.appearance))
                guideWindows[topic] = NotebookHelpGuideWindowController(content: host, topic: topic, behavior: behavior)
            }
            guideWindows[topic]?.showWindow(nil); guideWindows[topic]?.window?.makeKeyAndOrderFront(nil)
        } catch { reportError(error) }
    }
    func openInSystemHelp(_ topic: NotebookHelpTopic?) {
        do {
            guard let name = resourceBundle.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String,
                  !name.isEmpty, resourceBundle.object(forInfoDictionaryKey: "CFBundleHelpBookFolder") as? String == Self.folder,
                  let root = resourceBundle.resourceURL,
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.folder).appendingPathComponent("Contents/Info.plist").path),
                  registerBook(resourceBundle) else {
                throw NSError(domain: "Rnotebook", code: 12, userInfo: [NSLocalizedDescriptionKey: L10n.string("系统帮助暂时无法打开，请重新打开应用后重试。")])
            }
            openAnchor("rnotebook-" + (topic?.rawValue ?? "home"), name)
        } catch { reportError(error) }
    }
    private func refreshGuides() {
        for (topic, controller) in guideWindows {
            controller.window?.title = topic.title
        }
    }
}

@MainActor final class NotebookHelpGuideModel: ObservableObject {
    let topic: NotebookHelpTopic
    private let bundle: Bundle
    @Published private(set) var blocks: [NotebookHelpGuideBlock]
    private var changes: AnyCancellable?
    init(topic: NotebookHelpTopic, language: AppLanguage, bundle: Bundle) throws {
        self.topic = topic; self.bundle = bundle
        blocks = NotebookHelpGuideBlock.parse(try Self.load(topic, language: language, bundle: bundle))
    }
    func observe(_ language: LanguageSettings) {
        changes = language.$language.dropFirst().sink { [weak self] value in
            Task { @MainActor in
                guard let self, let content = try? Self.load(self.topic, language: value, bundle: self.bundle) else { return }
                self.blocks = NotebookHelpGuideBlock.parse(content)
            }
        }
    }
    static func load(_ topic: NotebookHelpTopic, language: AppLanguage, bundle: Bundle) throws -> String {
        guard topic == .quickStart || topic == .syntax, let root = bundle.resourceURL else { throw CocoaError(.fileReadNoSuchFile) }
        return try String(contentsOf: root.appendingPathComponent("Help/Guides/\(language.id)/\(topic.rawValue).md"), encoding: .utf8)
    }
}

@MainActor private final class NotebookHelpGuideWindowController: NSWindowController {
    private var placement: NotebookWindowPlacement?
    init(content: NSViewController, topic: NotebookHelpTopic, behavior: DocumentBehaviorSettings) {
        let window = NSWindow(contentViewController: content)
        window.title = topic.title; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 640, height: 740)); window.minSize = NSSize(width: 520, height: 460)
        window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("notebook-guide-" + topic.rawValue)
        super.init(window: window); shouldCascadeWindows = false
        window.center()
        placement = NotebookWindowPlacement(window: window, behavior: behavior) { "window.help.guide." + topic.rawValue }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct NotebookHelpGuideView: View {
    @ObservedObject var model: NotebookHelpGuideModel
    let learnMore: () -> Void
    let openArticle: (NotebookHelpTopic) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.blocks) { block in
                    NotebookHelpBlockView(block: block)
                }
                Button(L10n.string("进一步了解…"), action: learnMore).buttonStyle(.link).padding(.top, 18)
                    .accessibilityIdentifier("guide-learn-more")
            }.font(.system(size: 13)).lineSpacing(2).padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 38)
                .frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }.scrollBounceBehavior(.basedOnSize).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "https" { NSWorkspace.shared.open(url) }
                else if url.scheme == "rnotebook-help", url.host == "article",
                        let topic = NotebookHelpTopic(rawValue: String(url.path.dropFirst())) { openArticle(topic) }
                return .handled
            })
    }
}

struct NotebookHelpBlockView: View {
    let block: NotebookHelpGuideBlock
    @State private var showingImage = false
    var body: some View {
        switch block.kind {
        case .image(let path):
            if let url = NotebookHelpAsset.url(path), let image = NSImage(contentsOf: url) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { showingImage = true } label: {
                        Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(block.text)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help(L10n.string("放大截图"))
                        .accessibilityIdentifier("help-image-\(block.id)")
                        .sheet(isPresented: $showingImage) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(block.text).font(.system(size: 13)).textSelection(.enabled)
                                    Spacer()
                                    Button(L10n.string("关闭")) { showingImage = false }.keyboardShortcut(.cancelAction)
                                }
                                ScrollView([.horizontal, .vertical]) {
                                    Image(nsImage: image).resizable().frame(width: image.size.width, height: image.size.height)
                                        .accessibilityLabel(block.text)
                                }
                            }.padding(20).frame(width: 940, height: 680)
                        }
                    Text(block.text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        case .heading(let level):
            Text(block.text).font(.system(size: level == 1 ? 29 : 19, weight: .bold))
                .padding(.top, level == 1 ? 0 : 15).textSelection(.enabled)
        case .code:
            VStack(alignment: .leading, spacing: 6) {
                HStack { Spacer(); Button { copy(block.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L10n.string("复制示例")).accessibilityLabel(L10n.string("复制示例"))
                    .accessibilityIdentifier("guide-copy-\(block.id)") }
                ScrollView(.horizontal) { Text(block.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true) }
            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        case .table:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(block.rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, text in
                            richText(text).fontWeight(index == 0 ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 9)
                    if index < block.rows.count - 1 { Divider() }
                }
            }
        case .paragraph, .list: richText(block.text)
        }
    }
    private func richText(_ text: String) -> some View {
        let value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

