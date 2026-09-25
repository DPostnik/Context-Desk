import Foundation
import Testing
@testable import ContextCore

@Test func languagePreferenceRoundTripsAndFallsBack() throws {
    let suite = "ContextDesk.LocalizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(AppLanguage.load(from: defaults) == .russian)
    defaults.set("unsupported", forKey: AppLanguage.preferenceKey)
    #expect(AppLanguage.load(from: defaults) == .russian)

    for language in AppLanguage.allCases {
        language.save(to: defaults)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(AppLanguage.load(from: reopened) == language)
        #expect(reopened.stringArray(forKey: "AppleLanguages") == [language.rawValue])
    }
}

@Test func localizedCopyPreservesInterpolatedUserContent() {
    let title = "Проект \"Example\" — 日本語" // Data must not be translated or interpreted as a key.
    #expect(L10n.text("Чат: \(title)", "Chat: \(title)", language: .english) == "Chat: \(title)")
    #expect(L10n.text("Чат: \(title)", "Chat: \(title)", language: .russian) == "Чат: \(title)")
    #expect(AppLanguage.russian.locale.language.languageCode?.identifier == "ru")
    #expect(AppLanguage.english.locale.language.languageCode?.identifier == "en")
}
