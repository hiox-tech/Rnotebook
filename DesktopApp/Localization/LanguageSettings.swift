import Combine
import Foundation

extension Notification.Name {
    static let notebookLanguageChanged = Notification.Name("Rnotebook.languageChanged")
}

/// Locale.preferredLanguages includes this application's AppleLanguages override
/// and may keep its launch value cached. Following the system must read the
/// global language domain, independently of explicit per-app language choices.
enum SystemInterfaceLanguages {
    static func preferred(globalDomain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain),
                          fallback: () -> [String] = { Locale.preferredLanguages }) -> [String] {
        if let languages = globalDomain?["AppleLanguages"] as? [String], !languages.isEmpty { return languages }
        return fallback()
    }
}

@MainActor final class LanguageSettings: ObservableObject {
    static let system = "system"
    static let preferenceKey = "interface.language"
    @Published private(set) var preference: String
    @Published private(set) var language: AppLanguage
    var locale: Locale { Locale(identifier: language.id) }
    private let defaults: UserDefaults
    private let systemLanguages: () -> [String]

    init(defaults: UserDefaults = .standard, systemLanguages: @escaping () -> [String] = { SystemInterfaceLanguages.preferred() }) {
        self.defaults = defaults
        self.systemLanguages = systemLanguages
        let stored = defaults.string(forKey: Self.preferenceKey) ?? Self.system
        let initial = stored == Self.system || AppLanguage.supported.contains { $0.id == stored } ? stored : Self.system
        preference = initial
        if initial == Self.system { defaults.removeObject(forKey: "AppleLanguages") }
        language = AppLanguage.resolve(preferred: initial == Self.system ? systemLanguages() : [initial])
        L10n.configure(language: language)
    }

    /// Unsupported/untranslated identifiers are rejected, never silently offered.
    @discardableResult func select(_ identifier: String) -> Bool {
        guard identifier == Self.system || AppLanguage.supported.contains(where: { $0.id == identifier }) else { return false }
        preference = identifier
        defaults.set(identifier, forKey: Self.preferenceKey)
        // App-scoped preference for AppKit's native panels on the next launch.
        // Other apps and the user's global language order are never changed.
        if identifier == Self.system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([identifier], forKey: "AppleLanguages") }
        refreshSystemLanguage()
        return true
    }

    func refreshSystemLanguage() {
        let resolved = AppLanguage.resolve(preferred: preference == Self.system ? systemLanguages() : [preference])
        L10n.configure(language: resolved)
        if language != resolved {
            language = resolved
            NotificationCenter.default.post(name: .notebookLanguageChanged, object: self)
        }
    }
}
