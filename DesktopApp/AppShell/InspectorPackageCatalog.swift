import Foundation

struct InspectorCRANMirror: Codable, Identifiable, Sendable {
    let name: String
    let url: String
    var id: String { url }
    static func repositoryKey(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

actor InspectorMirrorCatalog {
    static let shared = InspectorMirrorCatalog()
    nonisolated static var bundled: [InspectorCRANMirror] {
        guard let url = Bundle.main.url(forResource: "CRANMirrors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([InspectorCRANMirror].self, from: data) else { return [] }
        return values
    }
    private var cached: [InspectorCRANMirror]?
    func mirrors() async -> [InspectorCRANMirror] {
        if let cached { return cached }
        var request = URLRequest(url: URL(string: "https://cran.r-project.org/CRAN_mirrors.csv")!)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else { return Self.bundled }
            let values = Self.parse(data)
            guard values.count >= 10 else { return Self.bundled }
            cached = values; return values
        } catch { return Self.bundled }
    }
    nonisolated static func parse(_ data: Data) -> [InspectorCRANMirror] {
        let rows = csvRows(String(decoding: data, as: UTF8.self))
        guard let header = rows.first, let name = header.firstIndex(of: "Name"),
              let url = header.firstIndex(of: "URL"), let ok = header.firstIndex(of: "OK") else { return [] }
        var seen = Set<String>()
        return rows.dropFirst().compactMap { row -> InspectorCRANMirror? in
            guard row.count > max(name, url, ok), row[ok] == "1",
                  let location = URL(string: row[url]), ["https", "http"].contains(location.scheme),
                  location.host != nil, location.user == nil, location.password == nil else { return nil }
            let key = InspectorCRANMirror.repositoryKey(row[url])
            guard seen.insert(key).inserted else { return nil }
            return .init(name: row[name], url: key)
        }
    }
    private nonisolated static func csvRows(_ text: String) -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if character == ",", !quoted { row.append(field); field = "" }
            else if (character == "\n" || character == "\r\n"), !quoted {
                row.append(field); field = ""; rows.append(row); row = []
            } else if character != "\r" || quoted { field.append(character) }
            index += 1
        }
        guard !quoted else { return [] }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
