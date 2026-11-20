import Combine
import Foundation

@MainActor final class DocumentBehaviorSettings: ObservableObject {
    let defaults: UserDefaults
    @Published var autosaveEnabled: Bool { didSet { defaults.set(autosaveEnabled, forKey: "documents.autosave") } }
    @Published var idleDelay: Double { didSet { defaults.set(idleDelay, forKey: "documents.idleDelay") } }
    @Published var maximumDelay: Double { didSet { defaults.set(maximumDelay, forKey: "documents.maximumDelay") } }
    @Published var automaticallyReload: Bool { didSet { defaults.set(automaticallyReload, forKey: "documents.reload") } }
    @Published var rememberWindows: Bool { didSet { defaults.set(rememberWindows, forKey: "windows.remember") } }

    init(defaults: UserDefaults? = nil) {
        #if DEBUG
        let defaults = defaults ?? ProcessInfo.processInfo.environment["KAIL_UI_TEST_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:))
            ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : UserDefaults(suiteName: "Rnotebook-WindowTests-" + String(ProcessInfo.processInfo.processIdentifier))!)
        #else
        let defaults = defaults ?? .standard
        #endif
        self.defaults = defaults
        func enabled(_ key: String) -> Bool { defaults.object(forKey: key) == nil || defaults.bool(forKey: key) }
        autosaveEnabled = enabled("documents.autosave")
        automaticallyReload = enabled("documents.reload")
        rememberWindows = enabled("windows.remember")
        let idle = defaults.double(forKey: "documents.idleDelay")
        idleDelay = Self.idleOptions.contains(idle) ? idle : 1
        let maximum = defaults.double(forKey: "documents.maximumDelay")
        maximumDelay = Self.maximumOptions.contains(maximum) ? maximum : 5
    }
    static let idleOptions: [Double] = [0.5, 1, 2, 5]
    static let maximumOptions: [Double] = [5, 10, 30, 60]
    var effectiveIdleDelay: Double { Self.idleOptions.contains(idleDelay) ? idleDelay : 1 }
    var effectiveMaximumDelay: Double { max(effectiveIdleDelay, Self.maximumOptions.contains(maximumDelay) ? maximumDelay : 5) }
}
