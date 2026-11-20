import AppKit

struct DocumentViewState: Codable {
    var sourceOnly: Bool
    var location: Int
    var length: Int
    var scrollY: Double

    @MainActor static func capture(_ model: RecordLayoutModel) -> DocumentViewState {
        let selection = model.activeEditor?.selectedRange() ?? .init(location: 0, length: 0)
        return .init(sourceOnly: model.sourceOnly, location: selection.location, length: selection.length,
                     scrollY: Double(model.activeEditor?.enclosingScrollView?.contentView.bounds.origin.y ?? 0))
    }
    private static func key(_ url: URL) -> String { "document.view." + DocumentRevision(text: url.standardizedFileURL.path).rawValue }
    func save(for url: URL, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(url)) }
    }
    static func load(for url: URL, defaults: UserDefaults = .standard) -> DocumentViewState? {
        defaults.data(forKey: key(url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
}
