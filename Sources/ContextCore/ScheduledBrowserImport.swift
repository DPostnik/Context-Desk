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
        let tool = engine == .claude ? ScheduledBrowserImport.claudeImportTool : "browser_import_session"
        return prompt + "\n\n" + ScheduledBrowserImport.instructions(policy, tool: tool, language: language)
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

/// Result of the app-side sign-in transfer that runs before the first model turn of a scheduled run.
public enum ScheduledBrowserPreflight: Equatable, Sendable {
    /// Site cookies were written to and read back from the run's fresh profile; website sign-in is not yet verified.
    case imported(verified: Int)
    /// Definite failure; nothing that could need a retry was left behind.
    case blocked(ChromeCookieError)
    /// The write may have happened. Never retried in this run.
    case uncertain
    /// Wildcard policy: the site is known only once the agent opens a page, so the agent keeps the import step.
    case skipped
}

extension ScheduledBrowserImport {
    /// Transfers only the policy site's cookies into the run's own fresh profile, once, before dispatch.
    /// A fresh per-run profile has no cookies, so missing sign-in is certain and no agent turn is spent observing it.
    public static func preflight(_ policy: ChromeSessionImportPolicy, session: AgentSessionReference, runtime: URL, maxBrowsers: Int,
                                 root: URL = BrowserEnvironmentStore.directory, sourceIsRunning: @escaping @Sendable () -> Bool,
                                 read: (@Sendable (String, String) throws -> ChromeCookieRead)? = nil,
                                 transfer: (@Sendable (ChromeCookieRead, URL, BrowserProfileGrant) async throws -> ChromeCookieImportResult)? = nil) async -> ScheduledBrowserPreflight {
        guard !policy.coversAnySite else { return .skipped }
        do {
            let store = BrowserProfileStore(root: root)
            guard let profile = try store.current(session: session) else { return .blocked(.missingEnvironment) }
            let environment = store.environment(profile.id)
            let grant = try store.ownedGrant(session: session, allowHuman: false)
            let cookies = try (read ?? { try ChromeCookieSource.read(profile: $0, site: $1, sourceIsRunning: sourceIsRunning) })(policy.profile, policy.site)
            guard !cookies.cookies.isEmpty else { return .blocked(.empty) }
            let result = try await (transfer ?? { read, environment, grant in
                try await ChromeCookieImporter.transfer(read, environment: environment, runtime: runtime, maxBrowsers: maxBrowsers,
                                                        grant: grant, browserRoot: root)
            })(cookies, environment, grant)
            return result.verified > 0 ? .imported(verified: result.verified) : .blocked(.empty)
        } catch let error as ChromeCookieError {
            return error == .uncertain ? .uncertain : .blocked(error)
        } catch {
            return .blocked(.connection)
        }
    }

    /// Run instructions after the preflight. The import step is replaced; the agent never imports again in this run.
    public static func instructions(_ policy: ChromeSessionImportPolicy, preflight: ScheduledBrowserPreflight, tool: String = "browser_import_session",
                                    language: AppLanguage = L10n.language) -> String {
        let site = policy.site
        let tail = L10n.text(
            " Не вызывай \(tool) в этом запуске и не закрывай обычный Chrome. Если вход недоступен, укажи один конкретный blocker и продолжай независимые этапы исходной задачи. Это не расширяет права на отправку сообщений, приглашений, заявок или другие внешние действия.",
            " Do not call \(tool) in this run and do not close regular Chrome. If sign-in is unavailable, report one specific blocker and continue independent stages of the original task. This does not expand authority to send messages, invitations, applications or perform other external actions.", language: language)
        switch preflight {
        case .skipped:
            return instructions(policy, tool: tool, language: language)
        case .imported(let verified):
            return L10n.text(
                "Context Desk до начала запуска перенёс в браузер этой задачи cookies сайта \(site) из выбранного профиля Chrome (подтверждено: \(verified)). Вход на сайте ещё не проверен: открой \(site) обычным действием и проверь доступ к защищённому содержимому. Если сайт всё равно просит войти, значит сессия в обычном Chrome истекла — blocker: «войди в \(site) в обычном Chrome».",
                "Before this run, Context Desk transferred \(site) cookies from the selected Chrome profile into this task's browser (\(verified) confirmed). Website sign-in is not verified yet: open \(site) normally and check access to protected content. If the site still asks to sign in, the session in regular Chrome has expired — blocker: \"sign in to \(site) in regular Chrome\".", language: language) + tail
        case .uncertain:
            return L10n.text(
                "Context Desk пытался до начала запуска перенести cookies сайта \(site), но результат не подтверждён; повтора не было. Проверь вход обычным чтением страницы.",
                "Before this run, Context Desk attempted to transfer \(site) cookies, but the outcome is unconfirmed; it was not retried. Check sign-in by reading the page normally.", language: language) + tail
        case .blocked(let error):
            return L10n.text(
                "Context Desk не смог до начала запуска перенести вход на сайт \(site): \(error.message(language: language)) Считай \(site) недоступным без входа в этом запуске.",
                "Before this run, Context Desk could not transfer sign-in for \(site): \(error.message(language: language)) Treat \(site) as unavailable without sign-in in this run.", language: language) + tail
        }
    }

    /// Swaps the standard import paragraph that `browserExecutionPrompt` appended for the preflight outcome.
    public static func applying(_ preflight: ScheduledBrowserPreflight, policy: ChromeSessionImportPolicy, to prompt: String,
                                tool: String, language: AppLanguage = L10n.language) -> String {
        let standard = instructions(policy, tool: tool, language: language)
        let replacement = instructions(policy, preflight: preflight, tool: tool, language: language)
        guard standard != replacement else { return prompt }
        return prompt.contains(standard) ? prompt.replacingOccurrences(of: standard, with: replacement) : prompt + "\n\n" + replacement
    }
}
