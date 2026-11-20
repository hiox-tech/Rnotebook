import SwiftUI

/// Current document's R session; all list entries stay on one compact line.
struct RecordStatusLayoutPreview: View {
    @ObservedObject var model: RecordLayoutModel
    private var variableQuery: String { session.variableQuery }
    @FocusState private var helpFocused: Bool
    @State private var preview: InspectorPreviewSelection?
    @State private var deleting: NotebookVariable?
    @State private var actionSession: UUID?
    private var session: NotebookExecution { model.notebook }
    private var available: Bool { !session.needsRestart && !session.hasPendingRSelection }
    private var snapshot: NotebookInspectorSnapshot? { available ? session.inspectorSnapshot : nil }
    private var canEditObjects: Bool { available && !session.isBusy && session.state == .ready }
    private var matchingVariables: [NotebookVariable] {
        snapshot != nil && session.variablesMatchQuery ? session.inspectorVariables : []
    }
    private var matchingPackages: [NotebookPackage] {
        (snapshot?.packages ?? []).filter { model.packageQuery.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(model.packageQuery) }
    }
    private var emptyReason: String? {
        if session.hasPendingRSelection { return L10n.string("R 或包目录已更换，请先重启会话") }
        if session.needsRestart { return L10n.string("重启 R 后刷新") }
        if session.state == .notStarted { return L10n.string("启动 R 后显示") }
        if snapshot == nil { return session.isBusy ? L10n.string("正在读取…") : L10n.string("点击刷新重试") }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            NotebookSessionBar(model: model).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            VSplitView {
                variableSection.frame(minHeight: 150, idealHeight: 260)
                packageSection.frame(minHeight: 180, idealHeight: 300)
            }
            Divider()
            helpRow.padding(12)
        }
        .font(.system(size: 11)).controlSize(.small)
        .accessibilityElement(children: .contain).accessibilityIdentifier("record-status-panel")
        .alert(L10n.string("删除变量？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.string("取消"), role: .cancel) { deleting = nil }
            Button(L10n.string("删除"), role: .destructive) {
                if let variable = deleting { session.manage(.init(operation: .removeObject, name: variable.name), expectedSession: actionSession) }
                deleting = nil
            }
        } message: { Text(L10n.string("从当前 R 会话中删除“\(String(deleting?.name ?? ""))”。代码和已有结果会保留。")) }
        .alert(L10n.string("清空当前 R 会话的所有变量？"), isPresented: $model.showingClearVariables) {
            Button(L10n.string("取消"), role: .cancel) {}
            Button(L10n.string("清空变量"), role: .destructive) { session.manage(.init(operation: .clearObjects), expectedSession: model.inspectorActionSession) }
        } message: { Text(L10n.string("将清除当前文档 R 环境的全部用户对象，包括隐藏对象和用户函数，不受筛选结果限制。代码和已有结果会保留，其他窗口不受影响。")) }
        .onChange(of: model.helpSearchRequest) { _, _ in helpFocused = true }
        .sheet(item: $preview) { RecordVariablePreviewSheet(session: session, selection: $0) }
        .sheet(isPresented: $model.showingPackageInstall) { RecordPackageInstallSheet(model: model, session: session) }
    }
    private var variableSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.string("变量")).fontWeight(.semibold).fixedSize().accessibilityIdentifier("record-variable-heading")
                refreshButton("record-variable-refresh")
                TextField(L10n.string("筛选变量"), text: Binding(get: { variableQuery }, set: { session.filterVariables($0) })).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("record-variable-filter")
                Button { model.requestClearVariables() } label: { Image(systemName: "eraser") }
                    .buttonStyle(.borderless).disabled(!canEditObjects)
                    .help(L10n.string("清空当前会话的所有变量")).accessibilityLabel(L10n.string("清空变量")).accessibilityIdentifier("record-variable-clear")
            }.frame(height: 24)
            GeometryReader { geometry in
                List(matchingVariables) { variable in
                    HStack(spacing: 4) {
                        Image(systemName: variable.symbol).resizable().scaledToFit().foregroundStyle(.secondary).frame(width: 12, height: 12).frame(width: 14)
                        Button {
                            guard let sessionID = session.sessionID else { return }
                            preview = .init(name: variable.name, sessionID: sessionID, revision: session.inspectorRevision)
                        } label: { Text(variable.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).disabled(!canEditObjects)
                        .frame(width: min(110, max(48, geometry.size.width * 0.27)), alignment: .leading)
                        .help(L10n.string("只读预览 ") + variable.name).accessibilityIdentifier("record-variable-preview-" + variable.name)
                        Text(variable.type).foregroundStyle(.secondary).lineLimit(1).frame(width: min(56, geometry.size.width * 0.18), alignment: .leading)
                        Text(variable.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        Button { actionSession = session.sessionID; deleting = variable } label: { Image(systemName: "trash").frame(width: 14) }
                            .buttonStyle(.borderless).disabled(!canEditObjects)
                            .help(L10n.string("删除变量 ") + variable.name).accessibilityLabel(L10n.string("删除变量 ") + variable.name)
                            .accessibilityIdentifier("record-variable-delete-" + variable.name)
                    }
                    .font(.system(size: 11)).frame(height: 20)
                    .help(variable.name + " · " + variable.type + " · " + variable.detail)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("record-variable-row-" + variable.name)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if matchingVariables.isEmpty { emptyLabel(emptyReason ?? (!session.variablesMatchQuery ? L10n.string("正在读取…") : variableQuery.isEmpty ? L10n.string("当前会话没有变量") : L10n.string("没有匹配的变量"))) } }
                .accessibilityIdentifier("record-variable-list")
            }
            if snapshot != nil, session.variablesMatchQuery, session.canLoadMoreVariables {
                HStack {
                    Spacer()
                    Button(L10n.string("载入更多…")) { session.loadMoreVariables() }
                        .buttonStyle(.borderless).disabled(!canEditObjects)
                        .accessibilityIdentifier("record-variable-load-more")
                }
            }
        }
        .padding(12).accessibilityElement(children: .contain).accessibilityIdentifier("record-variable-section")
    }
    private var packageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.string("R包")).fontWeight(.semibold).fixedSize().accessibilityIdentifier("record-package-heading")
                refreshButton("record-package-refresh")
                TextField(L10n.string("筛选包"), text: $model.packageQuery).textFieldStyle(.roundedBorder).accessibilityIdentifier("record-package-filter")
                Button { model.presentPackageInstall() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).disabled(session.isBusy || !available)
                    .help(L10n.string("安装 R 包")).accessibilityLabel(L10n.string("安装 R 包")).accessibilityIdentifier("record-package-install")
            }.frame(height: 24)
            GeometryReader { geometry in
                List(matchingPackages) { package in
                    HStack(spacing: 4) {
                        Toggle(L10n.string("加载 ") + package.name, isOn: Binding(get: { package.loaded }, set: {
                            session.manage(.init(operation: $0 ? .loadPackage : .unloadPackage, name: package.name))
                        }))
                        .toggleStyle(.checkbox).labelsHidden().frame(width: 14)
                        .disabled(session.isBusy || package.protected)
                        .help(package.protected ? L10n.string("R 基础包") : package.loaded ? L10n.string("从搜索路径卸载 ") + package.name : L10n.string("加载 ") + package.name)
                        .accessibilityIdentifier("record-package-load-" + package.name)
                        Text(package.name).lineLimit(1).frame(width: min(110, max(48, geometry.size.width * 0.27)), alignment: .leading)
                        Text(package.version).foregroundStyle(.secondary).lineLimit(1).frame(width: min(58, geometry.size.width * 0.18), alignment: .leading)
                        Text(package.description).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        Button { if let url = package.officialURL { _ = session.openHelpURL(url) } } label: { Image(systemName: "arrow.up.right.square").frame(width: 14) }
                            .buttonStyle(.borderless).disabled(package.officialURL == nil)
                            .help(package.protected ? L10n.string("打开 R 官方文档") : package.officialURL == nil ? L10n.string("此包来自非 CRAN 仓库") : L10n.string("打开 CRAN 包页面"))
                            .accessibilityLabel(L10n.string("打开 ") + package.name + L10n.string(" 官方页面")).accessibilityIdentifier("record-package-cran-" + package.name)
                    }
                    .font(.system(size: 11)).frame(height: 20)
                    .help(package.name + " " + package.version + " · " + package.description)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("record-package-row-" + package.name)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if matchingPackages.isEmpty { emptyLabel(emptyReason ?? L10n.string("没有匹配的已安装包")) } }
                .accessibilityIdentifier("record-package-list")
            }
            if let snapshot, snapshot.packageTotal > 2000 { Text(L10n.string("最多显示 2000 个包")).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(12).accessibilityElement(children: .contain).accessibilityIdentifier("record-package-section")
    }
    private func refreshButton(_ identifier: String) -> some View {
        Button { session.manage(.init(operation: .snapshot)) } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless).disabled(session.isBusy || !available)
            .help(L10n.string("刷新变量与已安装包")).accessibilityLabel(L10n.string("刷新变量与已安装包")).accessibilityIdentifier(identifier)
    }
    private var helpRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            TextField(L10n.string("函数或帮助主题"), text: $model.helpQuery).textFieldStyle(.roundedBorder).onSubmit { openHelp() }
                .focused($helpFocused).accessibilityIdentifier("record-help-query")
            Button(action: openHelp) { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).disabled(NotebookOfficialHelp.searchURL(model.helpQuery) == nil)
                .help(L10n.string("在浏览器中打开 R 官方在线搜索结果")).accessibilityLabel(L10n.string("在浏览器中打开帮助")).accessibilityIdentifier("record-help-open")
        }.font(.system(size: 11)).controlSize(.small)
        .accessibilityElement(children: .contain).accessibilityIdentifier("record-help-row")
    }
    private func openHelp() { session.manage(.init(operation: .help, name: model.helpQuery)) }
    private func emptyLabel(_ title: String) -> some View {
        Text(title).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
