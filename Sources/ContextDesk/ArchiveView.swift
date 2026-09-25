import SwiftUI
import ContextCore

struct ArchiveView: View {
    @ObservedObject var model: DeskModel
    @State private var search = ""

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
    }
}
