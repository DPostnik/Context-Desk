import Foundation
import ContextCore

extension DeskModel {
    var browserProfileOwnerNames: [String: String] {
        Dictionary(state.chats.compactMap { chat in
            chat.nativeSession.map { (BrowserProfileStore.key($0), chat.title) }
        }, uniquingKeysWith: { first, _ in first })
    }
    func changeBrowserProfile(chatID: String, action: BrowserProfileAction) async throws {
        guard !isBusy(threadID: chatID), !isChangingChat(chatID),
              !pending.contains(where: { $0.threadID == chatID }),
              let chat = state.chats.first(where: { $0.id == chatID }),
              let session = chat.nativeSession, session.connection == .originalCodex,
              let project = state.projects.first(where: { $0.id == chat.projectID }),
              let runtime = Bundle.main.resourceURL?.appendingPathComponent("BrowserRuntime"),
              state.browserEnabled == true else { throw BrowserProfileError.busy }
        configuringBrowserChats.insert(chatID)
        defer { configuringBrowserChats.remove(chatID) }
        let client = connection
        let store = BrowserProfileStore()
        if try store.current(session: session) == nil {
            try await client.resume(session, projectPath: project.path, access: chat.resolvedAccessMode(in: project), route: chat.route ?? .direct)
        }
        try await Task.detached {
            switch action {
            case .rename(let name): try store.rename(session: session, name: name)
            case .release:
                try store.release(session: session) { try BrowserProfileControl.verifyClosed(environment: $0, runtime: runtime) }
            case .select(let id):
                try store.select(id, session: session, project: project.path) { try BrowserProfileControl.verifyClosed(environment: $0, runtime: runtime) }
            case .takeControl: try store.humanControl(session: session, take: true)
            case .returnControl: try store.humanControl(session: session, take: false)
            }
        }.value
        switch action {
        case .select, .returnControl:
            try await client.resume(session, projectPath: project.path, access: chat.resolvedAccessMode(in: project), route: chat.route ?? .direct)
        default: break
        }
    }
}
