import Foundation
enum RecordTableClipboard {
    static func parse(_ text: String, delimiter: Character = "\t") -> [[String]]? {
        let chars = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, index = 0, endedRow = false
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" {
                        field.append("\""); index += 1
                    } else { quoted = false; closed = true }
                } else { field.append(char) }
                endedRow = false
            } else if char == delimiter {
                row.append(field); field = ""; closed = false; endedRow = false
            } else if char == "\n" || char == "\r" || char == "\r\n" {
                row.append(field); rows.append(row)
                row = []; field = ""; closed = false; endedRow = true
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
            } else if char == "\"", field.isEmpty, !closed {
                quoted = true; endedRow = false
            } else {
                guard !closed else { return nil }
                field.append(char); endedRow = false
            }
            index += 1
        }
        guard !quoted else { return nil }
        if !endedRow || rows.isEmpty { row.append(field); rows.append(row) }
        let width = rows.map(\.count).max() ?? 1
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    static func encode(_ rows: [[String]], delimiter: Character = "\t") -> String {
        rows.map { row in
            row.map { value in
                if value.contains(where: { $0 == delimiter || $0.isNewline || $0 == "\"" }) {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n")
    }
}