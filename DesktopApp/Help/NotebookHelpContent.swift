import Foundation
import Markdown

enum NotebookHelpTopic: String, CaseIterable, Identifiable {
    case overview, components, interface, quickStart = "quick-start", syntax, rBasics = "r-basics", quartoBasics = "quarto-basics", editing, rExport = "r-export", files, shortcuts
    var id: String { rawValue }
    var title: String { L10n.string(titleKey) }
    var titleKey: String.LocalizationValue {
        switch self {
        case .overview: return "认识 Rnotebook"
        case .components: return "组件与环境"
        case .interface: return "界面导览"
        case .rBasics: return "R 基础"
        case .quartoBasics: return "Quarto 与 QMD 基础"
        case .quickStart: return "快速开始"
        case .syntax: return "Quarto语法"
        case .editing: return "编辑与资源"
        case .rExport: return "R 运行与报告导出"
        case .files: return "保存、恢复与设置"
        case .shortcuts: return "快捷键速查"
        }
    }
    var summary: String {
        switch self {
        case .overview: return L10n.string("了解笔记、编辑视图与报告工作流程。")
        case .components: return L10n.string("区分编辑器、R 会话与报告引擎，准备运行环境。")
        case .interface: return L10n.string("对照截图认识工具栏、正文与检查器。")
        case .rBasics: return L10n.string("从对象、向量到数据框、文件读取和绘图。")
        case .quartoBasics: return L10n.string("配置 YAML、代码块、图表引用与报告输出。")
        case .quickStart: return L10n.string("从第一份笔记到运行 R、导出报告。")
        case .syntax: return L10n.string("查阅 Markdown、R 代码块、公式与扩展写法。")
        case .editing: return L10n.string("切换视图，使用补全、格式化和文件引用。")
        case .rExport: return L10n.string("管理会话、运行范围、包与 Quarto 导出。")
        case .files: return L10n.string("配置自动保存，处理冲突与恢复草稿。")
        case .shortcuts: return L10n.string("快速找到编辑、运行和窗口操作快捷键。")
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "book.closed"
        case .components: return "shippingbox"
        case .interface: return "macwindow"
        case .rBasics: return "function"
        case .quartoBasics: return "doc.richtext"
        case .quickStart: return "sparkles"
        case .syntax: return "textformat.abc"
        case .editing: return "pencil.and.outline"
        case .rExport: return "play.rectangle"
        case .files: return "doc.badge.arrow.up"
        case .shortcuts: return "keyboard"
        }
    }
    var url: URL { URL(string: "rnotebook-help://article/" + rawValue)! }
}

enum NotebookHelpExternal: String, CaseIterable {
    case r, quarto, qmd
    var title: String {
        switch self {
        case .r: return L10n.string("R 官方帮助")
        case .quarto: return L10n.string("Quarto 使用指南")
        case .qmd: return L10n.string("QMD 语法指南")
        }
    }
    var url: URL {
        switch self {
        case .r: return URL(string: "https://search.r-project.org/")!
        case .quarto: return URL(string: "https://quarto.org/docs/guide/")!
        case .qmd: return URL(string: "https://quarto.org/docs/authoring/markdown-basics.html")!
        }
    }
}

struct NotebookHelpContent {
    let topic: NotebookHelpTopic
    let language: AppLanguage
    let markdown: String
    static func load(_ topic: NotebookHelpTopic, language: AppLanguage, bundle: Bundle = .main) throws -> Self {
        guard let root = bundle.resourceURL else { throw CocoaError(.fileReadNoSuchFile) }
        let path = root.appendingPathComponent("Help").appendingPathComponent(language.id).appendingPathComponent(topic.rawValue + ".md")
        return .init(topic: topic, language: language, markdown: try String(contentsOf: path, encoding: .utf8))
    }
}

struct NotebookHelpGuideBlock: Identifiable {
    enum Kind { case heading(Int), paragraph, code, list, table, image(String) }
    let id: Int
    let kind: Kind
    let text: String
    var rows: [[String]] = []
    static func parse(_ markdown: String) -> [Self] {
        var blocks: [Self] = []
        for child in Document(parsing: markdown).children {
            let kind: Kind, text: String
            var rows: [[String]] = []
            switch child {
            case let heading as Heading: kind = .heading(heading.level); text = heading.plainText
            case let code as CodeBlock: kind = .code; text = code.code
            case let paragraph as Paragraph where paragraph.childCount == 1 && paragraph.child(at: 0) is Markdown.Image:
                let image = paragraph.child(at: 0) as! Markdown.Image
                kind = .image(image.source ?? ""); text = image.plainText
            case let table as Table:
                kind = .table; text = ""
                for section in table.children {
                    if section is Table.Head { rows.append(section.children.map { cell in cell.children.map { $0.format() }.joined() }) }
                    else { for row in section.children { rows.append(row.children.map { cell in cell.children.map { $0.format() }.joined() }) } }
                }
            case is UnorderedList, is OrderedList:
                kind = .list
                let start = (child as? OrderedList)?.startIndex
                text = child.children.enumerated().map { index, item in
                    let prefix = start.map { "\($0 + UInt(index)). " } ?? "• "
                    return prefix + item.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }.joined(separator: "\n")
            default: kind = .paragraph; text = child.format().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            blocks.append(.init(id: blocks.count, kind: kind, text: text, rows: rows))
        }
        return blocks
    }
}

enum NotebookHelpAsset {
    static func url(_ path: String, bundle: Bundle = .main) -> URL? {
        guard path.hasPrefix("images/"), !path.contains(".."),
              path.range(of: #"^images/[A-Za-z0-9_-]+\.png$"#, options: .regularExpression) != nil,
              let root = bundle.resourceURL else { return nil }
        let url = root.appendingPathComponent("Help").appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
