import AppKit
import Combine
import SwiftUI

@MainActor enum NotebookPreferences {
    static let language = LanguageSettings()
    static let source = SourceEditorSettings()
    static let visual = VisualEditorSettings()
    static let appearance = AppearanceSettings()
    static let documents = DocumentBehaviorSettings()
}

enum AppAccent: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L10n.string("跟随系统")
        case .blue: return L10n.string("蓝色")
        case .purple: return L10n.string("紫色")
        case .pink: return L10n.string("粉色")
        case .red: return L10n.string("红色")
        case .orange: return L10n.string("橙色")
        case .yellow: return L10n.string("黄色")
        case .green: return L10n.string("绿色")
        }
    }
    var color: NSColor {
        switch self {
        case .system: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        }
    }
}

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L10n.string("跟随系统")
        case .light: return L10n.string("浅色")
        case .dark: return L10n.string("深色")
        }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    var appearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

@MainActor final class AppearanceSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var accent: AppAccent { didSet { defaults.set(accent.rawValue, forKey: "appearance.accent") } }
    @Published var interface: InterfaceAppearance { didSet { defaults.set(interface.rawValue, forKey: "appearance.interface") } }
    init(defaults: UserDefaults? = nil) {
        #if DEBUG
        self.defaults = defaults ?? ProcessInfo.processInfo.environment["KAIL_UI_TEST_DEFAULTS_SUITE"]
            .flatMap { UserDefaults(suiteName: $0) } ?? .standard
        #else
        self.defaults = defaults ?? .standard
        #endif
        accent = AppAccent(rawValue: self.defaults.string(forKey: "appearance.accent") ?? "") ?? .system
        interface = InterfaceAppearance(rawValue: self.defaults.string(forKey: "appearance.interface") ?? "") ?? .system
    }
    func applyToApplication() {
        if NSApp.appearance?.name != interface.appearance?.name { NSApp.appearance = interface.appearance }
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @ObservedObject var settings: AppearanceSettings
    @ObservedObject private var language = NotebookPreferences.language
    func body(content: Content) -> some View {
        content
            .environmentObject(settings)
            .environment(\.locale, language.locale)
            .tint(Color(nsColor: settings.accent.color))
            .accentColor(Color(nsColor: settings.accent.color))
            .preferredColorScheme(settings.interface.colorScheme)
            .onAppear { settings.applyToApplication() }
            .onChange(of: settings.interface) { _, _ in settings.applyToApplication() }
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
                settings.objectWillChange.send()
            }
    }
}

extension View {
    func appAppearance(_ settings: AppearanceSettings) -> some View { modifier(AppAppearanceModifier(settings: settings)) }
}
