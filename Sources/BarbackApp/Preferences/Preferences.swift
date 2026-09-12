import Foundation

/// How much detail the status-bar menu shows (requirements.md APP-6 「菜单密度」).
enum MenuDensity: String {
    case normal
    case compact
}

/// The app-wide settings behind 偏好设置. SwiftUI binds to these keys with `@AppStorage`;
/// this type is the read side for the AppKit code — menu building and notification
/// posting — that has no SwiftUI environment to read them from.
enum Preferences {
    enum Key {
        static let menuDensity = "barback.menuDensity"
        static let notifyFatal = "barback.notif.fatal"
        static let notifyRestart = "barback.notif.restart"
        static let notifyOneshot = "barback.notif.oneshot"
        static let debounceMinutes = "barback.notif.debounceMinutes"
        static let logFontSize = "barback.logFontSize"
    }

    /// Registered at launch so an unset key reads the same value here as it does through
    /// the `@AppStorage` defaults in `PreferencesWindowView`.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.menuDensity: MenuDensity.normal.rawValue,
            Key.notifyFatal: true,
            Key.notifyRestart: true,
            Key.notifyOneshot: true,
            Key.debounceMinutes: 10,
            Key.logFontSize: 11.0
        ])
    }

    static var menuDensity: MenuDensity {
        MenuDensity(rawValue: UserDefaults.standard.string(forKey: Key.menuDensity) ?? "") ?? .normal
    }

    static var notifyFatal: Bool { UserDefaults.standard.bool(forKey: Key.notifyFatal) }
    static var notifyRestart: Bool { UserDefaults.standard.bool(forKey: Key.notifyRestart) }
    static var notifyOneshot: Bool { UserDefaults.standard.bool(forKey: Key.notifyOneshot) }

    /// Window during which a repeat of the same notification for the same program is dropped
    /// (requirements.md APP-4, default 10 minutes).
    static var notifyDebounce: TimeInterval {
        TimeInterval(max(1, UserDefaults.standard.integer(forKey: Key.debounceMinutes)) * 60)
    }

    static var logFontSize: Double {
        let stored = UserDefaults.standard.double(forKey: Key.logFontSize)
        return stored > 0 ? stored : 11
    }
}
