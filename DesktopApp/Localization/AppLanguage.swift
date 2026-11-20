import Foundation

/// Register a language here only after its UI resources are ready to ship.
/// Keep Config/Info.plist's localization declarations in sync, so AppKit's
/// native document panels resolve the same supported languages as Settings.
/// Identifiers follow BCP 47 and do not depend on the R runtime language.
struct AppLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let nativeName: String
    let helpIdentifiers: [String]

    init(id: String, nativeName: String, helpIdentifiers: [String]? = nil) {
        self.id = id
        self.nativeName = nativeName
        self.helpIdentifiers = helpIdentifiers ?? [id]
    }

    static let simplifiedChinese = AppLanguage(id: "zh-Hans", nativeName: "简体中文", helpIdentifiers: ["zh-Hans", "zh-CN"])
    static let english = AppLanguage(id: "en", nativeName: "English")
    static let supported = [simplifiedChinese, english]

    static func resolve(preferred: [String], supported: [AppLanguage] = supported) -> AppLanguage {
        let identifiers = supported.map(\.id)
        let match = Bundle.preferredLocalizations(from: identifiers, forPreferences: preferred).first
        return supported.first { $0.id == match } ?? simplifiedChinese
    }
}
