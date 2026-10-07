import SwiftUI
import ContextCore

struct ArchiveView: View {
    @ObservedObject var model: DeskModel
    @State private var search = ""
    @State private var summary: ArchiveSummaryRecord?

    private var archivedChats: [Chat] {
        model.state.projects.flatMap { project in
            model.state.orderedChats(projectID: project.id, archived: true).filter {
                search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                    || project.name.localizedCaseInsensitiveContains(search)
                    || project.path.localizedCaseInsensitiveContains(search)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if model.archiveViewingChat { model.archiveViewingChat = false }
                    else { model.closeArchive() }
                } label: {
                    Label(model.archiveViewingChat ? L10n.text("К архиву", "Back to archive") : L10n.text("Вернуться", "Back"), systemImage: "chevron.left")
                }.buttonStyle(DeskButtonStyle())
                Spacer()
                Label(L10n.text("Архив чатов", "Chat archive"), systemImage: "archivebox").font(.headline)
            }.padding()
            Divider()
            if model.archiveViewingChat && model.selectedChatIsArchived {
                ChatView(model: model)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("Найти чат или проект в архиве", "Find a chat or project in the archive"), text: $search)
                        .textFieldStyle(.roundedBorder)
                }.padding()
                if archivedChats.contains(where: { model.archiveSummaries[$0.id] == nil }) {
                    Button(L10n.text("Подготовить итоги архивных чатов", "Summarize archived chats")) {
                        Task { await model.queueMissingArchiveSummaries() }
                    }.buttonStyle(DeskButtonStyle()).disabled(!archivedChats.contains { model.archiveSummaries[$0.id] == nil && model.canGenerateSummary($0.id) })
                        .help(L10n.text("Создать краткие итоги для архива. Использует модель и лимиты твоего аккаунта.", "Create compact archive summaries. Uses your model and account allowance."))
                        .padding(.bottom, 10)
                }
                if archivedChats.isEmpty {
                    EmptyState(icon: "archivebox", title: search.isEmpty ? L10n.text("Архив пуст", "Archive is empty") : L10n.text("Ничего не найдено", "No results"),
                               text: search.isEmpty ? L10n.text("Архивные чаты всех проектов появятся здесь.", "Archived chats from all projects will appear here.") : L10n.text("Попробуй другое название чата или проекта.", "Try a different chat or project name."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(archivedChats) { chat in
                                HStack(spacing: 16) {
                                    Button { Task { await model.openChat(chat) } } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(chat.title).font(.headline).lineLimit(2)
                                            if let project = model.state.projects.first(where: { $0.id == chat.projectID }) {
                                                Text(project.name).font(.caption).foregroundStyle(.secondary)
                                                Text(project.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(PointerButtonStyle(base: .plain))
                                        .disabled(model.isChangingChat(chat.id))
                                    if let record = model.archiveSummaries[chat.id] {
                                        VStack(alignment: .trailing, spacing: 6) {
                                            if record.status == .ready {
                                                Button(record.status.label()) { summary = record }.buttonStyle(DeskButtonStyle())
                                            } else {
                                                Text(record.status.label()).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if [.failed, .uncertain, .stale].contains(record.status) {
                                                Button(L10n.text("Создать итог заново", "Generate summary again")) {
                                                    Task { await model.retryArchiveSummary(chat.id) }
                                                }.buttonStyle(DeskButtonStyle()).disabled(!model.canGenerateSummary(chat.id) || model.isChangingChat(chat.id))
                                                if record.status == .uncertain {
                                                    Text(L10n.text("Прошлый запрос мог выполниться. Новый использует лимиты повторно.", "The previous request may have completed. A new one uses allowance again."))
                                                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 220)
                                                }
                                            }
                                        }.help(record.issue ?? record.status.label())
                                    }
                                    Button(L10n.text("Восстановить", "Restore")) {
                                        Task { await model.setChatArchived(chat.id, archived: false) }
                                    }.buttonStyle(DeskButtonStyle()).disabled(!model.canDeleteChat(chat.id))
                                }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }.padding(.horizontal).padding(.bottom)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $summary) { record in
                ArchiveSummaryDetail(record: record) {
                    summary = nil
                    if let chat = model.state.chats.first(where: { $0.id == record.threadID }) {
                        Task { await model.openChat(chat) }
                    }
                }
            }
    }
}

private struct ArchiveSummaryDetail: View {
    let record: ArchiveSummaryRecord
    let openSource: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("Краткий итог чата", "Conversation summary")).font(.title2)
                Spacer()
                Button(L10n.text("Готово", "Done")) { dismiss() }.buttonStyle(DeskButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if record.omittedDetails {
                        Text(L10n.text("Длинные результаты инструментов сокращены; вложения не анализировались.", "Long tool results were shortened; attachments were not analyzed."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(record.parts.enumerated()), id: \.offset) { _, part in
                        Text(part.content.overview)
                        ForEach(Array(part.content.activities.enumerated()), id: \.offset) { _, activity in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(activity.goal).font(.headline)
                                lines(L10n.text("Действия", "Actions"), activity.actions)
                                if !activity.outcome.isEmpty { Text(activity.outcome) }
                                lines(L10n.text("Осталось", "Unfinished"), activity.unfinished)
                                lines(L10n.text("Повторяемые шаги", "Reusable steps"), activity.reusableSteps)
                                lines(L10n.text("Переменные данные", "Variable inputs"), activity.variableInputs)
                                Text(L10n.text("Ссылок на исходные сообщения: \(activity.evidence.count)", "Source references: \(activity.evidence.count)"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            Button(L10n.text("Открыть исходный чат", "Open source conversation"), action: openSource).buttonStyle(DeskButtonStyle())
        }.padding(24).frame(width: 640, height: 580)
    }

    @ViewBuilder private func lines(_ label: String, _ values: [String]) -> some View {
        if !values.isEmpty { Text(label + ": " + values.joined(separator: "; ")) }
    }
}
