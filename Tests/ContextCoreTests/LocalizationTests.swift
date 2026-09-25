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

@Test func pluginStatusAndMetricsChooseTheRequestedLanguage() throws {
    let payload = Data(#"{"protocolVersion":1,"pluginID":"example","pluginVersion":"1","instance":"test","detail":"Исходный текст","detailTranslations":{"ru":"Подключён","en":"Connected"},"metrics":[{"id":"requests","title":"Запросов","value":3,"titleTranslations":{"ru":"Запросов","en":"Requests"}}]}"#.utf8)
    let status = try JSONDecoder().decode(PluginStatus.self, from: payload)
    #expect(status.localizedDetail(language: .english) == "Connected")
    #expect(status.localizedDetail(language: .russian) == "Подключён")
    #expect(status.metrics[0].localizedTitle(language: .english) == "Requests")
    #expect(status.metrics[0].localizedTitle(language: .russian) == "Запросов")
    let legacy = Data(#"{"protocolVersion":1,"pluginID":"example","pluginVersion":"1","instance":"test","detail":"Third-party text","metrics":[{"id":"requests","title":"Custom label","value":3}]}"#.utf8)
    let unchanged = try JSONDecoder().decode(PluginStatus.self, from: legacy)
    #expect(unchanged.localizedDetail(language: .english) == "Third-party text")
    #expect(unchanged.metrics[0].localizedTitle(language: .russian) == "Custom label")
}

@Test func pluginTranslationsRequireBothLanguagesWhenProvided() throws {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PluginTranslations.self, from: Data(#"{"ru":"Текст"}"#.utf8))
    }
    let blank = try JSONDecoder().decode(PluginTranslations.self, from: Data(#"{"ru":"Текст","en":" "}"#.utf8))
    #expect(!blank.isValid(maxLength: 100))
}
