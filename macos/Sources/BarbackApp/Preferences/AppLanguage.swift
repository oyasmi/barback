import Foundation

/// The interface language chosen in 偏好设置 (design.md §6.7). Only Simplified Chinese — the
/// development language, whose text is the lookup key — and English are shipped.
///
/// The choice is stored as `AppleLanguages` in Barback's own defaults domain, which is what
/// Foundation reads at launch to pick a `.lproj` and what System Settings → Language & Region
/// → Applications writes for a per-app language, so the two always agree. Like that system
/// setting it only takes effect on the next launch: SwiftUI literals, `String(localized:)`,
/// menus and the system's own control text are all bound to the language picked at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    /// The two fixed languages are named in their own language, so whoever cannot read the
    /// current interface can still find theirs.
    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zhHans: return "简体中文" // l10n: ignore
        case .en: return "English"
        }
    }

    private static let languagesKey = "AppleLanguages"

    /// What the picker shows. Reads Barback's persistent domain directly: a plain
    /// `UserDefaults.standard.array(forKey:)` falls through to the global domain when no app
    /// override exists and would report the system list as if it were an explicit choice.
    static var stored: AppLanguage {
        guard let first = appDomainLanguages?.first else { return .system }
        return matching(first) ?? .system
    }

    /// Writes the choice; `.system` removes the override so the system list applies again.
    static func store(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: languagesKey)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: languagesKey)
        }
    }

    /// The language this process is showing, decided at launch. A binary run without its
    /// bundle (`make run`) has no `.lproj` and shows the Chinese source text whatever the
    /// preferences say.
    static let current: AppLanguage = {
        guard Bundle.main.url(forResource: "Localizable", withExtension: "strings") != nil,
              let localization = Bundle.main.preferredLocalizations.first else { return .zhHans }
        return matching(localization) ?? .zhHans
    }()

    /// The language the next launch will show if this choice stands: `.system` walks the
    /// system's preferred list for the first language Barback ships, and falls back to the
    /// development language when the list contains neither.
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[Self.languagesKey] as? [String] ?? []
        return preferred.lazy.compactMap(Self.matching).first ?? .zhHans
    }

    private static var appDomainLanguages: [String]? {
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: domain)?[languagesKey] as? [String]
    }

    /// Maps a language identifier (`en-GB`, `zh-CN`, `zh-Hans-SG`, …) to a shipped language.
    /// Traditional Chinese has no localization of its own and does not match Simplified.
    private static func matching(_ identifier: String) -> AppLanguage? {
        let language = Locale.Language(identifier: identifier)
        if language.languageCode == .english { return .en }
        if language.languageCode == .chinese, language.maximalIdentifier.hasPrefix("zh-Hans") { return .zhHans }
        return nil
    }
}
