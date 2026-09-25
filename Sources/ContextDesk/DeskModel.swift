import AppKit
import Foundation
import SwiftUI
import UserNotifications
import ContextCore

struct PendingAction: Identifiable {
    let id: String
    let rpcID: JSONValue
    let method: String
    let params: JSONValue
    var threadID: String { params["threadId"].string ?? "" }
    var title: String { method.contains("requestUserInput") ? L10n.text("Нужен твой ответ", "Your input is needed") : L10n.text("Требуется действие", "Action required") }
}

struct DeskNotice: Identifiable {
    let id = UUID()
    let threadID: String
    let title: String
    let detail: String
    var completionID: String? = nil
    var actionID: String? = nil
}

private struct ChatRunState {
    var running = false
    var sending = false
    var stopRequested = false
    var turnID: String?
    var queuePaused = true
    var priorityMessageID: String?
}

@MainActor final class DeskModel: ObservableObject {
    @Published private(set) var plugins: [ProviderPlugin] = []
    @Published private(set) var pluginIssues: [String] = []
    @Published private(set) var pluginStatuses: [String: PluginStatus] = [:]
    @Published private(set) var pluginMessages: [String: String] = [:]
    let pluginDirectory: URL
    private var pluginRuntimes: [String: ProviderPluginRuntime] = [:]
    private var pluginTask: Task<Void, Never>?
    @Published var notices: [DeskNotice] = []
    @Published private(set) var unreadResponseItems: [String: String] = [:]
    private var notifiedTurns: Set<String> = []
    @Published var state = SavedState()
    @Published var projectID: UUID?
    @Published var chatID: String?
    @Published var showingArchive = false
    @Published var archiveViewingChat = false
    @Published var showingJobs = false
    @Published var jobs: [ScheduledJob] = []
    @Published var items: [TranscriptItem] = []
    @Published var pending: [PendingAction] = []
    @Published var usage: [String: UsageSnapshot] = [:]
    @Published var models: [JSONValue] = []
    @Published var effort = ""
    private var newChatDrafts: [UUID: String] = [:]
    private var chatDrafts: [String: String] = [:]
    @Published var draft = "" {
        didSet {
            if let chatID {
                chatDrafts[chatID] = draft.isEmpty ? nil : draft
            } else if let projectID {
                newChatDrafts[projectID] = draft.isEmpty ? nil : draft
            }
        }
    }
    @Published var connected = false
    @Published var authenticated = false
    @Published var connecting = false
    @Published private(set) var isBootstrapping = true
    @Published private var runs: [String: ChatRunState] = [:]
    @Published private(set) var deletingChatIDs: Set<String> = []
    @Published private(set) var archivingChatIDs: Set<String> = []
    func isChangingChat(_ id: String) -> Bool { deletingChatIDs.contains(id) || archivingChatIDs.contains(id) }
    func isArchived(_ id: String) -> Bool { state.chats.first { $0.id == id }?.isArchived == true }
    var selectedChatIsArchived: Bool { selectedChat?.isArchived == true }
    private var completedTurns: [String: (status: String?, hasError: Bool)] = [:]
    private var currentRunKey: String { chatID ?? "new:" + selectionGeneration.uuidString }
    var sending: Bool { runs[currentRunKey]?.sending == true }
    var busy: Bool { runs[currentRunKey]?.running == true }
    var queuePaused: Bool { runs[currentRunKey]?.queuePaused ?? true }
    var priorityMessageID: String? { runs[currentRunKey]?.priorityMessageID }
    var anyBusy: Bool { !deletingChatIDs.isEmpty || !archivingChatIDs.isEmpty || runs.values.contains { $0.running || $0.sending } }
    func isBusy(threadID: String) -> Bool { runs[threadID]?.running == true }
    private func resetRuns() { runs.removeAll() }
    @Published var loadingChat = false
    @Published var accountLabel = L10n.text("Вход не выполнен", "Not signed in")
    @Published var error: String?
    @Published private(set) var accountLimits: AccountLimits?
    @Published private(set) var limitsError: String?
    @Published private(set) var refreshingLimits = false
    private var limitsRequestID: UUID?
    @Published var notificationStatus = L10n.text("Уведомления не включены", "Notifications are off")
    private var loadedThreads: Set<String> = []
    private var eventTask: Task<Void, Never>?
    private var deltaTask: Task<Void, Never>?
    private var deltas: [String: String] = [:]
    private var selectionGeneration = UUID()
    private var booted = false
    let connection: CodexConnection
    let store: AppStore
    init(connection: CodexConnection = CodexConnection(), store: AppStore = AppStore(file: Locations.root.appendingPathComponent("metadata.sqlite")),
         pluginDirectory: URL = PluginCatalog.defaultDirectory) {
        self.connection = connection
        self.store = store
        self.pluginDirectory = pluginDirectory
        refreshPlugins()
    }

    var selectedProject: Project? { state.projects.first { $0.id == projectID } }
    var selectedChat: Chat? { state.chats.first { $0.id == chatID } }
    var chats: [Chat] { projectID.map { state.orderedChats(projectID: $0, archived: false) } ?? [] }
    var currentAction: PendingAction? { pending.first { $0.threadID == chatID } }
    var currentUsage: UsageSnapshot? { chatID.flatMap { usage[$0] } }
    var canSend: Bool { !selectedChatIsArchived && !isChangingChat(currentRunKey) && routeIsAvailable(currentRoute) && connected && authenticated && selectedProject != nil && !sending && !loadingChat && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var supportedEfforts: [String] {
        models.first { $0["model"].string == state.model }?["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string } ?? []
    }

    func boot() async {
        guard !booted else { return }; booted = true
        defer { isBootstrapping = false }
        do { state = try await store.load(); usage = try await store.loadUsage(); projectID = state.projects.first?.id } catch { self.error = error.localizedDescription }
        for chat in state.chats where chat.hasUnreadResponse {
            let project = state.projects.first { $0.id == chat.projectID }
            notices.append(DeskNotice(threadID: chat.id, title: L10n.text("Непрочитанный ответ", "Unread response"),
                                      detail: [project?.name, chat.title].compactMap { $0 }.joined(separator: " · "),
                                      completionID: chat.unreadCompletionID))
        }
        await refreshJobs()
        eventTask = Task { [weak self, connection] in
            for await event in connection.events { await self?.receive(event) }
        }
        await connect()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus == .authorized ? L10n.text("Уведомления включены", "Notifications are on") : L10n.text("Уведомления не включены", "Notifications are off")
    }
    var defaultRoute: RequestRoute { state.defaultRoute ?? .direct }
    var currentRoute: RequestRoute { selectedChat.map { $0.route ?? .direct } ?? defaultRoute }
    var neededPluginIDs: Set<String> {
        Set(([defaultRoute] + state.chats.compactMap(\.route)).filter { $0 != .direct }.map(\.rawValue))
    }
    var availableRoutes: [RequestRoute] {
        [.direct] + Set(plugins.map(\.route) + [defaultRoute, currentRoute] + state.chats.compactMap(\.route))
            .filter { $0 != .direct }.sorted { $0.rawValue < $1.rawValue }
    }
    func routeTitle(_ route: RequestRoute, language: AppLanguage = L10n.language) -> String {
        if route == .direct { return L10n.text("Без плагина", "No plugin", language: language) }
        return plugins.first(where: { $0.id == route.rawValue })?.manifest.localizedTitle(language: language)
            ?? L10n.text("\(route.rawValue) (не установлен)", "\(route.rawValue) (not installed)", language: language)
    }
    func routeIsAvailable(_ route: RequestRoute) -> Bool { route == .direct || pluginStatuses[route.rawValue] != nil }
    func routeMessage(_ route: RequestRoute, language: AppLanguage = L10n.language) -> String {
        if route == .direct { return L10n.text("Codex работает напрямую, без обработки запросов плагином.", "Codex works directly, without a plugin processing requests.", language: language) }
        if connecting && neededPluginIDs.contains(route.rawValue) {
            return L10n.text("Подключение…", "Connecting…", language: language)
        }
        if let status = pluginStatuses[route.rawValue] { return status.localizedDetail(language: language) }
        if let message = pluginMessages[route.rawValue] { return message }
        guard plugins.contains(where: { $0.id == route.rawValue }) else {
            return L10n.text("Плагин не установлен. Выбор для этого чата сохранён.", "Plugin is not installed. This chat's selection has been preserved.", language: language)
        }
        return neededPluginIDs.contains(route.rawValue)
            ? L10n.text("Установлен. Нажми «Применить выбор», чтобы подключить.", "Installed. Click Apply selection to connect.", language: language)
            : L10n.text("Установлен, но не используется.", "Installed, but not in use.", language: language)
    }
    func refreshPlugins() {
        guard !anyBusy, !connecting else { return }
        let catalog = PluginCatalog.scan(directory: pluginDirectory)
        plugins = catalog.plugins; pluginIssues = catalog.issues
    }
    func selectDefaultRoute(_ route: RequestRoute) { state.defaultRoute = route; persist() }
    private func stopPlugins() async {
        pluginTask?.cancel(); pluginTask = nil
        for runtime in pluginRuntimes.values { await runtime.stop() }
        pluginRuntimes.removeAll(); pluginStatuses.removeAll()
    }
    func connect() async {
        guard !connecting, !anyBusy else { return }
        refreshPlugins()
        connecting = true; connected = false
        clearLimits()
        defer { connecting = false }
        await connection.stop(); loadedThreads.removeAll()
        await stopPlugins()
        pluginMessages.removeAll()
        var arguments: [String] = []
        for id in neededPluginIDs.sorted() {
            guard let plugin = plugins.first(where: { $0.id == id }) else {
                pluginMessages[id] = L10n.text("Плагин не установлен. Установи его и нажми «Применить выбор».", "Plugin is not installed. Install it, then click Apply selection.")
                continue
            }
            let runtime = ProviderPluginRuntime(plugin: plugin)
            do {
                let endpoint = try await runtime.start()
                let status = try await runtime.status()
                arguments += try plugin.providerArguments(endpoint: endpoint)
                pluginStatuses[id] = status
                pluginRuntimes[id] = runtime
            } catch {
                await runtime.stop()
                pluginMessages[id] = error.localizedDescription
            }
        }
        do {
            try await connection.start(executable: Locations.codexExecutable(), home: Locations.codexHome, extraArguments: arguments)
            connected = true
            clearConnectionError()
            await refreshAccount()
            if !pluginRuntimes.isEmpty {
                pluginTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self else { return }
                        for id in self.pluginRuntimes.keys.sorted() {
                            guard let runtime = self.pluginRuntimes[id] else { continue }
                            do {
                                let status = try await runtime.status()
                                guard !Task.isCancelled else { return }
                                self.pluginStatuses[id] = status
                            } catch {
                                guard !Task.isCancelled else { return }
                                self.pluginStatuses[id] = nil
                                self.pluginMessages[id] = error.localizedDescription
                                await runtime.stop()
                                self.pluginRuntimes[id] = nil
                                let affected = self.state.chats.filter { $0.route?.rawValue == id }
                                for chat in affected { self.runs[chat.id, default: ChatRunState()].queuePaused = true }
                                if affected.contains(where: { self.isBusy(threadID: $0.id) }) {
                                    await self.connection.stop()
                                    self.connected = false
                                    self.resetRuns(); self.pending.removeAll()
                                    self.error = L10n.text("Плагин отключился. Запрос не повторён.", "The plugin disconnected. The request was not retried.")
                                    return
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            connected = false; self.error = error.localizedDescription
            await stopPlugins()
        }
    }
    func refreshAccount() async {
        do {
            let result = try await connection.request("account/read", params: .object(["refreshToken": .bool(false)]))
            clearConnectionError()
            authenticated = result["account"] != .null
            accountLabel = authenticated ? L10n.text("ChatGPT · \(result["account"]["planType"].string ?? "подключён")", "ChatGPT · \(result["account"]["planType"].string ?? "connected")") : L10n.text("Вход не выполнен", "Not signed in")
            if authenticated { await refreshModels(); await refreshLimits() }
            else { clearLimits() }
        } catch { self.error = error.localizedDescription }
    }
    // A successful server response makes an earlier transport warning obsolete.
    // Keep unrelated errors (for example, persistence failures) visible.
    private func clearConnectionError() {
        guard let error else { return }
        let transportErrors = [
            L10n.text("Codex не подключён", "Codex is not connected"),
            L10n.text("Соединение закрыто", "Connection closed"),
            L10n.text("Соединение с Codex закрыто", "The connection to Codex is closed"),
            L10n.text("Codex отключился. Подключись заново; отправка не будет повторена автоматически.", "Codex disconnected. Reconnect; the message will not be sent again automatically.")
        ]
        if transportErrors.contains(error) { self.error = nil }
    }
    func login() async {
        do {
            let result = try await connection.request("account/login/start", params: .object(["type": .string("chatgpt")]))
            guard let text = result["authUrl"].string, let url = URL(string: text),
                  url.scheme == "https", let host = url.host,
                  host == "chatgpt.com" || host == "auth.openai.com" || host.hasSuffix(".openai.com") else {
                throw ClientFailure(L10n.text("Движок не вернул допустимую ссылку входа", "The engine did not return a valid sign-in link"))
            }
            NSWorkspace.shared.open(url)
            accountLabel = L10n.text("Заверши вход в браузере", "Finish signing in in your browser")
        } catch { self.error = error.localizedDescription }
    }
    func logout() async {
        guard !anyBusy else { return }
        do { _ = try await connection.request("account/logout"); authenticated = false; clearLimits(); await refreshAccount() }
        catch { self.error = error.localizedDescription }
    }
    func refreshModels() async {
        do {
            let result = try await connection.request("model/list", params: .object(["limit": .number(100), "includeHidden": .bool(false)]))
            models = result["data"].array
            if !models.contains(where: { $0["model"].string == state.model }) {
                state.model = (models.first { $0["isDefault"].bool == true } ?? models.first)?["model"].string ?? ""
            }
            selectModel(state.model)
        } catch { self.error = error.localizedDescription }
    }
    func selectModel(_ model: String) {
        state.model = model
        effort = models.first { $0["model"].string == model }?["defaultReasoningEffort"].string ?? ""
        persist()
    }
    func refreshLimits() async {
        guard connected, authenticated, !refreshingLimits else { return }
        let requestID = UUID()
        limitsRequestID = requestID
        refreshingLimits = true
        limitsError = nil
        defer {
            if limitsRequestID == requestID { refreshingLimits = false; limitsRequestID = nil }
        }
        do {
            let result = try await connection.request("account/rateLimits/read")
            guard limitsRequestID == requestID, authenticated, connected else { return }
            accountLimits = AccountLimits(response: result)
        } catch {
            guard limitsRequestID == requestID else { return }
            limitsError = accountLimits == nil
                ? L10n.text("Не удалось получить лимиты. Попробуй обновить ещё раз.", "Could not fetch limits. Try refreshing again.")
                : L10n.text("Не удалось обновить лимиты. Показаны последние полученные данные.", "Could not refresh limits. Showing the last available data.")
        }
    }
    private func clearLimits() {
        limitsRequestID = nil
        refreshingLimits = false
        accountLimits = nil
        limitsError = nil
    }
    func moveProject(_ id: UUID, to targetID: UUID) -> Bool {
        guard state.moveProject(id, to: targetID) else { return false }
        persist()
        return true
    }

    func moveChat(_ id: String, to targetID: String) -> Bool {
        guard !isChangingChat(id), !isChangingChat(targetID), state.moveChat(id, to: targetID) else { return false }
        persist()
        return true
    }

    func toggleChatPin(_ id: String) {
        if state.toggleChatPin(id) { persist() }
    }

    func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.prompt = L10n.text("Добавить папки", "Add folders")
        panel.message = L10n.text("Выбери папки проектов. У каждой папки будет свой список чатов.", "Choose project folders. Each folder will have its own list of chats.")
        guard panel.runModal() == .OK else { return }
        var firstID: UUID?
        for url in panel.urls {
            let path = url.resolvingSymlinksInPath().path
            let project = state.projects.first { $0.path == path } ?? Project(path: path)
            if !state.projects.contains(where: { $0.id == project.id }) { state.projects.append(project) }
            if firstID == nil { firstID = project.id }
        }
        persist()
        if let firstID { selectProject(firstID) }
    }
    func openArchive() {
        showingJobs = false
        archiveViewingChat = false
        showingArchive = true
    }
    func closeArchive() {
        showingArchive = false
        archiveViewingChat = false
        if selectedChatIsArchived { newChat() }
    }
    func selectProject(_ id: UUID) {
        showingArchive = false
        guard projectID != id || chatID != nil else { showingJobs = false; return }
        projectID = id; showingJobs = false
        newChat()
    }
    func newChat() {
        showingArchive = false
        selectionGeneration = UUID(); chatID = nil; items = []
        draft = projectID.flatMap { newChatDrafts[$0] } ?? ""
        showingJobs = false; loadingChat = false
    }
    func openChat(_ chat: Chat) async {
        guard !isChangingChat(chat.id), state.chats.contains(where: { $0.id == chat.id }) else { return }
        showingArchive = isArchived(chat.id)
        archiveViewingChat = showingArchive
        showingJobs = false; projectID = chat.projectID; chatID = chat.id
        draft = chatDrafts[chat.id] ?? ""
        let generation = UUID(); selectionGeneration = generation
        loadingChat = true; items = []
        do {
            let result = try await connection.request("thread/read", params: .object(["threadId": .string(chat.id), "includeTurns": .bool(true)]))
            guard selectionGeneration == generation else { return }
            let turns = result["thread"]["turns"].array
            items = turns.flatMap { $0["items"].array }.compactMap(TranscriptItem.parse)
            if let completion = state.chats.first(where: { $0.id == chat.id })?.unreadCompletionID,
               let turn = turns.first(where: { "turn:" + chat.id + ":" + ($0["id"].string ?? "") == completion }) {
                unreadResponseItems[chat.id] = turn["items"].array.compactMap(TranscriptItem.parse).last(where: { $0.kind == "assistant" })?.id
            }
        } catch { if selectionGeneration == generation { self.error = error.localizedDescription } }
        if selectionGeneration == generation { loadingChat = false }
    }
    func renameChat(_ id: String, title: String) async {
        guard !isChangingChat(id) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try await connection.request("thread/name/set", params: .object(["threadId": .string(id), "name": .string(title)]))
            if let i = state.chats.firstIndex(where: { $0.id == id }) { state.chats[i].title = title; persist() }
        } catch { self.error = error.localizedDescription }
    }
    func canDeleteChat(_ id: String) -> Bool {
        connected && state.chats.contains(where: { $0.id == id }) &&
        !isChangingChat(id) && !isBusy(threadID: id) &&
        runs[id]?.sending != true && !pending.contains(where: { $0.threadID == id })
    }
    func setChatArchived(_ id: String, archived: Bool) async {
        guard canDeleteChat(id), isArchived(id) != archived else { return }
        archivingChatIDs.insert(id)
        runs[id, default: ChatRunState()].queuePaused = true
        defer { archivingChatIDs.remove(id) }
        do {
            _ = try await connection.request(archived ? "thread/archive" : "thread/unarchive",
                                             params: .object(["threadId": .string(id)]))
        } catch {
            self.error = (archived ? L10n.text("Не удалось подтвердить архивирование: ", "Could not confirm archiving: ") : L10n.text("Не удалось подтвердить восстановление: ", "Could not confirm restoring: ")) + error.localizedDescription
            return
        }
        guard let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
        state.chats[index].archived = archived
        if chatID == id {
            if archived { openArchive() }
            else { archiveViewingChat = false }
        }
        state.chats[index].sidebarOrder = nil
        loadedThreads.remove(id)
        do { try await store.save(state) }
        catch { self.error = L10n.text("Статус чата изменён в Codex, но не удалось сохранить его в приложении: ", "The chat status changed in Codex, but could not be saved in the app: ") + error.localizedDescription }
    }
    func deleteChat(_ id: String) async {
        guard canDeleteChat(id) else { return }
        deletingChatIDs.insert(id)
        let wasPaused = runs[id]?.queuePaused ?? true
        runs[id, default: ChatRunState()].queuePaused = true
        defer { deletingChatIDs.remove(id) }
        do {
            _ = try await connection.request("thread/delete", params: .object(["threadId": .string(id)]))
        } catch {
            // Keep the chat and queue on any unconfirmed server result. Never retry deletion.
            runs[id, default: ChatRunState()].queuePaused = true
            self.error = L10n.text("Не удалось подтвердить удаление чата: ", "Could not confirm chat deletion: ") + error.localizedDescription +
                (wasPaused ? "" : L10n.text(" Очередь этого чата приостановлена.", " This chat’s queue is paused."))
            return
        }
        state.chats.removeAll { $0.id == id }
        state.queuedMessages = queuedMessages.filter { $0.threadID != id }
        usage.removeValue(forKey: id)
        chatDrafts.removeValue(forKey: id)
        loadedThreads.remove(id)
        runs.removeValue(forKey: id)
        let notificationIDs = notifiedTurns.filter { $0.hasPrefix(id + ":") }.map { "turn:" + $0 }
        notifiedTurns = notifiedTurns.filter { !$0.hasPrefix(id + ":") }
        completedTurns = completedTurns.filter { !$0.key.hasPrefix(id + ":") }
        notices.removeAll { $0.threadID == id }
        if !notificationIDs.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: notificationIDs)
        }
        if chatID == id { newChat() }
        do { try await store.saveDeletingChat(state, threadID: id) }
        catch { self.error = L10n.text("Чат удалён в Codex, но не удалось сохранить изменения в приложении: ", "The chat was deleted in Codex, but the change could not be saved in the app: ") + error.localizedDescription }
    }
    var accessMode: AccessMode { selectedProject?.accessMode ?? .standard }
    func selectAccessMode(_ mode: AccessMode) {
        guard !busy, !sending, let index = state.projects.firstIndex(where: { $0.id == projectID }) else { return }
        state.projects[index].accessMode = mode
        persist()
    }
    var queuedMessages: [QueuedMessage] { state.queuedMessages ?? [] }
    var visibleQueue: [QueuedMessage] { queuedMessages.filter { $0.threadID == chatID } }
    func removeQueuedMessage(_ id: String) {
        guard !runs.values.contains(where: { $0.priorityMessageID == id }) else { return }
        state.queuedMessages = queuedMessages.filter { $0.id != id }
        persist()
    }
    func sendQueuedMessageNow(_ id: String) async {
        guard connected, let message = queuedMessages.first(where: { $0.id == id }),
              !isChangingChat(message.threadID), !isArchived(message.threadID) else { return }
        let thread = message.threadID
        let run = runs[thread] ?? ChatRunState()
        guard !run.sending, run.priorityMessageID == nil,
              !run.running || run.turnID != nil else { return }
        state.queuedMessages = [message] + queuedMessages.filter { $0.id != id }
        persist()
        if !run.running {
            runs[thread, default: ChatRunState()].queuePaused = false
            scheduleQueue(threadID: thread)
            return
        }
        guard let turn = run.turnID else { return }
        runs[thread, default: ChatRunState()].priorityMessageID = id
        runs[thread, default: ChatRunState()].queuePaused = true
        do {
            _ = try await connection.request("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": .string(turn)]))
            // Only matching turn/completed releases this chat's next message.
        } catch {
            if runs[thread]?.priorityMessageID == id {
                runs[thread, default: ChatRunState()].priorityMessageID = nil
                runs[thread, default: ChatRunState()].queuePaused = true
                self.error = error.localizedDescription
            }
        }
    }
    func resumeQueue() {
        guard let thread = chatID, !isChangingChat(thread), !isArchived(thread) else { return }
        runs[thread, default: ChatRunState()].queuePaused = false
        scheduleQueue(threadID: thread)
    }
    private func drainQueue(threadID: String) async {
        let run = runs[threadID] ?? ChatRunState()
        guard !isChangingChat(threadID), !isArchived(threadID), !run.queuePaused, !run.running, !run.sending, connected, authenticated,
              let next = queuedMessages.first(where: { $0.threadID == threadID }),
              let project = state.projects.first(where: { $0.id == next.projectID }) else { return }
        let route = state.chats.first(where: { $0.id == threadID })?.route ?? .direct
        if !routeIsAvailable(route) {
            runs[threadID, default: ChatRunState()].queuePaused = true
            error = routeMessage(route); return
        }
        runs[threadID, default: ChatRunState()].sending = true
        defer {
            runs[threadID, default: ChatRunState()].sending = false
            scheduleQueue(threadID: threadID)
        }
        state.queuedMessages = queuedMessages.filter { $0.id != next.id }
        do { try await store.save(state) }
        catch {
            state.queuedMessages = [next] + queuedMessages
            runs[threadID, default: ChatRunState()].queuePaused = true
            self.error = error.localizedDescription
            return
        }
        await deliver(text: next.text, project: project, threadID: threadID, localID: next.id,
                      selectedModel: next.model, selectedEffort: next.effort)
    }
    private func scheduleQueue(threadID: String) {
        let run = runs[threadID] ?? ChatRunState()
        guard !run.queuePaused, !run.running, !run.sending,
              queuedMessages.contains(where: { $0.threadID == threadID }) else { return }
        Task { await drainQueue(threadID: threadID) }
    }
    func send() async {
        guard canSend, let project = selectedProject else { return }
        let text = draft; draft = ""
        let localID = "local-user:" + UUID().uuidString
        if let thread = chatID, busy || !visibleQueue.isEmpty {
            if visibleQueue.isEmpty { runs[thread, default: ChatRunState()].queuePaused = false }
            state.queuedMessages = queuedMessages + [QueuedMessage(id: localID, threadID: thread,
                projectID: project.id, text: text, model: state.model, effort: effort)]
            persist()
            scheduleQueue(threadID: thread)
            return
        }
        await deliver(text: text, project: project, threadID: chatID, localID: localID,
                      selectedModel: state.model, selectedEffort: effort)
    }
    private func deliver(text: String, project: Project, threadID: String?, localID: String,
                         selectedModel: String, selectedEffort: String) async {
        let selection = selectionGeneration
        let visible = threadID == chatID && project.id == projectID
        if visible { items.append(TranscriptItem(id: localID, kind: "user", text: text, phase: L10n.text("Отправляется…", "Sending…"))) }
        let initialKey = threadID ?? currentRunKey
        var runKey = initialKey
        runs[runKey, default: ChatRunState()].running = true
        runs[runKey, default: ChatRunState()].sending = true
        defer {
            runs[runKey, default: ChatRunState()].sending = false
            if initialKey != runKey { runs.removeValue(forKey: initialKey) }
            scheduleQueue(threadID: runKey)
        }
        let access = project.accessMode ?? .standard
        let route = threadID == nil ? defaultRoute : (state.chats.first { $0.id == threadID }?.route ?? .direct)
        do {
            if route != .direct {
                guard let runtime = pluginRuntimes[route.rawValue], routeIsAvailable(route) else { throw ClientFailure(routeMessage(route)) }
                pluginStatuses[route.rawValue] = try await runtime.status()
            }
            var id = threadID
            if id == nil {
                var params = access.threadParameters
                params["cwd"] = .string(project.path)
                params["modelProvider"] = .string(route.providerID)
                if !selectedModel.isEmpty { params["model"] = .string(selectedModel) }
                let result = try await connection.request("thread/start", params: .object(params))
                guard let created = result["thread"]["id"].string else { throw ClientFailure(L10n.text("Не получен ID разговора", "No conversation ID received")) }
                id = created
                runs[created] = runs[runKey]
                runs.removeValue(forKey: runKey)
                runKey = created
                if visible && selectionGeneration == selection {
                    chatID = created
                    chatDrafts[created] = draft.isEmpty ? nil : draft
                    newChatDrafts.removeValue(forKey: project.id)
                }
                loadedThreads.insert(created)
                var chat = Chat(id: created, projectID: project.id, title: String(text.prefix(60)), model: selectedModel)
                chat.route = route
                state.chats.append(chat); persist()
            }
            guard let id else { throw ClientFailure(L10n.text("Не выбран разговор", "No conversation selected")) }
            if !loadedThreads.contains(id) {
                var resumeParams = access.threadParameters
                resumeParams["threadId"] = .string(id)
                resumeParams["cwd"] = .string(project.path)
                resumeParams["modelProvider"] = .string(route.providerID)
                _ = try await connection.request("thread/resume", params: .object(resumeParams))
                loadedThreads.insert(id)
            }
            var params: [String: JSONValue] = ["threadId": .string(id), "input": .array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])])]
            params.merge(access.turnParameters(projectPath: project.path)) { _, new in new }
            if !selectedModel.isEmpty { params["model"] = .string(selectedModel) }
            if !selectedEffort.isEmpty { params["effort"] = .string(selectedEffort) }
            let result = try await connection.request("turn/start", params: .object(params), timeout: 60)
            clearConnectionError()
            setDelivery(localID, phase: L10n.text("Отправлено", "Sent"))
            if let turn = result["turn"]["id"].string, runs[id]?.running == true {
                runs[id, default: ChatRunState()].turnID = turn
                if let completion = completedTurns[id + ":" + turn] {
                    finishActiveTurn(threadID: id, turnID: turn, status: completion.status, hasError: completion.hasError)
                } else if runs[id]?.stopRequested == true {
                    await interruptThread(id)
                }
            }
            if let i = state.chats.firstIndex(where: { $0.id == id }) { state.chats[i].updated = Date(); persist() }
        } catch {
            setDelivery(localID, phase: L10n.text("Доставка не подтверждена", "Delivery unconfirmed"))
            self.error = error.localizedDescription + L10n.text(" Сообщение не отправлено повторно.", " The message was not sent again.")
            runs[runKey, default: ChatRunState()].queuePaused = true
            runs[runKey, default: ChatRunState()].running = false
            runs[runKey, default: ChatRunState()].turnID = nil
            if visible && selectionGeneration == selection && draft.isEmpty { draft = text }
        }
    }
    func finishActiveTurn(threadID: String?, turnID: String?, status: String?, hasError: Bool) {
        guard let threadID, let turnID else { return }
        completedTurns[threadID + ":" + turnID] = (status, hasError)
        guard runs[threadID]?.turnID == turnID else { return }
        runs[threadID, default: ChatRunState()].running = false
        runs[threadID, default: ChatRunState()].turnID = nil
        runs[threadID, default: ChatRunState()].stopRequested = false
        if runs[threadID]?.priorityMessageID != nil && (status == "interrupted" || status == "completed") && !hasError {
            runs[threadID, default: ChatRunState()].queuePaused = false
        } else if status != "completed" || hasError {
            runs[threadID, default: ChatRunState()].queuePaused = true
        }
        runs[threadID, default: ChatRunState()].priorityMessageID = nil
        scheduleQueue(threadID: threadID)
    }
    private func setDelivery(_ id: String, phase: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].phase = phase }
    }
    func interrupt() async {
        await interruptThread(currentRunKey)
    }
    private func interruptThread(_ thread: String) async {
        runs[thread, default: ChatRunState()].priorityMessageID = nil
        runs[thread, default: ChatRunState()].queuePaused = true
        runs[thread, default: ChatRunState()].stopRequested = true
        guard let turn = runs[thread]?.turnID else { return }
        do { _ = try await connection.request("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": .string(turn)])) }
        catch { self.error = error.localizedDescription }
    }
    func refreshJobs() async {
        jobs = await Task.detached { ScheduledJobs.read(directory: Locations.automations) }.value
    }
    func enableNotifications() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            notificationStatus = allowed ? L10n.text("Уведомления включены", "Notifications are on") : L10n.text("Уведомления запрещены в настройках macOS", "Notifications are disabled in macOS Settings")
        } catch { self.error = error.localizedDescription }
    }
    private func postNotice(threadID: String, title: String, identifier: String, completionID: String? = nil, actionID: String? = nil) {
        let chat = state.chats.first { $0.id == threadID }
        let project = state.projects.first { $0.id == chat?.projectID }
        let detail = [project?.name, chat?.title].compactMap { $0 }.joined(separator: " · ")
        notices.insert(DeskNotice(threadID: threadID, title: title, detail: detail, completionID: completionID, actionID: actionID), at: 0)
        notices = Array(notices.prefix(50))
        let content = UNMutableNotificationContent()
        content.title = title; content.body = detail
        content.sound = .default; content.userInfo = ["threadID": threadID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil), withCompletionHandler: nil)
    }
    func recordUnreadCompletion(threadID: String, completionID: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == threadID }) else { return }
        state.chats[index].unreadCompletionID = completionID
        unreadResponseItems[threadID] = chatID == threadID ? items.last(where: { $0.kind == "assistant" })?.id : nil
        persist()
    }

    func markResponseRead(threadID: String, completionID: String) {
        guard chatID == threadID, !showingJobs, (!showingArchive || archiveViewingChat), !loadingChat,
              let index = state.chats.firstIndex(where: { $0.id == threadID }),
              state.chats[index].unreadCompletionID == completionID else { return }
        state.chats[index].unreadCompletionID = nil
        unreadResponseItems[threadID] = nil
        // Approval/input notices are acknowledged separately when their request is visible.
        notices.removeAll { $0.threadID == threadID && $0.completionID != nil }
        let identifiers = notifiedTurns.filter { $0.hasPrefix(threadID + ":") }.map { "turn:" + $0 }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers + [completionID])
        }
        persist()
    }

    func notify(_ action: PendingAction) {
        postNotice(threadID: action.threadID, title: action.title, identifier: action.id, actionID: action.id)
        NSApplication.shared.dockTile.badgeLabel = String(pending.count)
    }
    /// Acknowledging a notice never answers or approves the underlying request.
    func markActionRead(_ action: PendingAction) {
        guard chatID == action.threadID, !showingJobs, (!showingArchive || archiveViewingChat), !loadingChat,
              currentAction?.id == action.id else { return }
        removeActionNotices([action])
    }
    private func removeActionNotices(_ actions: [PendingAction]) {
        notices.removeAll { notice in
            actions.contains { $0.id == notice.actionID && $0.threadID == notice.threadID }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: actions.map(\.id))
        }
    }
    func focusAction(threadID: String) async {
        guard let chat = state.chats.first(where: { $0.id == threadID }) else { return }
        await openChat(chat)
    }
    func answer(_ action: PendingAction, result: JSONValue) async {
        guard pending.contains(where: { $0.id == action.id }), connected else { return }
        do {
            try await connection.answer(id: action.rpcID, result: result)
            pending.removeAll { $0.id == action.id }
            removeActionNotices([action])
            NSApplication.shared.dockTile.badgeLabel = pending.isEmpty ? nil : String(pending.count)
        } catch { self.error = error.localizedDescription }
    }
    func shutdown() async {
        await connection.stop()
        await stopPlugins()
    }
    private func persist() { let snapshot = state; Task { do { try await store.save(snapshot) } catch { self.error = error.localizedDescription } } }

    private func receive(_ event: JSONValue) async {
        let method = event["method"].string ?? "", p = event["params"]
        if event["id"] != .null {
            let supported = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput", "item/permissions/requestApproval", "mcpServer/elicitation/request"]
            guard supported.contains(method) else {
                try? await connection.rejectUnknown(id: event["id"])
                error = L10n.text("Движок запросил пока неподдерживаемое действие: \(method)", "The engine requested an unsupported action: \(method)"); return
            }
            let action = PendingAction(id: event["id"].display, rpcID: event["id"], method: method, params: p)
            if !pending.contains(where: { $0.id == action.id }) { pending.append(action); notify(action) }
            return
        }
        switch method {
        case "account/login/completed", "account/updated":
            clearLimits()
            if p["success"].bool == false { error = p["error"].string ?? L10n.text("Вход не выполнен", "Not signed in") }
            await refreshAccount()
        case "account/rateLimits/updated": await refreshLimits()
        case "client/disconnected":
            resetRuns()
            connected = false
            loadedThreads.removeAll(); pending.removeAll(); deltas.removeAll()
            NSApplication.shared.dockTile.badgeLabel = nil
            error = L10n.text("Codex отключился. Подключись заново; отправка не будет повторена автоматически.", "Codex disconnected. Reconnect; the message will not be sent again automatically.")
        case "client/error": error = p["message"].string
        case "serverRequest/resolved":
            let resolved = pending.filter { $0.rpcID == p["requestId"] && $0.threadID == p["threadId"].string }
            pending.removeAll { action in resolved.contains { $0.id == action.id } }
            removeActionNotices(resolved)
            NSApplication.shared.dockTile.badgeLabel = pending.isEmpty ? nil : String(pending.count)
        case "thread/tokenUsage/updated":
            if let id = p["threadId"].string { let snapshot = UsageSnapshot(event: p); usage[id] = snapshot; try? await store.saveUsage(threadID: id, snapshot: snapshot) }
        case "turn/started":
            if let thread = p["threadId"].string, let turn = p["turn"]["id"].string,
               completedTurns[thread + ":" + turn] == nil {
                runs[thread, default: ChatRunState()].running = true
                runs[thread, default: ChatRunState()].turnID = turn
            }
        case "turn/completed":
            flushDeltas()
            if let threadID = p["threadId"].string, let turnID = p["turn"]["id"].string,
               notifiedTurns.insert(threadID + ":" + turnID).inserted {
                let status = p["turn"]["status"].string
                let title = p["turn"]["error"] != .null || status == "failed" ? L10n.text("Ошибка в разговоре", "Conversation error") : status == "interrupted" ? L10n.text("Ответ остановлен", "Response stopped") : L10n.text("Ответ готов", "Response ready")
                let completionID = "turn:" + threadID + ":" + turnID
                recordUnreadCompletion(threadID: threadID, completionID: completionID)
                postNotice(threadID: threadID, title: title, identifier: completionID, completionID: completionID)
            }
            finishActiveTurn(threadID: p["threadId"].string, turnID: p["turn"]["id"].string,
                             status: p["turn"]["status"].string, hasError: p["turn"]["error"] != .null)
            let resolved = pending.filter { $0.threadID == p["threadId"].string && $0.params["turnId"] == p["turn"]["id"] }
            pending.removeAll { action in resolved.contains { $0.id == action.id } }
            removeActionNotices(resolved)
            NSApplication.shared.dockTile.badgeLabel = pending.isEmpty ? nil : String(pending.count)
            if p["turn"]["error"] != .null { error = p["turn"]["error"]["message"].string ?? L10n.text("Задача завершилась с ошибкой", "The task failed") }
        case "item/started", "item/completed":
            guard p["threadId"].string == chatID, let item = TranscriptItem.parse(p["item"]) else { return }
            flushDeltas()
            TranscriptItem.merge(item, into: &items)
        case "item/agentMessage/delta":
            guard p["threadId"].string == chatID, let id = p["itemId"].string else { return }
            if !items.contains(where: { $0.id == id }) { items.append(TranscriptItem(id: id, kind: "assistant", text: "")) }
            deltas[id, default: ""] += p["delta"].string ?? ""
            if deltaTask == nil {
                deltaTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(50)); self?.flushDeltas(); self?.deltaTask = nil
                }
            }
        case "error": error = p["error"]["message"].string ?? p["message"].string ?? L10n.text("Ошибка Codex", "Codex error")
        default: break
        }
    }
    private func flushDeltas() {
        for (id, delta) in deltas { if let i = items.firstIndex(where: { $0.id == id }) { items[i].text += delta } }
        deltas.removeAll()
    }
}
