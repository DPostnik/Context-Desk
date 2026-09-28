import Foundation
import SwiftUI
import ContextCore
import AgentContract
import Combine
import IOKit.pwr_mgt
import IOKit.ps

@MainActor final class MobileRemoteHost: ObservableObject {
    @Published var url = ""
    @Published var key = ""
    @Published var email = ""
    @Published var password = ""
    @Published var projects: Set<String> = []
    @Published private(set) var enabled = false
    @Published private(set) var transitioning = false
    @Published private(set) var status = ""
    @Published private(set) var connectionState: RemoteConnectionState = .stopped
    private var realtime: RemoteRealtime?
    private let publication = RemoteEventWork()
    private let commandWork = RemoteEventWork()
    private var modelChanges: AnyCancellable?
    private weak var model: DeskModel?
    private var lastPublished: RemoteSnapshot?
    private var liveMessages: [String: [RemoteMessage]] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var sleeping = false
    private var api: RemoteAPI?
    private var assertion: IOPMAssertionID = 0
    private let configFile = Locations.root.appendingPathComponent("mobile-remote.json")
    private let setupFile: URL
    private let journal = RemoteJournal(file: Locations.root.appendingPathComponent("mobile-remote-journal.json"))
    private var device = UUID().uuidString.lowercased()
    private struct Config: Codable { var url: String; var key: String; var device: String; var projects: Set<String> }
    init(setupFile: URL = Locations.root.appendingPathComponent("mobile-setup.json")) {
        self.setupFile = setupFile
        if let data = try? Data(contentsOf: configFile), let config = try? JSONDecoder().decode(Config.self, from: data) {
            url = config.url; key = config.key; device = config.device; projects = config.projects
        }
    }
    // Model construction also happens in tests and background contexts. Only the
    // settings UI consumes the installer handoff.
    func prepareConnection() {
        guard !enabled, !transitioning else { return }
        do {
            if let setup = try RemoteSetup.consume(setupFile) {
                url = setup.url; key = setup.key; email = setup.email; password = setup.password
                status = L10n.text("Подключение подготовлено. Выберите проекты и включите доступ.", "Connection prepared. Select projects and enable access.")
            }
        } catch { status = error.localizedDescription }
    }
    func enable(model: DeskModel) async {
        guard !enabled, !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        do {
            let client = try RemoteAPI(url: url, key: key)
            if !password.isEmpty { try await client.signIn(email: email, password: password); password = "" }
            _ = try await client.owner()
            try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Config(url: url, key: key, device: device, projects: projects)).write(to: configFile, options: .atomic)
            api = client; self.model = model; enabled = true; lastPublished = nil
            let channel = RemoteRealtime(role: "mac", device: device, credentials: { try await client.realtimeCredentials() }) { [weak self] in
                try await client.checkRealtimeSchema()
                guard let self, self.enabled, !self.sleeping else { throw CancellationError() }
                self.lastPublished = nil // A new subscription always reconciles current local state.
                try await self.publishCurrent()
            }
            realtime = channel
            channel.onState = { [weak self] value in
                guard let self else { return }
                connectionState = value; status = value.text
                if value == .connecting { publication.cancel() }
                if value == .connected { requestPublication(); requestCommands() }
            }
            channel.onError = { [weak self] error in self?.status = error.localizedDescription }
            channel.onChange = { [weak self] event in
                guard let self, event.device.lowercased() == device.lowercased(), event.entity == "command" else { return }
                // Finishing/rejecting an earlier command can unblock a queued send.
                requestCommands()
            }
            channel.onPresence = { [weak self] peers in
                if !peers.phones.isEmpty { self?.requestPublication() }
            }
            modelChanges = model.objectWillChange.sink { [weak self] _ in self?.requestPublication() }
            observePowerAndSleep()
            updateSleepAssertion()
            channel.start()
        } catch { password = ""; status = error.localizedDescription }
    }
    private func publishCurrent() async throws {
        guard enabled, !sleeping, let model, let api else { throw CancellationError() }
        var snapshot = await model.remoteSnapshot(projects: projects)
        try Task.checkCancellation()
        for index in snapshot.chats.indices {
            let chat = snapshot.chats[index].id
            // Off-screen streaming events are not in the selected desktop transcript.
            if chat != model.chatID, let live = liveMessages[chat] {
                var messages = snapshot.chats[index].messages
                for item in live {
                    if let i = messages.firstIndex(where: { $0.id == item.id }) { messages[i] = item }
                    else { messages.append(item) }
                }
                snapshot.chats[index].messages = Array(messages.suffix(20))
            }
        }
        liveMessages = liveMessages.filter { key, _ in snapshot.chats.contains { $0.id == key } }
        guard snapshot != lastPublished else { return }
        try await api.publishChanges(RemoteDevice(id: device, owner: api.owner(), snapshot: snapshot), previous: lastPublished)
        try Task.checkCancellation()
        lastPublished = snapshot
    }
    func requestPublication() {
        guard enabled, !sleeping, connectionState == .connected else { return }
        publication.enqueue(delay: .milliseconds(350), operation: { [weak self] in
            try await self?.publishCurrent()
        }, failure: { [weak self] error in self?.realtime?.recover(from: error) })
    }
    func observe(_ event: AgentEvent, thread: String?) {
        guard enabled, let thread, let model,
              let chat = model.state.chats.first(where: { $0.id == thread }), projects.contains(chat.projectID.uuidString) else { return }
        switch event.payload {
        case .item(let item) where ["user", "assistant"].contains(item.kind):
            let message = RemoteMessage(id: item.id, role: item.kind, text: String(item.text.prefix(2000)))
            var entries = liveMessages[thread] ?? []
            if let i = entries.firstIndex(where: { $0.id == item.id }) { entries[i] = message } else { entries.append(message) }
            liveMessages[thread] = Array(entries.suffix(20))
        case .delta(_, let id, let text):
            var entries = liveMessages[thread] ?? []
            if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].text = String((entries[i].text + text).prefix(2000)) }
            else {
                let base = lastPublished?.chats.first(where: { $0.id == thread })?.messages.first(where: { $0.id == id })?.text ?? ""
                entries.append(RemoteMessage(id: id, role: "assistant", text: String((base + text).prefix(2000))))
            }
            liveMessages[thread] = Array(entries.suffix(20))
        default: break
        }
        requestPublication()
    }
    private func requestCommands() {
        guard enabled, !sleeping, connectionState == .connected else { return }
        commandWork.enqueue(operation: { [weak self] in
            guard let self, let api, let model else { return }
            while enabled, !sleeping {
                try Task.checkCancellation()
                let commands = try await api.claim(device: device)
                guard !commands.isEmpty else { return }
                for command in commands {
                    // Once claimed, an uncertain command is never requeued or redispatched.
                    try Task.checkCancellation()
                    var result = "rejected"
                    do {
                        guard projects.contains(command.project), command.device.lowercased() == device.lowercased(),
                              command.owner == (try await api.owner()) else { throw RemoteFailure.invalidCommand }
                        try await journal.begin(command)
                        result = try await model.executeRemote(command)
                    } catch RemoteFailure.invalidCommand { result = "rejected" }
                    catch { result = "uncertain" }
                    try await api.finish(id: command.id, status: result)
                    requestPublication()
                }
            }
        }, failure: { [weak self] error in self?.realtime?.recover(from: error) })
    }
    func disable() async {
        enabled = false; sleeping = false
        realtime?.stop(); realtime = nil
        publication.cancel(); commandWork.cancel(); modelChanges = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil; liveMessages = [:]; lastPublished = nil
        releaseSleepAssertion()
        status = L10n.text("Удалённый доступ выключен. Очередь в облаке сохранена.", "Remote access disabled. Cloud queue retained.")
    }
    private func observePowerAndSleep() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true; self.publication.cancel(); self.commandWork.cancel(); self.realtime?.stop(); self.releaseSleepAssertion()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                self.sleeping = false; self.updateSleepAssertion(); self.realtime?.start()
            }
        })
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let host = Unmanaged<MobileRemoteHost>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak host] in
                guard let host, host.enabled, !host.sleeping else { return }
                host.updateSleepAssertion()
            }
        }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    }
    func forgetCloudCopy() async {
        await disable()
        do {
            let client = try api ?? RemoteAPI(url: url, key: key)
            try await client.deleteDevice(device)
            try await client.signOut()
            status = L10n.text("Облачная копия и очередь удалены", "Cloud copy and queue deleted")
        } catch { status = error.localizedDescription }
    }
    private func updateSleepAssertion() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let onAC = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPSACPowerValue
        if onAC && assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Context Desk Remote Access" as CFString, &assertion)
        } else if !onAC { releaseSleepAssertion() }
    }
    private func releaseSleepAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
}

struct MobileRemoteSettings: View {
    @ObservedObject var host: MobileRemoteHost
    @ObservedObject var model: DeskModel
    var body: some View {
        Section(L10n.text("Мобильный доступ · Supabase", "Mobile access · Supabase")) {
            Group {
            TextField("Supabase URL", text: $host.url)
            SecureField(L10n.text("Публичный ключ", "Public key"), text: $host.key)
            TextField(L10n.text("Почта Supabase", "Supabase email"), text: $host.email)
            SecureField(L10n.text("Пароль Supabase", "Supabase password"), text: $host.password)
            }.disabled(host.enabled || host.transitioning)
            Text(L10n.text("Выбранные проекты: названия, последние сообщения и запросы подтверждения передаются в Supabase. Вложения и учётные данные агентов не передаются. Облачная копия хранится до удаления ниже. После перезапуска доступ нужно включить вручную; сохранённые команды будут обработаны.", "Selected projects: names, recent messages and approval requests are sent to Supabase. Attachments and agent credentials are excluded. The cloud copy remains until deleted below. After restarting, enable access manually; saved commands will be processed."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.state.projects) { project in
                Toggle(project.name, isOn: Binding(get: { host.projects.contains(project.id.uuidString) }, set: {
                    if $0 { host.projects.insert(project.id.uuidString) } else { host.projects.remove(project.id.uuidString) }
                })).disabled(host.enabled)
            }
            Text(L10n.text("На питании от сети Mac не засыпает автоматически. Закрытая крышка, принудительный сон и Cmd+Q могут прервать доступ.", "On external power, the Mac stays awake during idle time. Closing the lid, forced sleep and Cmd+Q can interrupt access."))
                .font(.caption).foregroundStyle(.secondary)
            if host.enabled {
                Button(L10n.text("Выключить доступ", "Disable access")) { Task { await host.disable() } }
            } else {
                Button(L10n.text("Включить и обработать очередь", "Enable and process queue")) { Task { await host.enable(model: model) } }.disabled(host.projects.isEmpty || host.transitioning)
            }
            Button(L10n.text("Удалить облачную копию и очередь", "Delete cloud copy and queue"), role: .destructive) { Task { await host.forgetCloudCopy() } }
            if !host.status.isEmpty { Text(host.status).font(.caption).textSelection(.enabled) }
        }
        .task { host.prepareConnection() }
    }
}
