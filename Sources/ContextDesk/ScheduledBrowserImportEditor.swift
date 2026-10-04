import SwiftUI
import ContextCore

struct ScheduledBrowserImportEditor: View {
    @Binding var policy: ChromeSessionImportPolicy?
    @State private var profiles: [ChromeCookieProfile] = []
    @State private var selection = "Default"
    @State private var site = "linkedin.com"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Автоматическое восстановление входа", "Automatic sign-in recovery")).font(.headline)
            Text(L10n.text("Разрешение сохраняется у задания и применяется к каждому новому запуску. Агент сам импортирует cookies при отсутствии входа. Обычный Chrome должен быть закрыт; Связка ключей может потребовать подтверждения.",
                           "Permission is saved with the task and applied to every new run. The agent imports cookies when sign-in is missing. Regular Chrome must be closed; Keychain may require confirmation."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("Профиль Chrome", "Chrome profile"), selection: $selection) {
                ForEach(profiles) { Text($0.name + " (" + $0.id + ")").tag($0.id) }
            }
            TextField(L10n.text("Домен сайта", "Site domain"), text: $site)
            HStack {
                Button(L10n.text("Разрешить для всех запусков", "Allow for every run")) {
                    do { policy = try ChromeSessionImportPolicy(profile: selection, site: site); error = nil }
                    catch { self.error = L10n.text("Проверь домен сайта и профиль Chrome.", "Check the site domain and Chrome profile.") }
                }.disabled(profiles.isEmpty)
                Button(L10n.text("Отключить", "Disable")) { policy = nil }.disabled(policy == nil)
            }
            if let policy {
                Text(L10n.text("Разрешено после сохранения задания: ", "Allowed when the task is saved: ") + policy.site + " · " + policy.profile).font(.caption)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task {
            if let policy { site = policy.site; selection = policy.profile }
            do {
                profiles = try await Task.detached { try ChromeCookieSource.profiles() }.value
                if !profiles.contains(where: { $0.id == selection }) { selection = profiles.first?.id ?? "" }
            } catch {
                self.error = L10n.text("Не удалось прочитать список профилей Chrome.", "Could not read the Chrome profile list.")
            }
        }
    }
}
