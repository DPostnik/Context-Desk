import SwiftUI
import AppKit
import ContextCore
import ContextTranscript

struct DeskView: View {
    @ObservedObject var model: DeskModel
    @State private var search = ""
    @State private var selectedJobID: String?
    @State private var renaming: Chat?
    @State private var deleting: Chat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargetProjectID: UUID?
    @State private var dropTargetChatID: String?
    @State private var expandedProjects: Set<UUID> = []
    @State private var collapsedSearchProjects: Set<UUID> = []
    @State private var visibleChatCounts: [UUID: Int] = [:]
    private let chatPageSize = 5
    private var sidebarAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9) }
    @State private var newTitle = ""
    @State private var showingNotifications = false
    @State private var showingLimits = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .background(DeskPalette.canvas)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(PointerButtonStyle(base: .plain))
                .help(L10n.text("Показать или скрыть боковую панель", "Show or hide sidebar"))
                .accessibilityLabel(L10n.text("Показать или скрыть боковую панель", "Show or hide sidebar"))
            }
        }
        .tint(.primary)
        .onChange(of: model.projectID, initial: true) { _, projectID in
            if let projectID { expandedProjects.insert(projectID) }
        }
        .onChange(of: search) { _, _ in
            collapsedSearchProjects.removeAll()
        }
        .onChange(of: model.chatID) { _, _ in
            revealSelectedChat()
        }
        .popover(isPresented: $showingNotifications) {
            notificationsPanel
        }
        .alert(L10n.text("Название чата", "Chat title"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.text("Название", "Title"), text: $newTitle)
            Button(L10n.text("Сохранить", "Save")) { if let chat = renaming { Task { await model.renameChat(chat.id, title: newTitle) } }; renaming = nil }
            Button(L10n.text("Отмена", "Cancel"), role: .cancel) { renaming = nil }
        }
        .alert(L10n.text("Удалить чат?", "Delete chat?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { chat in
            Button(L10n.text("Удалить", "Delete"), role: .destructive) { Task { await model.deleteChat(chat.id) } }
            Button(L10n.text("Отмена", "Cancel"), role: .cancel) { }
        } message: { chat in
            Text(L10n.text("Чат «\(chat.title)» и его сообщения в очереди будут удалены. Отменить это действие нельзя. Файлы проекта останутся на месте.", "The chat “\(chat.title)” and its queued messages will be deleted. This cannot be undone. Project files will be kept."))
        }
    }
    private var sidebar: some View {
            VStack(spacing: 12) {
                HStack {
                    Text("Context Desk").font(.headline)
                    Spacer()
                    Button { showingNotifications.toggle() } label: {
                        Image(systemName: (model.notices.isEmpty && !model.state.chats.contains(where: \.hasUnreadResponse)) ? "bell" : "bell.badge.fill")
                            .foregroundStyle((model.notices.isEmpty && !model.state.chats.contains(where: \.hasUnreadResponse)) ? Color.primary : .blue)
                    }.buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Уведомления", "Notifications"))
                }.padding(.horizontal, 16).padding(.top, 16)
                Button { model.newChat() } label: {
                    Label(L10n.text("Новый чат", "New chat"), systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(DeskButtonStyle()).disabled(model.selectedProject == nil).padding(.horizontal, 12)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("Найти проект или чат", "Find a project or chat"), text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Очистить поиск", "Clear search"))
                    }
                }.padding(10).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DeskPalette.border))
                    .padding(.horizontal, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.state.chats.contains(where: { $0.isPinned && !$0.isArchived }) {
                            Text(L10n.text("Избранное", "Favorites"))
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                            ForEach(model.state.chats.filter { chat in
                                chat.isPinned && !chat.isArchived && (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search)
                                    || model.state.projects.contains { $0.id == chat.projectID && ($0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)) })
                            }) { chat in
                                chatEntry(chat, favorite: true)
                            }
                            Divider().padding(.vertical, 6)
                        }
                        Text(L10n.text("Папки проектов", "Project folders"))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                        ForEach(model.state.projects.filter { project in
                            search.isEmpty || project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search) || model.state.chats.contains { $0.projectID == project.id && !$0.isArchived && $0.title.localizedCaseInsensitiveContains(search) }
                        }) { project in
                            projectEntries(project)
                        }
                        Button { model.openProject() } label: {
                            Label(L10n.text("Добавить папки…", "Add folders…"), systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(PointerButtonStyle(base: .plain))
                        Divider().padding(.vertical, 6)
                        Button { model.showingArchive = false; model.showingJobs = true; Task { await model.refreshJobs() } } label: {
                            Label(L10n.text("По расписанию", "Scheduled jobs"), systemImage: "calendar")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(PointerButtonStyle(base: .plain))
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                }
                Button { showingLimits = true } label: {
                    Label(L10n.text("Usage и лимиты", "Usage and limits"), systemImage: "chart.bar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(DeskButtonStyle()).padding(.horizontal, 12)
                    .popover(isPresented: $showingLimits, arrowEdge: .trailing) {
                        AccountLimitsView(model: model)
                    }
                HStack {
                    Circle().fill(model.connected ? Color.primary : .secondary).frame(width: 6, height: 6)
                    Text(model.connecting ? L10n.text("Подключение…", "Connecting…") : model.accountLabel).font(.caption).lineLimit(1)
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(PointerButtonStyle(base: .plain))
                }.padding(14)
            }.background(DeskPalette.sidebar)
                .navigationSplitViewColumnWidth(min: 240, ideal: 285, max: 380)
    }
    private var detail: some View {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.blue)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Закрыть", "Close"))
                    }.padding().background(.blue.opacity(0.08))
                }
                if model.showingArchive {
                    ArchiveView(model: model)
                } else if model.showingJobs {
                    HSplitView {
                        List(model.jobs, selection: $selectedJobID) { job in Text(job.name).tag(job.id) }.frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                        if let job = model.jobs.first(where: { $0.id == selectedJobID }) { JobDetail(job: job) }
                        else { EmptyState(icon: "calendar", title: L10n.text("Задачи по расписанию", "Scheduled jobs"), text: L10n.text("Выбери задание слева.", "Select a job on the left.")) }
                    }
                } else if !model.authenticated {
                    EmptyState(icon: "person.crop.circle", title: model.connected ? L10n.text("Войди в аккаунт", "Sign in") : L10n.text("Не удалось подключиться", "Could not connect"),
                               text: model.connected ? model.accountLabel + L10n.text(". Войди через ChatGPT, чтобы начать работу.", ". Sign in with ChatGPT to get started.") : L10n.text("Повтори подключение к Codex, чтобы начать работу.", "Reconnect to Codex to get started."))
                    Button(model.connecting ? L10n.text("Подключение…", "Connecting…") : (model.connected ? L10n.text("Войти через ChatGPT", "Sign in with ChatGPT") : L10n.text("Подключиться", "Connect"))) {
                        Task { if model.connected { await model.login() } else { await model.connect() } }
                    }.buttonStyle(DeskButtonStyle()).disabled(model.connecting).padding(.bottom, 60)
                } else if model.selectedProject == nil {
                    EmptyState(icon: "folder", title: L10n.text("С какой папкой работаем?", "Which folder are we working in?"), text: L10n.text("Проект — это папка на компьютере. Добавь свои проекты, и чаты появятся под каждой папкой слева.", "A project is a folder on your computer. Add your projects, and chats will appear under each folder on the left."))
                    Button(L10n.text("Добавить папки…", "Add folders…")) { model.openProject() }.buttonStyle(DeskButtonStyle()).padding(.bottom, 60)
                } else { ChatView(model: model) }
            }.navigationTitle(model.showingArchive ? L10n.text("Архив", "Archive") : model.showingJobs ? L10n.text("Расписание", "Schedule") : (model.selectedChat?.title ?? L10n.text("Новый чат", "New chat")))
    }
    private var notificationsPanel: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(L10n.text("Уведомления", "Notifications"), systemImage: "bell.fill").font(.headline).foregroundStyle(.blue)
                    Spacer()
                    Button(L10n.text("Очистить", "Clear")) { model.notices.removeAll() }.disabled(model.notices.isEmpty)
                }
                Button(L10n.text("Включить уведомления macOS", "Enable macOS notifications")) { Task { await model.enableNotifications() } }
                Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
                if model.notices.isEmpty { Text(L10n.text("Новых уведомлений нет", "No new notifications")).foregroundStyle(.secondary).padding(.vertical) }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.notices) { notice in
                            Button {
                                showingNotifications = false
                                Task { await model.focusAction(threadID: notice.threadID) }
                            } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: "bubble.left.fill").foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(notice.title).fontWeight(.medium)
                                        Text(notice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }.padding(12).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(PointerButtonStyle(base: .plain))
                        }
                    }
                }.frame(maxHeight: 320)
            }.padding(20).frame(width: 350)
    }
    private func adjacentProjectMove(_ project: Project, offset: Int) -> (() -> Void)? {
        guard let index = model.state.projects.firstIndex(where: { $0.id == project.id }),
              model.state.projects.indices.contains(index + offset) else { return nil }
        let targetID = model.state.projects[index + offset].id
        return { _ = model.moveProject(project.id, to: targetID) }
    }

    @ViewBuilder private func projectEntries(_ project: Project) -> some View {
        let isExpanded = search.isEmpty ? expandedProjects.contains(project.id) : !collapsedSearchProjects.contains(project.id)
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ProjectHeader(project: project, expanded: isExpanded, activate: {
                    withAnimation(sidebarAnimation) {
                        if isExpanded {
                            expandedProjects.remove(project.id)
                            if !search.isEmpty { collapsedSearchProjects.insert(project.id) }
                            model.selectProject(project.id)
                        } else {
                            // Reset on opening so collapsing keeps the full content height.
                            visibleChatCounts[project.id] = nil
                            expandedProjects.insert(project.id)
                            collapsedSearchProjects.remove(project.id)
                            model.selectProject(project.id)
                        }
                    }
                }, move: { sourceID in
                    model.moveProject(sourceID, to: project.id)
                }, targeted: { targeted in
                    if targeted { dropTargetProjectID = project.id }
                    else if dropTargetProjectID == project.id { dropTargetProjectID = nil }
                }, moveUp: adjacentProjectMove(project, offset: -1), moveDown: adjacentProjectMove(project, offset: 1)) {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10, height: 16)
                            .foregroundStyle(.secondary)
                        Image(systemName: model.projectID == project.id ? "folder.fill" : "folder")
                        Text(project.name).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 0)
                        if model.state.chats.contains(where: { $0.projectID == project.id && !$0.isArchived && $0.hasUnreadResponse }) {
                            Circle().fill(.blue).frame(width: 7, height: 7)
                                .help(L10n.text("Есть непрочитанные ответы", "Unread responses"))
                                .accessibilityLabel(L10n.text("Есть непрочитанные ответы", "Unread responses"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .frame(height: 32)

                Menu {
                    Button { startChat(in: project) } label: {
                        Label(L10n.text("Новый чат", "New chat"), systemImage: "square.and.pencil")
                    }
                    Divider()
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                    } label: {
                        Label(L10n.text("Открыть в Finder", "Open in Finder"), systemImage: "folder")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(project.path, forType: .string)
                    } label: {
                        Label(L10n.text("Скопировать путь", "Copy path"), systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(L10n.text("Переместить выше", "Move up")) {
                        adjacentProjectMove(project, offset: -1)?()
                    }.disabled(adjacentProjectMove(project, offset: -1) == nil)
                    Button(L10n.text("Переместить ниже", "Move down")) {
                        adjacentProjectMove(project, offset: 1)?()
                    }.disabled(adjacentProjectMove(project, offset: 1) == nil)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointingHandCursor()
                .help(L10n.text("Действия проекта", "Project actions"))
                .accessibilityLabel(L10n.text("Действия проекта: \(project.name)", "Project actions: \(project.name)"))

                Button { startChat(in: project) } label: {
                    Image(systemName: "square.and.pencil").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(PointerButtonStyle(base: .plain))
                .help(L10n.text("Новый чат в проекте", "New chat in project"))
                .accessibilityLabel(L10n.text("Новый чат в проекте \(project.name)", "New chat in \(project.name)"))
            }
            .padding(.trailing, 4)
            .frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargetProjectID == project.id ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
            .background(model.projectID == project.id && model.chatID == nil && !model.showingJobs && !model.showingArchive ? DeskPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))

            SidebarDisclosure(isExpanded: isExpanded, animation: sidebarAnimation) {
                VStack(alignment: .leading, spacing: 0) {
                    let matching = model.state.orderedChats(projectID: project.id, archived: false).filter {
                        search.isEmpty || project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search)
                    }
                    chatEntries(matching, projectID: project.id)
                    if model.state.chats.allSatisfy({ $0.projectID != project.id || $0.isArchived }) {
                        Text(L10n.text("Пока нет чатов", "No chats yet")).font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                    }
                }
            }
        }.animation(sidebarAnimation, value: isExpanded)
    }

    private func startChat(in project: Project) {
        search = ""
        withAnimation(sidebarAnimation) {
            expandedProjects.insert(project.id)
            collapsedSearchProjects.remove(project.id)
            visibleChatCounts[project.id] = nil
            model.selectProject(project.id)
        }
    }

    @ViewBuilder private func chatEntries(_ chats: [Chat], projectID: UUID) -> some View {
        let limit = search.isEmpty ? (visibleChatCounts[projectID] ?? chatPageSize) : chats.count
        ForEach(chats.prefix(limit)) { chat in
            chatEntry(chat)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if chats.count > limit {
            Button {
                withAnimation(sidebarAnimation) {
                    visibleChatCounts[projectID] = limit + chatPageSize
                }
            } label: {
                Label(L10n.text("Показать ещё", "Show more"), systemImage: "ellipsis")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.leading, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PointerButtonStyle(base: .plain))
            .help(L10n.text("Осталось чатов: \(chats.count - limit)", "More chats: \(chats.count - limit)"))
        }
    }

    private func revealSelectedChat() {
        guard let chat = model.selectedChat, !chat.isArchived else { return }
        expandedProjects.insert(chat.projectID)
        let siblings = model.state.orderedChats(projectID: chat.projectID, archived: chat.isArchived)
        guard let index = siblings.firstIndex(where: { $0.id == chat.id }) else { return }
        let limit = (index / chatPageSize + 1) * chatPageSize
        visibleChatCounts[chat.projectID] = max(visibleChatCounts[chat.projectID] ?? chatPageSize, limit)
    }

    private func chatActions(_ chat: Chat, reorder: Bool) -> [ChatRowAction] {
        var actions: [ChatRowAction] = []
        if reorder {
            let siblings = model.state.orderedChats(projectID: chat.projectID, archived: chat.isArchived)
            if let index = siblings.firstIndex(where: { $0.id == chat.id }) {
                for (offset, title) in [(-1, L10n.text("Переместить выше", "Move up")), (1, L10n.text("Переместить ниже", "Move down"))] {
                    let target = siblings.indices.contains(index + offset) ? siblings[index + offset].id : nil
                    actions.append(ChatRowAction(title: title, enabled: target != nil) {
                        if let target { _ = model.moveChat(chat.id, to: target) }
                    })
                }
            }
        }
        actions += [
            ChatRowAction(title: chat.isPinned ? L10n.text("Открепить из избранного", "Unpin from favorites") : L10n.text("Закрепить в избранном", "Pin to favorites")) { model.toggleChatPin(chat.id) },
            ChatRowAction(title: L10n.text("Переименовать…", "Rename…")) { renaming = chat; newTitle = chat.title },
            ChatRowAction(title: chat.isArchived ? L10n.text("Восстановить из архива", "Restore from archive") : L10n.text("Архивировать", "Archive"), enabled: model.canDeleteChat(chat.id)) {
                Task {
                    await model.setChatArchived(chat.id, archived: !chat.isArchived)
                }
            },
            ChatRowAction(title: L10n.text("Удалить чат…", "Delete chat…"), enabled: model.canDeleteChat(chat.id)) { deleting = chat }
        ]
        return actions
    }

    private func chatEntry(_ chat: Chat, favorite: Bool = false) -> some View {
        Group {
            if favorite {
                Button { Task { await model.openChat(chat) } } label: { chatLabel(chat, favorite: true) }
                    .buttonStyle(PointerButtonStyle(base: .plain))
                    .contextMenu {
                        ForEach(Array(chatActions(chat, reorder: false).enumerated()), id: \.offset) { _, action in
                            Button(action.title, action: action.perform).disabled(!action.enabled)
                        }
                    }
            } else {
                // Let the original SwiftUI label determine height, including title wrapping.
                // The native interaction surface fills that size without imposing a row height.
                chatLabel(chat, favorite: false).hidden()
                    .overlay {
                        ChatRow(chat: chat, enabled: !model.isChangingChat(chat.id), activate: {
                            Task { await model.openChat(chat) }
                        }, move: { model.moveChat($0, to: chat.id) }, targeted: { targeted in
                            if targeted { dropTargetChatID = chat.id }
                            else if dropTargetChatID == chat.id { dropTargetChatID = nil }
                        }, actions: chatActions(chat, reorder: true)) { chatLabel(chat, favorite: false) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargetChatID == chat.id ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
            }
        }
        .background(model.chatID == chat.id && !model.showingJobs && !model.showingArchive ? DeskPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .disabled(model.isChangingChat(chat.id))
    }

    private func chatLabel(_ chat: Chat, favorite: Bool) -> some View {
            HStack(spacing: 8) {
                Image(systemName: chat.isArchived ? "archivebox" : "bubble.left").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.title).lineLimit(2)
                    if favorite, let project = model.state.projects.first(where: { $0.id == chat.projectID }) {
                        Text(project.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .help(project.path)
                    }
                }
                if chat.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("В избранном", "In favorites"))
                }
                Spacer(minLength: 0)
                if model.pending.contains(where: { $0.threadID == chat.id }) || chat.hasUnreadResponse {
                    Circle().fill(.blue).frame(width: 7, height: 7)
                        .help(chat.hasUnreadResponse ? L10n.text("Непрочитанный ответ", "Unread response") : L10n.text("Требуется действие", "Action required"))
                        .accessibilityLabel(chat.hasUnreadResponse ? L10n.text("Непрочитанный ответ", "Unread response") : L10n.text("Требуется действие", "Action required"))
                }
                if model.isBusy(threadID: chat.id) { ProgressView().controlSize(.small) }
            }.font(.callout).padding(.horizontal, 16).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

}

/// Keep the content mounted while animating its allocated height. A system List
/// removes rows before SwiftUI can animate this kind of continuous disclosure.
private struct SidebarDisclosure<Content: View>: View {
    let isExpanded: Bool
    let animation: Animation?
    @ViewBuilder var content: Content

    var body: some View {
        SidebarDisclosureLayout(progress: isExpanded ? 1 : 0) {
            content
        }
        .clipped()
        .opacity(isExpanded ? 1 : 0)
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(animation, value: isExpanded)
    }
}

private struct SidebarDisclosureLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Always lay out at natural height; only the enclosing viewport shrinks.
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

struct DeskButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10)
            .background(configuration.isPressed ? DeskPalette.selection : DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .pointingHandCursor()
    }
}

struct ChatView: View {
    @ObservedObject var model: DeskModel
    @State private var followOutput = true
    @State private var showingUsage = false
    @State private var composerFocused = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedProject?.name ?? "").font(.callout.weight(.semibold))
                    Text(model.selectedProject?.path ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 12)
                .overlay(alignment: .bottom) { DeskPalette.border.frame(height: 0.5) }
            if !model.authenticated {
                HStack {
                    Text(L10n.text("Войди через ChatGPT, чтобы начать чат.", "Sign in with ChatGPT to start a chat.")).font(.callout)
                    Spacer()
                    Button(model.connected ? L10n.text("Войти", "Sign in") : L10n.text("Подключиться", "Connect")) { Task { if model.connected { await model.login() } else { await model.connect() } } }
                        .buttonStyle(DeskButtonStyle()).disabled(model.connecting)
                }.padding()
            }
            if model.loadingChat {
                ChatLoadingIndicator()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                VStack {
                    EmptyState(icon: "bubble.left.and.bubble.right", title: L10n.text("Чем помочь с проектом?", "How can I help with your project?"), text: model.chatID == nil ? L10n.text("Первое сообщение создаст новый чат в папке «\(model.selectedProject?.name ?? "")»", "Your first message will create a new chat in “\(model.selectedProject?.name ?? "")”") : L10n.text("Чат в папке «\(model.selectedProject?.name ?? "")»", "Chat in “\(model.selectedProject?.name ?? "")”"))
                    if !model.selectedChatIsArchived {
                        HStack {
                            suggestion(L10n.text("Объясни проект", "Explain the project"), prompt: L10n.text("Объясни структуру этого проекта и как его запустить.", "Explain this project’s structure and how to run it."))
                            suggestion(L10n.text("Найди проблемы", "Find problems"), prompt: L10n.text("Проверь проект и расскажи о найденных проблемах.", "Review the project and describe any problems you find."))
                        }.padding(.bottom, 24)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let renderedItems = model.items
                NativeTranscript(items: renderedItems, conversationID: model.chatID, followOutput: followOutput,
                                 isWorking: model.busy, unreadCompletionID: model.selectedChat?.unreadCompletionID,
                                 unreadResponseItemID: model.chatID.flatMap { model.unreadResponseItems[$0] }) { threadID, completionID in
                    guard model.items == renderedItems else { return }
                    model.markResponseRead(threadID: threadID, completionID: completionID)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let action = model.currentAction {
                ActionView(action: action, model: model).id(action.id)
                    .task(id: "\(action.id):\(model.loadingChat)") {
                        if NSApplication.shared.isActive { model.markActionRead(action) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        model.markActionRead(action)
                    }
                    .padding(12)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)).tint(.blue).padding(.horizontal, 24)
            }
            if model.selectedChatIsArchived, let chat = model.selectedChat {
                HStack {
                    Label(L10n.text("Чат в архиве. История сохранена.", "This chat is archived. Its history is saved."), systemImage: "archivebox")
                    Spacer()
                    Button(L10n.text("Восстановить", "Restore")) { Task { await model.setChatArchived(chat.id, archived: false) } }
                        .disabled(!model.canDeleteChat(chat.id))
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
            if !model.visibleQueue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.queuePaused ? L10n.text("Очередь приостановлена", "Queue paused") : L10n.text("В очереди · \(model.visibleQueue.count)", "Queued · \(model.visibleQueue.count)"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.queuePaused && model.priorityMessageID == nil {
                            Button(L10n.text("Продолжить", "Resume")) { model.resumeQueue() }.disabled(model.busy || !model.connected || model.selectedChatIsArchived || model.selectedChat.map { model.isChangingChat($0.id) } == true)
                        }
                    }.font(.caption)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.visibleQueue) { message in
                                HStack(alignment: .center, spacing: 12) {
                                    Text(message.text).font(.callout).lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading).help(message.text)
                                    Button {
                                        Task { await model.sendQueuedMessageNow(message.id) }
                                    } label: {
                                        Label(model.priorityMessageID == message.id ? L10n.text("Останавливаю…", "Stopping…") : model.busy ? L10n.text("Прервать и отправить", "Interrupt and send") : L10n.text("Отправить сейчас", "Send now"), systemImage: "arrow.up")
                                    }.disabled(model.sending || !model.connected || model.priorityMessageID != nil || model.selectedChatIsArchived || model.selectedChat.map { model.isChangingChat($0.id) } == true)
                                    Button { model.removeQueuedMessage(message.id) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Убрать из очереди", "Remove from queue"))
                                        .disabled(model.priorityMessageID == message.id)
                                }.padding(10)
                                    .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.frame(maxHeight: min(CGFloat(model.visibleQueue.count) * 78, 180))
                }.padding(.horizontal, 24).padding(.top, 8)
            }
            if !model.selectedChatIsArchived {
            VStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty { Text(L10n.text("Напиши сообщение…", "Write a message…")).foregroundStyle(.secondary).padding(.horizontal, 21).padding(.top, 18).allowsHitTesting(false) }
                    MessageComposer(text: $model.draft, focused: $composerFocused) { Task { await model.send() } }
                        .frame(height: 84).padding(.horizontal, 16).padding(.vertical, 14).accessibilityLabel(L10n.text("Сообщение", "Message"))
                }
                HStack(spacing: 10) {
                    Picker(L10n.text("Разрешения", "Permissions"), selection: Binding(get: { model.accessMode }, set: { model.selectAccessMode($0) })) {
                        ForEach(AccessMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pointingHandCursor().labelsHidden().fixedSize().disabled(model.busy || model.sending)
                        .help(L10n.text("Режим для этой папки. Полный доступ: команды, файлы и сеть без подтверждений Codex. Применяется со следующего сообщения.", "Permissions for this folder. Full access allows commands, files, and network access without Codex approvals. Applies from the next message."))
                    Spacer()
                    if !model.models.isEmpty {
                        Picker(L10n.text("Модель", "Model"), selection: Binding(get: { model.state.model }, set: { model.selectModel($0) })) {
                            ForEach(model.models, id: \.self) { entry in Text(entry["displayName"].string ?? L10n.text("Модель", "Model")).tag(entry["model"].string ?? "") }
                        }.pointingHandCursor().labelsHidden().frame(maxWidth: 200, alignment: .trailing).disabled(model.busy)
                        if !model.supportedEfforts.isEmpty {
                            Picker(L10n.text("Рассуждение", "Reasoning"), selection: $model.effort) { ForEach(model.supportedEfforts, id: \.self) { Text($0).tag($0) } }
                                .pointingHandCursor().labelsHidden().frame(width: 100).disabled(model.busy)
                        }
                    }
                    if model.busy {
                        Button { Task { await model.interrupt() } } label: { Image(systemName: "stop.fill").frame(width: 20, height: 20) }
                            .buttonStyle(DeskButtonStyle()).help(L10n.text("Остановить ответ", "Stop response")).accessibilityLabel(L10n.text("Остановить ответ", "Stop response"))
                    }
                    Group {
                        Button { Task { await model.send() } } label: {
                            Image(systemName: "arrow.up").font(.headline).frame(width: 36, height: 36)
                                .foregroundStyle(.white)
                                .background(DeskPalette.ink.opacity(model.canSend ? 1 : 0.25), in: Circle())
                        }.buttonStyle(PointerButtonStyle(base: .plain)).keyboardShortcut(.return, modifiers: .command).disabled(!model.canSend)
                            .help(model.busy ? L10n.text("Добавить в очередь · Enter", "Add to queue · Enter") : L10n.text("Отправить · Enter", "Send · Enter")).accessibilityLabel(L10n.text("Отправить сообщение", "Send message"))
                    }
                }.padding(.horizontal, 12).padding(.bottom, 10)
            }.background(DeskPalette.canvas, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(composerFocused ? DeskPalette.focusBorder : DeskPalette.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.045), radius: 10, y: 2)
                .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 10)
            }
            HStack {
                Text(model.routeTitle(model.currentRoute)).help(model.routeMessage(model.currentRoute))
                if !model.routeIsAvailable(model.currentRoute) {
                    Text(L10n.text("Недоступен", "Unavailable")).foregroundStyle(.orange)
                }
                Button { showingUsage.toggle() } label: {
                    Text(model.currentUsage?.contextFraction.map { L10n.text("Контекст ≈\(Int($0 * 100))%", "Context ≈\(Int($0 * 100))%") } ?? L10n.text("Контекст: нет данных", "Context: no data"))
                }.buttonStyle(PointerButtonStyle(base: .plain)).popover(isPresented: $showingUsage) { UsageDetail(usage: model.currentUsage).padding(20).frame(width: 330) }
                Spacer()
                Toggle(L10n.text("Следить за ответом", "Follow response"), isOn: $followOutput).toggleStyle(.checkbox).pointingHandCursor()
                Text(L10n.text("Enter — отправить · Shift+Enter — новая строка", "Enter to send · Shift+Enter for a new line"))
            }.font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(DeskPalette.canvas)
    }
    private func suggestion(_ title: String, prompt: String) -> some View {
        Button(title) { model.draft = prompt }.buttonStyle(DeskButtonStyle())
    }
}

struct MessageRow: View {
    let item: TranscriptItem
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if item.kind == "user" { Spacer(minLength: 70) }
            else { Image(systemName: "sparkle").font(.title3).padding(.top, 4).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 10) {
                Text(item.kind == "user" ? L10n.text("Ты", "You") : "Codex").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MessageText(text: item.text)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                } label: { Label(copied ? L10n.text("Скопировано", "Copied") : L10n.text("Копировать", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption2) }
                    .buttonStyle(PointerButtonStyle(base: .plain)).foregroundStyle(.secondary)
            }.padding(item.kind == "user" ? 16 : 0)
                .background(item.kind == "user" ? Color(nsColor: DeskPalette.outgoingBubble) : .clear, in: RoundedRectangle(cornerRadius: 20))
            if item.kind != "user" { Spacer(minLength: 0) }
        }
    }
}

struct UsageDetail: View {
    let usage: UsageSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Контекст и токены", "Context and tokens")).font(.headline)
            if let usage {
                LabeledContent(L10n.text("Последний запрос", "Last request"), value: usage.last.map(String.init) ?? L10n.text("Нет данных", "No data"))
                LabeledContent(L10n.text("Окно контекста", "Context window"), value: usage.window.map(String.init) ?? L10n.text("Нет данных", "No data"))
                Divider()
                LabeledContent(L10n.text("Входные за разговор", "Conversation input"), value: usage.input.map(String.init) ?? L10n.text("Нет данных", "No data"))
                LabeledContent(L10n.text("Из них из кэша", "Cached input"), value: usage.cached.map(String.init) ?? L10n.text("Нет данных", "No data"))
                LabeledContent(L10n.text("Выходные", "Output"), value: usage.output.map(String.init) ?? L10n.text("Нет данных", "No data"))
                Text(L10n.text("Измерено: \(L10n.date(usage.measuredAt))", "Measured: \(L10n.date(usage.measuredAt))")).font(.caption)
            } else { Text(L10n.text("Показатели появятся после ответа Codex.", "Metrics will appear after Codex responds.")) }
            Text(L10n.text("Процент — оценка по последнему событию, а не точный порог сжатия. Кэш уже входит во входные токены. Эти числа не равны расходу лимита подписки.", "The percentage is an estimate from the latest event, not an exact compaction threshold. Cached tokens are included in input tokens. These numbers do not represent subscription usage."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MessageText: View {
    let text: String
    var body: some View {
        let blocks = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if index % 2 == 1 {
                    ScrollView(.horizontal) { Text(block).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12) }
                        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                        .textSelection(.enabled).lineSpacing(4)
                }
            }
        }.environment(\.openURL, OpenURLAction { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }
}

struct EmptyState: View {
    var icon: String; var title: String; var text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.medium))
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobDetail: View {
    let job: ScheduledJob
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(job.name).font(.title2.bold())
                Label(L10n.text("Только просмотр · запускает штатный Codex", "Read only · run by the standard Codex scheduler"), systemImage: "eye").foregroundStyle(.secondary)
                LabeledContent(L10n.text("Состояние", "Status"), value: job.status == "ACTIVE" ? L10n.text("Включено", "Enabled") : job.status == "PAUSED" ? L10n.text("Приостановлено", "Paused") : L10n.text("Неизвестно", "Unknown"))
                LabeledContent(L10n.text("Тип", "Type"), value: job.kind)
                VStack(alignment: .leading, spacing: 8) { Text(L10n.text("Расписание", "Schedule")).font(.headline); Text(job.schedule).textSelection(.enabled) }
                Text(L10n.text("Часовой пояс и результаты запусков здесь не проверены.", "The time zone and run results have not been verified here.")).font(.caption).foregroundStyle(.secondary)
                if let issue = job.issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Divider()
                Text(L10n.text("Задание", "Task")).font(.headline)
                Text(job.prompt).textSelection(.enabled)
                if let thread = job.targetThread { Text(L10n.text("Исходный чат: \(thread)", "Source chat: \(thread)")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DeskModel
    @AppStorage(AppLanguage.preferenceKey) private var selectedLanguage = L10n.language.rawValue
    var body: some View {
        Form {
            Section("Язык / Language") {
                Picker(L10n.text("Язык интерфейса", "Interface language"), selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(language.nativeName).tag(language.rawValue)
                    }
                }
                .pointingHandCursor()
                .onChange(of: selectedLanguage) { _, value in
                    (AppLanguage(rawValue: value) ?? .russian).save()
                }
                if selectedLanguage != L10n.language.rawValue {
                    Text("Чтобы применить язык, выйди через ⌘Q и открой приложение снова.\nTo apply the language, quit with ⌘Q and reopen the app.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Новый язык применяется после перезапуска приложения.", "Language changes take effect after restarting the app."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.text("История чатов", "Chat history")) {
                Button {
                    model.openArchive()
                    openWindow(id: "main")
                    dismiss()
                } label: {
                    Label(L10n.text("Открыть архив", "Open archive"), systemImage: "archivebox")
                }
                Text(L10n.text("Просматривай и восстанавливай архивные чаты всех проектов.", "Browse and restore archived chats from all projects."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Аккаунт Codex", "Codex account")) {
                LabeledContent(L10n.text("Аккаунт", "Account"), value: model.accountLabel)
                if model.authenticated { Button(L10n.text("Выйти из аккаунта этого приложения", "Sign out of this app")) { Task { await model.logout() } }.disabled(model.anyBusy) }
                else { Button(L10n.text("Войти через ChatGPT", "Sign in with ChatGPT")) { Task { await model.login() } }.disabled(!model.connected) }
                Button(L10n.text("Переподключить Codex", "Reconnect Codex")) { Task { await model.connect() } }.disabled(model.connecting || model.anyBusy)
            }
            Section(L10n.text("Уведомления", "Notifications")) {
                Text(model.notificationStatus).font(.callout)
                Button(L10n.text("Разрешить уведомления", "Allow notifications")) { Task { await model.enableNotifications() } }
            }
            Section(L10n.text("Браузер", "Browser")) {
                Toggle(L10n.text("Использовать Chrome DevTools", "Use Chrome DevTools"),
                       isOn: Binding(get: { model.state.browserEnabled == true }, set: { model.selectBrowserEnabled($0) }))
                Text(L10n.text("Отдельный профиль Chrome для задач агента. Входи на сайты вручную. Браузер остаётся открытым после переподключения; разрешения проектов сохраняются.", "A separate Chrome profile for agent tasks. Sign in manually. The browser stays open after reconnecting; project permissions are preserved."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L10n.text("Инструкция по установке", "Installation instructions")) {
                    if let resources = Bundle.main.resourceURL {
                        NSWorkspace.shared.open(resources.appendingPathComponent("BrowserRuntime/README.md"))
                    }
                }
                Button(model.connecting ? L10n.text("Подключение…", "Connecting…") : L10n.text("Применить настройку браузера", "Apply browser setting")) {
                    Task { await model.connect() }
                }.disabled(model.anyBusy || model.connecting)
                Text(L10n.text("Применяется при переподключении Codex после завершения текущих задач. Браузер открывается при первом обращении агента.", "Takes effect when Codex reconnects after current tasks finish. The browser opens on the agent’s first browser request."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Плагины", "Plugins")) {
                Text(L10n.text("Плагины дополнительно обрабатывают запросы Codex. Они необязательны: выбери «Без плагина», чтобы работать напрямую.", "Plugins add processing to Codex requests. They are optional: choose No plugin to work directly."))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(L10n.text("Для новых чатов", "For new chats"), selection: Binding(get: { model.defaultRoute }, set: { model.selectDefaultRoute($0) })) {
                    ForEach(model.availableRoutes, id: \.self) { Text(model.routeTitle($0)).tag($0) }
                }.pointingHandCursor()
                Text(model.routeMessage(model.defaultRoute)).font(.callout).foregroundStyle(.secondary)
                Button(model.connecting ? L10n.text("Подключение…", "Connecting…") : L10n.text("Применить выбор", "Apply selection")) {
                    Task { await model.connect() }
                }.disabled(model.anyBusy || model.connecting)
                Text(L10n.text("Переподключает Codex, чтобы запустить выбранные плагины. Дождись завершения текущих задач. Существующие чаты сохраняют свой выбор плагина.", "Reconnects Codex to start the selected plugins. Wait for current tasks to finish. Existing chats keep their plugin selection."))
                    .font(.caption).foregroundStyle(.secondary)
                if model.plugins.isEmpty {
                    Text(L10n.text("Плагины пока не установлены. Codex может работать без них.", "No plugins installed yet. Codex can work without them."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(plugin.manifest.localizedTitle()) · \(plugin.manifest.version)").font(.headline)
                        if let description = plugin.manifest.descriptionTranslations {
                            Text(description.text()).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(model.routeMessage(plugin.route)).font(.caption).foregroundStyle(.secondary)
                        if let status = model.pluginStatuses[plugin.id] {
                            ForEach(status.metrics) { metric in
                                LabeledContent(metric.localizedTitle(), value: String(metric.value))
                            }
                        }
                    }
                }
                ForEach(model.pluginIssues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                Button(L10n.text("Обновить список", "Refresh list")) { model.refreshPlugins() }.disabled(model.anyBusy || model.connecting)
                Button(L10n.text("Открыть папку плагинов", "Open plugins folder")) {
                    do {
                        try FileManager.default.createDirectory(at: model.pluginDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.pluginDirectory)
                    } catch { model.error = error.localizedDescription }
                }
                Text(L10n.text("Установи плагин с помощью его установщика, затем нажми «Обновить список».", "Use the plugin's installer, then click Refresh list."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Данные", "Data")) {
                Text(L10n.text("Разговоры и настройки этого приложения хранятся отдельно от текущего Codex.", "This app’s conversations and settings are stored separately from your existing Codex setup."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L10n.text("Открыть папку данных", "Open data folder")) { NSWorkspace.shared.open(Locations.root) }
            }
        }.formStyle(.grouped)
    }
}
