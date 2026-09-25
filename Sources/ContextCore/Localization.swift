import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case russian = "ru"
    case english = "en"

    public static let preferenceKey = "interfaceLanguage"
    public var nativeName: String { self == .russian ? "Русский" : "English" }
    public var locale: Locale { Locale(identifier: self == .russian ? "ru_RU" : "en_US") }

    /// Preserve the original Russian UI for existing installations and invalid preferences.
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .russian
    }

    /// AppleLanguages is app-scoped. Never write global macOS or Codex preferences.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        defaults.set([rawValue], forKey: "AppleLanguages")
    }
}

/// Keep one language for the process lifetime, including background errors and notifications.
/// Changing the preference takes effect after a user-initiated restart.
public enum L10n {
    public static let language = AppLanguage.load()
    public static var locale: Locale { language.locale }

    /// Both translations are required at the call site; interpolations remain type checked.
    public static func text(_ russian: String, _ english: String, language: AppLanguage = L10n.language) -> String {
        language == .russian ? russian : english
    }

    public static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}
