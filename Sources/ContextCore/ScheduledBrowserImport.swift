import Foundation

extension ManagedJob {
    public func validateBrowserSessionImport() throws {
        guard let policy = browserSessionImport else { return }
        guard engine == .codex || engine == .claude,
              try ChromeSessionImportPolicy(profile: policy.profile, site: policy.site) == policy else {
            throw ClientFailure(L10n.text("Импорт сессии доступен только для заданий Codex или Claude Code с корректным доменом и профилем Chrome.",
                                          "Session import requires a Codex or Claude Code task with a valid site domain and Chrome profile."))
        }
    }

    /// Keep the saved user prompt/frozen routine intact; derive run instructions from explicit metadata.
    public func browserExecutionPrompt(language: AppLanguage = L10n.language) throws -> String {
        try validateBrowserSessionImport()
        guard let policy = browserSessionImport else { return prompt }
        return prompt + "\n\n" + ScheduledBrowserImport.instructions(policy, language: language)
    }
}

public enum ScheduledBrowserImport {
    /// Claude Code exposes MCP tools as `mcp__<server>__<tool>`; Codex uses the plain tool name.
    public static let claudeImportTool = "mcp__context_desk_browser__browser_import_session"

    public static func instructions(_ policy: ChromeSessionImportPolicy, tool: String = "browser_import_session",
                                    language: AppLanguage = L10n.language) -> String {
        let ru = policy.coversAnySite ? "любого сайта, на котором не хватает входа (только cookies, которые Chrome отправил бы этой странице)," : "сайта \(policy.site)"
        let en = policy.coversAnySite ? "any site where sign-in is missing (only the cookies Chrome would send to that page)" : policy.site
        return L10n.text(
            "Для этой задачи постоянно разрешён импорт cookies \(ru) из выбранного пользователем профиля Chrome. Это разрешение действует в каждом запуске; повторно спрашивать разрешение на этот импорт не нужно. Сначала проверь вход обычным чтением страницы. Только при подтверждённом отсутствии авторизации вызови \(tool) с session своей вкладки и её текущим expectedURL. После подтверждённого импорта один раз обнови страницу отдельным действием и проверь доступ к защищённому содержимому; количество cookies не подтверждает вход. Не повторяй импорт в этом запуске и не повторяй действия с неизвестным исходом. Если инструмент недоступен, обычный Chrome не дал прочитать cookies, Связка ключей требует участия пользователя или вход не восстановлен — укажи конкретный blocker и продолжай независимые этапы исходной задачи. Не закрывай обычный Chrome автоматически. Сетевые ошибки, CAPTCHA и блокировки сайта не являются основанием для импорта. Это разрешение не расширяет права на отправку сообщений, приглашений, заявок или другие внешние действия.",
            "This task has standing permission to import cookies for \(en) from the user-selected Chrome profile on every run. Do not ask again for permission to perform this import. First check sign-in by reading the page normally. Only after observing missing authentication, call \(tool) with your own tab's session and current expectedURL. After a confirmed import, reload once with a separate action and verify access to protected content; cookie counts do not confirm sign-in. Do not repeat import in this run or replay actions with unknown outcomes. If the tool is unavailable, regular Chrome blocked reading cookies, Keychain needs user interaction, or sign-in is not restored, report the specific blocker and continue independent stages of the original task. Do not close regular Chrome automatically. Network errors, CAPTCHA and site blocks are not reasons to import. This permission does not expand authority to send messages, invitations, applications or perform other external actions.", language: language)
    }

    public static var unavailable: ClientFailure {
        ClientFailure(L10n.text("Для восстановления входа в задании включи браузер Context Desk и переподключи Codex или Claude Code.",
                                "Enable the Context Desk browser and reconnect Codex or Claude Code to restore sign-in for this task."))
    }

    /// Runs after the fresh chat is durably attached, before its first model turn.
    /// Does not access source cookies or Keychain and never changes another profile's permission.
    public static func install(_ policy: ChromeSessionImportPolicy, session: AgentSessionReference, browserEnabled: Bool,
                               root: URL = BrowserEnvironmentStore.directory) throws {
        guard browserEnabled, session.connection == .originalCodex || session.connection == .appClaude else { throw unavailable }
        let checked = try ChromeSessionImportPolicy(profile: policy.profile, site: policy.site)
        let store = BrowserProfileStore(root: root)
        guard let profile = try store.current(session: session) else { throw ChromeCookieError.missingEnvironment }
        let environment = store.environment(profile.id)
        let grant = try store.ownedGrant(session: session, allowHuman: false)
        try ChromeSessionImportPolicy.save(checked, environment: environment, grant: grant, browserRoot: root)
    }
}
