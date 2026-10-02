import AppKit
import SwiftUI
import ContextCore

struct ChromeCookieImportView: View {
    let session: String
    let onImported: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [ChromeCookieProfile] = []
    @State private var selection = ""
    @State private var loading = true
    @State private var importing = false
    @State private var error: String?
    @State private var result: ChromeCookieImportResult?
    @AppStorage("chromeCookieSourceProfile") private var lastProfile = "Default"
    @AppStorage("parallelBrowserLimit") private var maxBrowsers = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Импортировать входы из Chrome", "Import sign-ins from Chrome")).font(.title2.bold())
            Text(L10n.text("Cookies сайтов из выбранного профиля станут доступны браузеру и агенту этого чата. Они сохранятся в его отдельном профиле.",
                           "Website cookies from the selected profile will be available to this chat’s browser and agent. They will stay in its separate profile."))
            Text(L10n.text("Заверши обычный Google Chrome через Cmd+Q. Если браузер чата открыт, сначала закрой его через меню «Браузер». macOS может запросить доступ к Chrome Safe Storage в Связке ключей.",
                           "Quit regular Google Chrome with Cmd+Q. If this chat’s browser is open, close it from the Browser menu first. macOS may request access to Chrome Safe Storage in Keychain."))
                .font(.callout)
            if loading {
                ProgressView(L10n.text("Поиск профилей…", "Finding profiles…"))
            } else if !profiles.isEmpty {
                Picker(L10n.text("Профиль Chrome", "Chrome profile"), selection: $selection) {
                    ForEach(profiles) { profile in Text("\(profile.name) (\(profile.id))").tag(profile.id) }
                }.disabled(importing)
            }
            Text(L10n.text("Импорт заменит совпадающие cookies. Некоторые сайты потребуют входа заново. Пароли и файлы авторизации Codex / Claude Code не переносятся.",
                           "Import replaces matching cookies. Some sites will require signing in again. Passwords and Codex / Claude Code authentication files are not transferred."))
                .font(.caption).foregroundStyle(.secondary)
            if let result {
                Text(L10n.text("Проверено cookies: \(result.verified). Пропущено: \(result.skipped). Не подтверждено: \(result.unverified). Открой нужный сайт в браузере чата и проверь вход.",
                               "Cookies verified: \(result.verified). Skipped: \(result.skipped). Unverified: \(result.unverified). Open the site in this chat’s browser to check your sign-in."))
                    .textSelection(.enabled)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L10n.text("Обновить профили", "Refresh profiles")) { loadProfiles() }
                    .disabled(loading || importing)
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Button(L10n.text("Закрыть", "Close")) { dismiss() }.disabled(importing)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Импортировать", "Import")) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(importing || loading || selection.isEmpty || result != nil)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(importing)
        .onAppear { loadProfiles() }
    }

    private func loadProfiles() {
        loading = true; error = nil; result = nil
        Task {
            defer { loading = false }
            do {
                profiles = try await Task.detached { try ChromeCookieSource.profiles() }.value
                selection = profiles.contains(where: { $0.id == lastProfile }) ? lastProfile : profiles.first?.id ?? ""
                if profiles.isEmpty { error = L10n.text("Профили обычного Google Chrome не найдены.", "No regular Google Chrome profiles were found.") }
            } catch {
                profiles = []; selection = ""
                self.error = (error as? ChromeCookieError ?? .unavailable).localizedDescription
            }
        }
    }

    private func start() {
        guard !importing, !selection.isEmpty else { return }
        importing = true; error = nil; result = nil
        let profile = selection, nativeID = session, limit = maxBrowsers
        let resources = Bundle.main.resourceURL
        Task {
            defer { importing = false }
            do {
                guard let root = try BrowserEnvironmentStore.existingEnvironment(session: nativeID), let resources else {
                    throw ChromeCookieError.missingEnvironment
                }
                result = try await Task.detached {
                    try await ChromeCookieImporter.run(profile: profile, environment: root,
                        runtime: resources.appendingPathComponent("BrowserRuntime"), maxBrowsers: limit,
                        sourceIsRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty })
                }.value
                lastProfile = profile
                onImported()
            } catch {
                self.error = (error as? ChromeCookieError ?? .unavailable).localizedDescription
            }
        }
    }
}
