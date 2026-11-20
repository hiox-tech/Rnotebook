import AppKit
import SwiftUI

struct NotebookThirdPartyNotice: Decodable, Identifiable {
    let id, name, license, purpose, file: String
    static func load(bundle: Bundle = .main) throws -> [Self] {
        guard let root = bundle.resourceURL else { throw CocoaError(.fileReadNoSuchFile) }
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: root.appendingPathComponent("ThirdPartyNotices/index.json")))
    }
    func text(bundle: Bundle = .main) throws -> String {
        guard !file.contains("/"), !file.contains(".."), let root = bundle.resourceURL else { throw CocoaError(.fileReadNoSuchFile) }
        return try String(contentsOf: root.appendingPathComponent("ThirdPartyNotices/" + file), encoding: .utf8)
    }
}

@MainActor final class NotebookAboutController {
    private(set) var window: NSWindow?
    private(set) var noticesWindow: NSWindow?
    func show() {
        if window == nil {
            window = makeWindow(title: L10n.string("关于 Rnotebook"), size: .init(width: 420, height: 380),
                                content: NotebookAboutView(showNotices: { [weak self] in self?.showNotices() }))
            window?.setAccessibilityIdentifier("notebook-about")
        }
        window?.title = L10n.string("关于 Rnotebook")
        window?.makeKeyAndOrderFront(nil)
    }
    func showNotices() {
        do {
            if noticesWindow == nil {
                let notices = try NotebookThirdPartyNotice.load()
                noticesWindow = makeWindow(title: L10n.string("第三方组件与许可证"), size: .init(width: 840, height: 620), content: NotebookNoticesView(notices: notices))
                noticesWindow?.minSize = .init(width: 660, height: 420)
                noticesWindow?.setAccessibilityIdentifier("notebook-third-party")
            }
            noticesWindow?.title = L10n.string("第三方组件与许可证")
            noticesWindow?.makeKeyAndOrderFront(nil)
        } catch { NSApp.presentError(error) }
    }
    private func makeWindow<V: View>(title: String, size: NSSize, content: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content.appAppearance(NotebookPreferences.appearance)))
        window.title = title; window.setContentSize(size); window.center()
        window.tabbingMode = .disallowed; window.isReleasedWhenClosed = false
        return window
    }
}

private struct NotebookAboutView: View {
    @ObservedObject private var language = NotebookPreferences.language
    let showNotices: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 80, height: 80)
            Text("Rnotebook").font(.system(size: 25, weight: .semibold))
            Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").foregroundStyle(.secondary)
            Text(L10n.string("在 Mac 上编写 QMD/RMD 笔记、运行 R 并导出报告。"))
                .multilineTextAlignment(.center)
            Text(L10n.string("开发者") + "  hiox-tech").textSelection(.enabled)
            Link("GeorgeBinDragon@outlook.com", destination: URL(string: "mailto:GeorgeBinDragon@outlook.com")!)
            Button(L10n.string("第三方组件与许可证…"), action: showNotices).padding(.top, 8)
                .accessibilityIdentifier("about-third-party")
        }.font(.system(size: 13)).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).id(language.language.id)
    }
}

private struct NotebookNoticesView: View {
    @ObservedObject private var language = NotebookPreferences.language
    let notices: [NotebookThirdPartyNotice]
    @State private var selected = "edmund"
    var body: some View {
        HSplitView {
            List(notices, selection: $selected) { notice in
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.name).fontWeight(.medium)
                    Text(notice.license).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 3).tag(notice.id)
            }.frame(minWidth: 210, idealWidth: 245, maxWidth: 330)
            ScrollView {
                if let notice = notices.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(notice.name).font(.title2.bold())
                        Text(notice.license).foregroundStyle(.secondary)
                        Text(tryNotice(notice)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(24)
                }
            }.frame(minWidth: 380)
        }.id(language.language.id)
    }
    private func tryNotice(_ notice: NotebookThirdPartyNotice) -> String {
        do { return try notice.text() }
        catch { return L10n.string("无法读取许可证文件。") }
    }
}
