import Foundation

struct NotebookInspectorRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case completion, snapshot, clearObjects, previewObject, removeObject, loadPackage, unloadPackage, installPackage, help, setWorkingDirectory, saveWorkspace
    }
    let operation: Operation
    var name: String?
    var preview: NotebookPreviewRequest?
    var installation: NotebookPackageInstallation?
    var refreshPackages: Bool?
    var variablePage: NotebookVariablePageRequest?
    var isValid: Bool {
        if let variablePage {
            guard variablePage.isValid, ![.completion, .previewObject, .help].contains(operation),
                  operation == .snapshot || (variablePage.offset == 0 && variablePage.snapshotID == nil) else { return false }
        }
        if operation == .completion { return name != nil && (name?.utf8.count ?? 0) <= 512 && !(name?.contains("\0") ?? false) && preview == nil && installation == nil }
        if operation == .snapshot || operation == .clearObjects { return name == nil && preview == nil && installation == nil }
        if operation == .installPackage, let installation { return name == nil && installation.isValid && preview == nil }
        guard let name, !name.isEmpty, name.utf8.count <= (operation == .saveWorkspace ? 4096 : 512), !name.contains("\0") else { return false }
        if operation == .previewObject { return installation == nil && (preview ?? .init()).isValid }
        guard preview == nil, installation == nil else { return false }
        if operation == .saveWorkspace { return name.hasPrefix("/") }
        if [.loadPackage, .unloadPackage, .installPackage].contains(operation) {
            return name.utf8.count <= 128 && name.range(of: "^[A-Za-z][A-Za-z0-9.]*$", options: .regularExpression) != nil
        }
        return true
    }
    var title: String {
        switch operation {
        case .completion: L10n.string("R 代码补全")
        case .snapshot: L10n.string("刷新变量与包")
        case .clearObjects: L10n.string("清空变量")
        case .previewObject: L10n.string("预览变量")
        case .removeObject: L10n.string("删除变量")
        case .loadPackage: L10n.string("加载包")
        case .unloadPackage: L10n.string("卸载包")
        case .installPackage: L10n.string("安装包")
        case .help: L10n.string("打开帮助")
        case .setWorkingDirectory: L10n.string("切换工作目录")
        case .saveWorkspace: L10n.string("保存 R 工作区")
        }
    }
}

struct NotebookVariable: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let type: String
    let detail: String
    let kind: String
    var id: Data { Data(name.utf8) }
    var symbol: String {
        switch kind {
        case "table", "matrix": "tablecells"
        case "list": "list.bullet.rectangle"
        case "numeric": "number"
        case "character": "textformat"
        default: "cube"
        }
    }
}

/// Limits each protocol response, never the number of variables a user can browse.
struct NotebookVariablePageRequest: Codable, Sendable, Equatable {
    var query: String = ""
    var offset: Int = 0
    var snapshotID: Int?
    var isValid: Bool {
        query.utf8.count <= 4096 && !query.contains("\0") && (0...Int(Int32.max)).contains(offset) &&
        (snapshotID.map { (1...Int(Int32.max)).contains($0) } ?? (offset == 0))
    }
}

struct NotebookVariablePage: Codable, Sendable, Equatable {
    let query: String
    let offset: Int
    let total: Int
    let snapshotID: Int
    var isValid: Bool {
        NotebookVariablePageRequest(query: query, offset: offset, snapshotID: snapshotID).isValid && total >= offset && total <= Int(Int32.max)
    }
}

struct NotebookPackage: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let version: String
    let library: String
    let loaded: Bool
    let namespaceLoaded: Bool
    let protected: Bool
    var description: String = ""
    var repository: String = ""
    var id: String { name }
    var officialURL: URL? {
        if protected { return URL(string: "https://search.r-project.org/R/refmans/" + name + "/html/00Index.html") }
        if !repository.isEmpty && !repository.localizedCaseInsensitiveContains("CRAN") { return nil }
        return URL(string: "https://cran.r-project.org/package=" + name)
    }
}

struct NotebookInspectorSnapshot: Codable, Sendable, Equatable {
    let variables: [NotebookVariable]
    let packages: [NotebookPackage]
    let variableTotal: Int
    let packageTotal: Int
    let installLibrary: String
    let repositories: [String]
    var workingDirectory: String?
    var libraryPaths: [String]?
    var variablePage: NotebookVariablePage?
    var isValid: Bool {
        variables.count <= 500 && packages.count <= 2000 && variableTotal >= variables.count && packageTotal >= packages.count &&
        Set(variables.map { Data($0.name.utf8) }).count == variables.count && Set(packages.map(\.name)).count == packages.count &&
        variables.allSatisfy { !$0.name.isEmpty && $0.name.utf8.count <= 512 && $0.type.utf8.count <= 256 && $0.detail.utf8.count <= 256 } &&
        packages.allSatisfy { !$0.name.isEmpty && $0.name.utf8.count <= 128 && $0.version.utf8.count <= 128 && $0.library.utf8.count <= 4096 && $0.description.utf8.count <= 1024 && $0.repository.utf8.count <= 512 } &&
        installLibrary.utf8.count <= 4096 && repositories.count <= 16 && repositories.allSatisfy { $0.utf8.count <= 4096 } &&
        (workingDirectory?.utf8.count ?? 0) <= 4096 && (libraryPaths?.count ?? 0) <= 128 &&
        (libraryPaths?.allSatisfy { $0.utf8.count <= 4096 } ?? true) &&
        (variablePage.map { $0.isValid && $0.total <= variableTotal && variables.count == min(500, $0.total - $0.offset) } ?? true)
    }
    static func helpURL(_ string: String) -> URL? {
        guard let parts = URLComponents(string: string), parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
              let url = parts.url, string.utf8.count <= 8192 else { return nil }
        return url
    }
}

struct NotebookPreviewRequest: Codable, Sendable, Equatable, Hashable {
    var path: [Int] = []
    var rowOffset: Int = 0
    var columnOffset: Int = 0
    var structure: Bool = false
    var isValid: Bool { path.count <= 12 && path.allSatisfy { $0 >= 0 && $0 < Int(Int32.max) } && rowOffset >= 0 && rowOffset <= Int(Int32.max) && columnOffset >= 0 && columnOffset <= Int(Int32.max) }
}

struct NotebookObjectPreview: Codable, Sendable, Equatable {
    let name: String
    let type: String
    let kind: String
    let summary: String
    let totalRows: Int
    let totalColumns: Int
    let columns: [String]
    let rows: [[String]]
    let expandable: [Bool]
    let request: NotebookPreviewRequest
    var rowNames: [String]? = nil
    var scalarText: String? = nil
    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 512 && type.utf8.count <= 256 && summary.utf8.count <= 2048 &&
        ["table", "vector", "list", "summary"].contains(kind) && totalRows >= 0 && totalColumns >= 0 &&
        request.isValid && columns.count <= 30 && columns.allSatisfy { $0.utf8.count <= 512 } && rows.count <= 100 &&
        expandable.count == rows.count && rows.allSatisfy { $0.count == columns.count && $0.allSatisfy { $0.utf8.count <= 256 } } &&
        rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } } <= 650_000 &&
        request.rowOffset <= totalRows && rows.count <= totalRows - request.rowOffset &&
        (rowNames == nil || (rowNames?.count == rows.count && rowNames!.allSatisfy { $0.utf8.count <= 512 })) &&
        (scalarText?.utf8.count ?? 0) <= 65_536
    }
}

struct NotebookPackageInstallation: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable { case repository, local }
    var source: Source = .repository
    var packages: [String] = []
    var files: [String] = []
    var repository: String = "https://cloud.r-project.org"
    var library: String = ""
    var includeSuggested = false
    var isValid: Bool {
        guard library.hasPrefix("/"), library.utf8.count <= 4096, !library.contains("\0") else { return false }
        if source == .local {
            return packages.isEmpty && (1...20).contains(files.count) && files.allSatisfy {
                $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") && ($0.hasSuffix(".tar.gz") || $0.hasSuffix(".tgz"))
            }
        }
        guard let url = URL(string: repository), ["https", "http", "file"].contains(url.scheme),
              url.user == nil, url.password == nil, repository.utf8.count <= 4096 else { return false }
        return files.isEmpty && (1...20).contains(packages.count) && Set(packages).count == packages.count && packages.allSatisfy {
            $0.utf8.count <= 128 && $0.range(of: "^[A-Za-z][A-Za-z0-9.]*$", options: .regularExpression) != nil
        }
    }
    static func names(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，"))).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum NotebookOfficialHelp {
    static func searchURL(_ query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 4096, !query.contains("\0") else { return nil }
        var url = URLComponents(string: "https://search.r-project.org/")!
        url.queryItems = [URLQueryItem(name: "FMT", value: "query"), URLQueryItem(name: "P", value: query), URLQueryItem(name: "HITSPERPAGE", value: "20"), URLQueryItem(name: "SORT", value: ""), URLQueryItem(name: "DEFAULTOP", value: "and")]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url
    }
}
