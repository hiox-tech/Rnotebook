import Foundation

/// An immutable lookup context also usable without SwiftUI (panels and errors).
struct LocalizationResources {
    let language: AppLanguage
    let bundle: Bundle
    var locale: Locale { Locale(identifier: language.id) }

    func string(_ key: String.LocalizationValue) -> String {
        let selected = bundle.url(forResource: language.id, withExtension: "lproj").flatMap(Bundle.init(url:))
        let fallback = bundle.url(forResource: AppLanguage.simplifiedChinese.id, withExtension: "lproj").flatMap(Bundle.init(url:))
        // The source keys/default values are Chinese, so missing translations
        // retain their source text. Never change the process-wide AppleLanguages.
        return String(localized: key, bundle: selected ?? fallback ?? bundle, locale: locale)
    }

    func helpURL(module: String) -> URL? {
        guard !module.isEmpty, !module.contains("/"), module != ".", module != "..",
              let root = bundle.resourceURL else { return nil }
        let candidates = language.helpIdentifiers + AppLanguage.simplifiedChinese.helpIdentifiers
        for identifier in candidates {
            let url = root.appendingPathComponent("AnalysisModules/\(module)/Help/\(identifier).md")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Error descriptions and environment probes may run off the main actor.
/// Only the tiny immutable lookup snapshot is shared, guarded by a lock.
enum L10n {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value = LocalizationResources(language: .simplifiedChinese, bundle: .main)
    }
    private static let storage = Storage()
    static var resources: LocalizationResources {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.value
    }
    static func configure(language: AppLanguage) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.value = LocalizationResources(language: language, bundle: .main)
    }
    static func string(_ key: String.LocalizationValue) -> String { resources.string(key) }
}
