import SwiftUI
import Foundation
import PhotosUI
import ImageIO

@MainActor final class MobileModel: ObservableObject {
    @Published var url = UserDefaults.standard.string(forKey: "supabaseURL") ?? ""
    @Published var key = UserDefaults.standard.string(forKey: "supabaseKey") ?? ""
    @Published var email = ""
    @Published var password = ""
    @Published var devices: [RemoteDevice] = []
    @Published var commands: [RemoteCommand] = []
    @Published var status = ""
    @Published var connecting = false
    @Published var drafts: [String: String] = [:]
    @Published var photoDrafts: [String: [RemotePhoto]] = [:]
    @Published var signedIn = false
    @Published var sending = false
    @Published var unresolved: RemoteCommand?
    var api: RemoteAPI?
    @Published var connectionState: RemoteConnectionState = .stopped
    @Published var onlineMacs: Set<String> = []
    private var realtime: RemoteRealtime?
    private let updates = RemoteEventWork()
    private var dirtyDevices: Set<String> = []
    private var dirtyCommands: Set<String> = []
    private var needsFullSync = false
    private var active = false
    private var lifecycle = UUID()
    private let phoneID = UUID().uuidString.lowercased()
    func restoreConnection() async {
        guard !signedIn else { return }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-mobile-preview") { loadPreview(); return }
        #endif
        do {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mobile-setup.json")
            if let setup = try RemoteSetup.consume(file) {
                url = setup.url; key = setup.key; email = setup.email; password = setup.password
            }
            if !url.isEmpty && !key.isEmpty { await connect() }
        } catch { status = error.localizedDescription }
    }
    func connect() async {
        guard !connecting, !signedIn else { return }
        connecting = true
        defer { connecting = false }
        do {
            let client = try RemoteAPI(url: url, key: key)
            if !password.isEmpty { try await client.signIn(email: email, password: password) }
            password = ""
            _ = try await client.owner()
            api = client; signedIn = true
            UserDefaults.standard.set(url, forKey: "supabaseURL"); UserDefaults.standard.set(key, forKey: "supabaseKey")
            if let saved = RemoteVault.read("pending-command"), let command = try? JSONDecoder().decode(RemoteCommand.self, from: saved) { unresolved = command }
            startConnection()
        } catch { password = ""; status = error.localizedDescription }
    }
    func setActive(_ value: Bool) {
        active = value
        if value { startConnection() }
        else {
            lifecycle = UUID(); realtime?.stop(); updates.cancel()
            dirtyDevices = []; dirtyCommands = []; onlineMacs = []
        }
    }
    func startConnection() {
        guard signedIn, active, let api else { return }
        if realtime == nil {
            let channel = RemoteRealtime(role: "phone", device: phoneID,
                credentials: { try await api.realtimeCredentials() }, ready: { [weak self] in
                    try await api.checkRealtimeSchema()
                    try await self?.synchronize()
                })
            realtime = channel
            channel.onState = { [weak self] value in
                guard let self else { return }
                connectionState = value
                if value == .connecting { lifecycle = UUID(); updates.cancel(); dirtyDevices = []; dirtyCommands = []; needsFullSync = false }
                if value == .connected { status = ""; requestUpdates() }
            }
            channel.onError = { [weak self] error in self?.status = error.localizedDescription }
            channel.onPresence = { [weak self] value in self?.onlineMacs = value.macs }
            channel.onChange = { [weak self] event in
                guard let self, active else { return }
                if event.entity == "device" { dirtyDevices.insert(event.device) }
                else if let id = event.command, UUID(uuidString: id) != nil { dirtyCommands.insert(id) }
                requestUpdates()
            }
        }
        realtime?.start()
    }
    private func synchronize() async throws {
        guard active, let api else { throw CancellationError() }
        let ticket = lifecycle
        let fetched = try await api.devices().filter { $0.snapshot.version == 1 }
        var updated: [RemoteCommand] = []
        for device in fetched { updated += try await api.commands(device: device.id) }
        // An uncertain command may be older than the bounded recent-command list.
        if let unresolved, !updated.contains(where: { $0.id == unresolved.id }), let found = try await api.command(id: unresolved.id) {
            updated.append(found)
        }
        try Task.checkCancellation()
        guard active, ticket == lifecycle, signedIn, self.api === api else { throw CancellationError() }
        for value in fetched {
            if let previous = devices.first(where: { $0.id == value.id }),
               (previous.revision ?? 0) > (value.revision ?? 0) { continue }
            if let index = devices.firstIndex(where: { $0.id == value.id }) { devices[index] = value }
            else { devices.append(value) }
        }
        devices.removeAll { value in !fetched.contains { $0.id == value.id } }
        commands = updated
        try resolveDelivery()
    }
    private func requestUpdates() {
        guard active, connectionState == .connected,
              needsFullSync || !dirtyDevices.isEmpty || !dirtyCommands.isEmpty else { return }
        updates.enqueue(delay: .milliseconds(40), operation: { [weak self] in
            try await self?.applyChanges()
        }, failure: { [weak self] error in self?.realtime?.recover(from: error) })
    }
    private func applyChanges() async throws {
        guard active, let api else { throw CancellationError() }
        let ticket = lifecycle
        if needsFullSync { needsFullSync = false; try await synchronize() }
        let deviceIDs = dirtyDevices; dirtyDevices = []
        let commandIDs = dirtyCommands; dirtyCommands = []
        for id in deviceIDs {
            let previous = devices.first { $0.id == id }
            let delta = try await api.changes(device: id, since: previous?.revision ?? -1)
            try Task.checkCancellation()
            guard active, ticket == lifecycle, self.api === api else { throw CancellationError() }
            if let delta {
                let current = devices.first { $0.id == id }
                let value = delta.applying(to: current)
                if let index = devices.firstIndex(where: { $0.id == id }) { devices[index] = value }
                else { devices.append(value) }
            } else { devices.removeAll { $0.id == id }; commands.removeAll { $0.device == id } }
        }
        for id in commandIDs {
            let value = try await api.command(id: id)
            try Task.checkCancellation()
            guard active, ticket == lifecycle, self.api === api else { throw CancellationError() }
            if let value {
                if let index = commands.firstIndex(where: { $0.id == id }) { commands[index] = value }
                else { commands.insert(value, at: 0) }
            } else { commands.removeAll { $0.id == id } }
        }
        try resolveDelivery()
        commands = Array(commands.prefix(600))
    }
    private func resolveDelivery() throws {
        if let unresolved, commands.contains(where: { $0.id == unresolved.id }) {
            try RemoteVault.save(nil, account: "pending-command"); self.unresolved = nil
        }
    }
    func refresh() async {
        guard active else { return }
        startConnection()
        needsFullSync = true; requestUpdates()
    }
    func send(device: RemoteDevice, chat: RemoteChat, kind: String, text: String = "", approval: String? = nil, photos: [RemotePhoto] = []) async -> Bool {
        guard let api, !sending, unresolved == nil else { return false }
        sending = true; defer { sending = false }
        do {
            let command = RemoteCommand(owner: try await api.owner(), device: device.id, project: chat.project, chat: chat.id, kind: kind, text: text, approval: approval, turn: chat.turn, photos: photos)
            try command.validate()
            if !photos.isEmpty {
                guard chat.supportsPhotos == true else { throw RemoteFailure.photoSetup }
                try await api.checkPhotoSchema()
            }
            // Save the stable ID before networking. Never resubmit after a transport failure.
            var receipt = command; receipt.photos = nil
            try RemoteVault.save(JSONEncoder().encode(receipt), account: "pending-command")
            unresolved = command
            try await api.submit(command)
            unresolved = nil; try RemoteVault.save(nil, account: "pending-command")
            if self.api === api, active { dirtyCommands.insert(command.id); requestUpdates() }
            return true
        } catch { status = error.localizedDescription; return false }
    }
    func signOut() async {
        lifecycle = UUID(); realtime?.stop(); realtime = nil; updates.cancel()
        dirtyDevices = []; dirtyCommands = []; onlineMacs = []
        do { try await api?.signOut(); api = nil; signedIn = false; devices = []; commands = []; drafts = [:]; photoDrafts = [:] }
        catch { status = error.localizedDescription }
    }
}

@main struct ContextMobileApp: App {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MobileRoot(model: model)
                .environment(\.locale, Locale(identifier: L10n.language.rawValue))
                .task { model.setActive(phase == .active); await model.restoreConnection() }
                .onChange(of: phase) { _, value in
                    if value == .active { model.setActive(true) } else if value == .background { model.setActive(false) }
                }
        }
    }
}
struct MobileRoot: View {
    @ObservedObject var model: MobileModel
    @State private var search = ""
    @State private var settings = false
    var body: some View {
        NavigationStack {
            Group {
                if model.signedIn {
                    List {
                        ForEach(model.devices) { device in
                            Section {
                                ConnectionStatus(model: model, device: device)
                            }
                            ForEach(device.snapshot.projects) { project in
                                let chats = device.snapshot.chats.filter {
                                    $0.project == project.id && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
                                }
                                if !chats.isEmpty {
                                    Section(project.name) {
                                        ForEach(chats) { chat in
                                            NavigationLink {
                                                MobileChatView(model: model, deviceID: device.id, chatID: chat.id)
                                            } label: { ChatRow(chat: chat) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $search, prompt: L10n.text("Найти чат", "Find a chat"))
                    .refreshable { await model.refresh() }
                    .overlay {
                        if model.devices.isEmpty {
                            ContentUnavailableView(L10n.text("Подключи Mac", "Connect your Mac"), systemImage: "desktopcomputer",
                                description: Text(L10n.text("В настройках Context Desk на Mac выбери проекты и включи мобильный доступ.", "Select projects and enable mobile access in Context Desk settings on your Mac.")))
                        } else if !search.isEmpty && !model.devices.contains(where: { $0.snapshot.chats.contains(where: { $0.title.localizedCaseInsensitiveContains(search) }) }) {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                } else {
                    Form {
                        Section {
                            Label(L10n.text("Твои проекты всегда рядом", "Your projects, wherever you are"), systemImage: "macbook.and.iphone")
                                .font(.title3.weight(.semibold)).padding(.vertical, 12)
                            Text(L10n.text("Подключись к той же учётной записи, что и Context Desk на Mac.", "Connect with the same account as Context Desk on your Mac."))
                                .foregroundStyle(.secondary)
                        }
                        Section(L10n.text("Подключение", "Connection")) {
                            TextField("Supabase URL", text: $model.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField(L10n.text("Публичный ключ", "Public key"), text: $model.key).textInputAutocapitalization(.never)
                            TextField(L10n.text("Почта", "Email"), text: $model.email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField(L10n.text("Пароль", "Password"), text: $model.password)
                            Button { Task { await model.connect() } } label: {
                                HStack { Text(L10n.text("Подключиться", "Connect")); Spacer(); if model.connecting { ProgressView() } }
                            }.disabled(model.connecting || model.url.isEmpty || model.key.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle(model.signedIn ? L10n.text("Чаты", "Chats") : "Context Desk")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L10n.text("Настройки", "Settings"))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { MobileNotice(model: model) }
            .sheet(isPresented: $settings) { MobileSettings(model: model) }
            #if targetEnvironment(simulator)
            .navigationDestination(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("-preview-chat") && model.signedIn)) {
                if let device = model.devices.first, let chat = device.snapshot.chats.first {
                    MobileChatView(model: model, deviceID: device.id, chatID: chat.id)
                }
            }
            #endif
        }
    }
}

struct ChatRow: View {
    let chat: RemoteChat
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: chat.approvals.isEmpty ? "bubble.left.and.bubble.right" : "hand.raised")
                .font(.title3).foregroundStyle(chat.approvals.isEmpty ? Color.accentColor : .orange)
                .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(chat.title).font(.headline).lineLimit(2)
                Text(chat.messages.last?.text ?? L10n.text("Пока нет сообщений", "No messages yet"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if chat.running || !chat.approvals.isEmpty {
                    Label(chat.approvals.isEmpty ? L10n.text("Работает", "Working") : L10n.text("Нужен ответ", "Needs your attention"),
                          systemImage: chat.approvals.isEmpty ? "circle.dotted" : "exclamationmark.circle")
                        .font(.caption.weight(.medium)).foregroundStyle(chat.approvals.isEmpty ? Color.accentColor : .orange)
                }
            }
        }.padding(.vertical, 7)
    }
}

struct ConnectionStatus: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    var body: some View {
        let server = model.connectionState == .connected
        let host = server && model.onlineMacs.contains(device.id.lowercased())
        HStack(spacing: 10) {
            Circle().fill(host ? Color.green : .orange).frame(width: 7, height: 7)
            Text(server ? (host ? L10n.text("Mac на связи", "Mac connected") : L10n.text("Mac недоступен", "Mac unavailable")) : model.connectionState.text)
                .font(.subheadline)
            Spacer()
            if let date = ISO8601DateFormatter().date(from: device.seen) {
                Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Последнее обновление данных", "Last data update"))
            }
        }.accessibilityElement(children: .combine)
    }
}

struct MobileNotice: View {
    @ObservedObject var model: MobileModel
    var body: some View {
        if !model.status.isEmpty || model.unresolved != nil || (model.signedIn && model.connectionState != .connected) {
            VStack(alignment: .leading, spacing: 6) {
                if !model.status.isEmpty { Label(model.status, systemImage: "exclamationmark.circle") }
                else if model.connectionState != .connected { Label(model.connectionState.text, systemImage: "network") }
                if model.unresolved != nil {
                    Text(L10n.text("Доставка не подтверждена. Проверь историю на Mac перед новой отправкой.", "Delivery is unconfirmed. Check the history on your Mac before sending again."))
                }
            }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.regularMaterial)
        }
    }
}

struct MobileSettings: View {
    @ObservedObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Уведомления", "Notifications")) {
                    Label(L10n.text("Push пока не подключены", "Push notifications are not connected"), systemImage: "bell.badge")
                    Text(L10n.text("Для уведомлений на заблокированном iPhone нужна подпись Apple Developer Program. Текущая бесплатная установка её не поддерживает.", "Notifications on a locked iPhone require Apple Developer Program signing. The current free installation does not support it."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("Язык", "Language")) {
                    Picker("Язык / Language", selection: Binding(get: { L10n.language.rawValue }, set: { UserDefaults.standard.set($0, forKey: AppLanguage.preferenceKey) })) {
                        Text("Русский").tag("ru"); Text("English").tag("en")
                    }
                    Text(L10n.text("Применится после перезапуска приложения.", "Applies after restarting the app.")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("История", "History")) {
                    Text(L10n.text("Здесь — последние 20 сообщений недавних чатов. Длинные сообщения сокращены до 2000 символов. Полная история остаётся на Mac.", "The latest 20 messages in recent chats are shown here. Long messages are limited to 2,000 characters. Full history stays on your Mac."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.signedIn {
                    Section {
                        Button(L10n.text("Выйти из аккаунта", "Sign out"), role: .destructive) { Task { await model.signOut(); dismiss() } }
                    }
                }
            }.navigationTitle(L10n.text("Настройки", "Settings")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Готово", "Done")) { dismiss() } } }
        }
    }
}

struct MobileChatView: View {
    @ObservedObject var model: MobileModel
    let deviceID: String
    let chatID: String
    @FocusState private var writing: Bool
    @State private var following = true
    @State private var atBottom = true
    @State private var jumpRequest = 0
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    @State private var photoError: String?
    private var draftKey: String { deviceID + ":" + chatID }
    private var photos: [RemotePhoto] { model.photoDrafts[draftKey] ?? [] }
    private var canSend: Bool { !loadingPhotos && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty) }
    @StateObject private var scrollController = TranscriptScrollController()
    private var draft: Binding<String> {
        Binding(get: { model.drafts[deviceID + ":" + chatID] ?? "" }, set: { model.drafts[deviceID + ":" + chatID] = $0 })
    }
    var body: some View {
        if let device = model.devices.first(where: { $0.id == deviceID }), let chat = device.snapshot.chats.first(where: { $0.id == chatID }) {
            VStack(spacing: 0) {
                ConnectionStatus(model: model, device: device).padding(.horizontal).padding(.vertical, 9).background(.bar)
                GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(L10n.text("Последние сообщения · полная история на Mac", "Recent messages · full history on Mac"))
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 8)
                            ForEach(chat.messages) { message in MessageBubble(message: message) }
                            if chat.running {
                                HStack(spacing: 10) { ProgressView(); Text(L10n.text("Агент работает…", "Agent is working…")).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            ForEach(chat.approvals) { approval in
                                VStack(alignment: .leading, spacing: 12) {
                                    Label(L10n.text("Требуется подтверждение", "Approval required"), systemImage: "hand.raised.fill").font(.headline)
                                    Text(approval.details).font(.callout).textSelection(.enabled)
                                    HStack {
                                        Button(L10n.text("Отклонить", "Decline"), role: .destructive) { Task { _ = await model.send(device: device, chat: chat, kind: "deny", approval: approval.id) } }
                                        Spacer()
                                        if approval.canAllow {
                                            Button(L10n.text("Разрешить один раз", "Allow once")) { Task { _ = await model.send(device: device, chat: chat, kind: "allow", approval: approval.id) } }
                                        }
                                    }.buttonStyle(.bordered).disabled(model.sending || model.unresolved != nil)
                                }.padding().background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                            }
                            if let command = model.commands.first(where: { $0.chat == chatID && $0.device == deviceID }) {
                                Text(commandLabel(command.status)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            }
                            Color.clear.frame(height: 1).id("tail")
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: TranscriptBottomKey.self, value: geometry.frame(in: .named("transcript")).maxY)
                                })
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                            .frame(width: viewport.size.width)
                            .background(TranscriptScrollProbe(controller: scrollController))
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                            })
                    }
                    .coordinateSpace(name: "transcript")
                    .accessibilityIdentifier("conversation-scroll")
                    .defaultScrollAnchor(.bottom)
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(DragGesture().onChanged { _ in following = false })
                    .onPreferenceChange(TranscriptBottomKey.self) { bottom in
                        atBottom = bottom <= viewport.size.height + 24 && bottom >= 0
                        if atBottom { following = true }
                    }
                    .onPreferenceChange(TranscriptHeightKey.self) { _ in
                        if following { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                    .onChange(of: viewport.size.height) { _, _ in
                        if following { proxy.scrollTo("tail", anchor: .bottom) }
                    }
                    .onChange(of: jumpRequest) { _, _ in
                        following = true
                        proxy.scrollTo("tail", anchor: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom {
                            Button {
                                following = true
                                if !scrollController.jumpToBottom() { proxy.scrollTo("tail", anchor: .bottom) }
                            } label: {
                                Image(systemName: "arrow.down").font(.headline).padding(13).background(.regularMaterial, in: Circle())
                            }.padding().accessibilityLabel(L10n.text("К последнему сообщению", "Jump to latest message"))
                                .accessibilityIdentifier("jump-to-latest")
                        }
                    }
                }
                }
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !photos.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(photos) { photo in
                                    if let image = UIImage(data: photo.data) {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(alignment: .topTrailing) {
                                                Button { model.photoDrafts[draftKey]?.removeAll { $0.id == photo.id } } label: {
                                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black)
                                                }.accessibilityLabel(L10n.text("Удалить фото", "Remove photo"))
                                            }
                                    }
                                }
                            }.padding(.top, 4)
                        }.frame(height: 72).disabled(model.sending || model.unresolved != nil || loadingPhotos)
                    }
                    if loadingPhotos { ProgressView(L10n.text("Подготовка фото…", "Preparing photos…")).font(.caption) }
                    if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
                    HStack(alignment: .bottom, spacing: 8) {
                        PhotosPicker(selection: $photoSelection, maxSelectionCount: max(1, RemotePhoto.maximumCount - photos.count), matching: .images) {
                            Image(systemName: "photo.badge.plus").font(.title3).frame(width: 44, height: 44)
                        }.accessibilityLabel(L10n.text("Добавить фото", "Add photos")).accessibilityIdentifier("add-photos")
                            .disabled(loadingPhotos || photos.count >= RemotePhoto.maximumCount || chat.supportsPhotos != true)
                        TextField(L10n.text("Сообщение…", "Message…"), text: draft, axis: .vertical)
                            .lineLimit(1...6).focused($writing).padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityIdentifier("message-input")
                        if chat.running {
                            Button { Task { _ = await model.send(device: device, chat: chat, kind: "stop") } } label: {
                                Image(systemName: "stop.fill").frame(width: 44, height: 44).background(Color.red.opacity(0.12), in: Circle()).foregroundStyle(.red)
                            }.accessibilityLabel(L10n.text("Остановить", "Stop"))
                        } else {
                            Button {
                                let text = draft.wrappedValue
                                let submittedPhotos = photos
                                Task {
                                    if await model.send(device: device, chat: chat, kind: "send", text: text, photos: submittedPhotos) {
                                        if draft.wrappedValue == text { draft.wrappedValue = ""; writing = false }
                                        model.photoDrafts[draftKey]?.removeAll { photo in submittedPhotos.contains { $0.id == photo.id } }
                                        jumpRequest += 1
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                                    .foregroundStyle(.white).background(Color.accentColor, in: Circle())
                            }.disabled(!canSend)
                                .opacity(canSend ? 1 : 0.4)
                                .accessibilityLabel(L10n.text("Отправить", "Send")).accessibilityIdentifier("send-message")
                        }
                    }
                    .disabled(model.sending || model.unresolved != nil)
                    if model.sending { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 12).padding(.vertical, 10).background(.bar)
            }
            .task(id: photoSelection) {
                guard !photoSelection.isEmpty else { return }
                loadingPhotos = true; photoError = nil
                defer { loadingPhotos = false }
                do {
                    var prepared: [RemotePhoto] = []
                    for item in photoSelection {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw RemoteFailure.invalidPhoto }
                        try Task.checkCancellation()
                        prepared.append(try Self.preparePhoto(data))
                    }
                    try Task.checkCancellation()
                    guard photos.count + prepared.count <= RemotePhoto.maximumCount else { throw RemoteFailure.invalidPhoto }
                    model.photoDrafts[draftKey, default: []].append(contentsOf: prepared)
                    photoSelection = []
                } catch is CancellationError { }
                catch { photoError = error.localizedDescription; photoSelection = [] }
            }
            .navigationTitle(chat.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if writing {
                        Button { writing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                            .accessibilityLabel(L10n.text("Скрыть клавиатуру", "Hide keyboard"))
                    }
                }
            }
        } else {
            ContentUnavailableView(L10n.text("Чат недоступен", "Chat unavailable"), systemImage: "bubble.left",
                description: Text(L10n.text("Проверь выбранные проекты на Mac.", "Check the selected projects on your Mac.")))
        }
    }
    private static func preparePhoto(_ data: Data) throws -> RemotePhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw RemoteFailure.invalidPhoto }
        let image = UIImage(cgImage: thumbnail)
        for quality in [0.85, 0.65, 0.45, 0.25] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= RemotePhoto.maximumBytes {
                let photo = RemotePhoto(data: jpeg); try photo.validate(); return photo
            }
        }
        throw RemoteFailure.invalidPhoto
    }
    private func commandLabel(_ status: String) -> String {
        switch status {
        case "pending": L10n.text("Ожидает Mac", "Waiting for Mac")
        case "claimed": L10n.text("Получено Mac", "Received by Mac")
        case "submitted": L10n.text("Передано агенту", "Submitted to agent")
        case "stop_requested": L10n.text("Остановка запрошена", "Stop requested")
        case "rejected": L10n.text("Не отправлено: чат занят или недоступен", "Not sent: chat is busy or unavailable")
        default: L10n.text("Результат неизвестен · проверь Mac", "Outcome unknown · check your Mac")
        }
    }
}

private struct TranscriptScrollProbe: UIViewRepresentable {
    let controller: TranscriptScrollController
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.controller = controller; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.attach() }
    final class Probe: UIView {
        weak var controller: TranscriptScrollController?
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }
        func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { controller?.scrollView = scroll; return }
                ancestor = view.superview
            }
        }
    }
}

private struct TranscriptBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MessageBubble: View {
    let message: RemoteMessage
    var body: some View {
        HStack(alignment: .top) {
            if message.role == "user" { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 6) {
                if message.role != "user" { Text(L10n.text("Ассистент", "Assistant")).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                    .font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("message-text-" + message.id)
            }
            .padding(message.role == "user" ? 14 : 0)
            .background(message.role == "user" ? Color(.secondarySystemBackground) : .clear, in: RoundedRectangle(cornerRadius: 20))
            .contextMenu {
                Button { UIPasteboard.general.string = message.text } label: { Label(L10n.text("Копировать", "Copy"), systemImage: "doc.on.doc") }
            }
            if message.role != "user" { Spacer(minLength: 4) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("message-" + message.id)
    }
}

#if targetEnvironment(simulator)
extension MobileModel {
    func loadPreview() {
        let project = RemoteProject(id: "preview-project", name: "Context Desk")
        var chat = RemoteChat(id: "preview-chat", project: project.id, title: L10n.text("Мобильное приложение", "Mobile app"), running: false,
            messages: [RemoteMessage(id: "m1", role: "user", text: L10n.text("Сделаем удобный интерфейс для iPhone. Поле ввода должно быть всегда под рукой.", "Let's make the iPhone interface comfortable. Keep the message field within reach.")),
                       RemoteMessage(id: "m2", role: "assistant", text: L10n.text("Готово. Теперь переписка занимает весь экран, а поле ввода закреплено внизу.\n\n**Что изменилось**\n• Поиск по чатам\n• Превью последних сообщений\n• Кнопка скрытия клавиатуры\n\nПосле отправки клавиатура закрывается автоматически.", "Done. The conversation now fills the screen, with the composer pinned at the bottom.\n\n**What's new**\n• Chat search\n• Latest message previews\n• A button to hide the keyboard\n\nThe keyboard closes automatically after sending."))], approvals: [])
        if ProcessInfo.processInfo.arguments.contains("-preview-long") {
            chat.messages = (0..<20).map { index in
                RemoteMessage(id: "long-\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: "Message \(index)\n" + String(repeating: "Long transcript layout verification. ", count: index.isMultiple(of: 3) ? 70 : 10))
            }
        }
        devices = [RemoteDevice(id: "preview-device", owner: "preview-owner", snapshot: RemoteSnapshot(projects: [project], chats: [chat]))]
        connectionState = ProcessInfo.processInfo.arguments.contains("-preview-offline") ? .offline : .connected
        onlineMacs = ["preview-device"]
        signedIn = true
    }
}
#endif
