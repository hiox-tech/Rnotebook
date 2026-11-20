import CryptoKit
import Foundation

struct DocumentRevision: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(data: Data) { rawValue = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    init(text: String) { self.init(data: Data(text.utf8)) }

    /// Swift String equality normalizes Unicode. Source snapshots and their
    /// UTF-16 ranges must instead refer to exactly the same stored bytes.
    static func sameSource(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): lhs.utf8.elementsEqual(rhs.utf8)
        default: false
        }
    }
}

