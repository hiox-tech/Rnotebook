import Foundation

/// Quick Look reads a bounded snapshot, closes the file, and never executes it.
struct NotebookPreviewContent: Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    let source: String

    static func load(from url: URL) throws -> Self {
        guard url.isFileURL, ["qmd", "rmd"].contains(url.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let source = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return Self(source: source)
    }
}
