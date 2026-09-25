import AppKit
import Foundation
import Testing
import ContextCore
import ContextTranscript
@testable import ContextDesk

@Test func unreadResponseSurvivesPersistenceAndLegacyChatsDecode() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    var chat = Chat(id: "thread", projectID: UUID(), title: "Chat", model: "")
    let legacy = try JSONEncoder().encode(chat)
    #expect(try JSONDecoder().decode(Chat.self, from: legacy).hasUnreadResponse == false)
    chat.unreadCompletionID = "turn:thread:first"
    var state = SavedState()
    state.chats = [chat]
    try await store.save(state)
    #expect(try await store.load().chats.first?.unreadCompletionID == "turn:thread:first")
    state.chats[0].unreadCompletionID = nil
    try await store.save(state)
    #expect(try await store.load().chats.first?.hasUnreadResponse == false)
}

@Test @MainActor func readingCompletionRequiresCurrentLoadedChatAndMatchingCompletion() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("state.sqlite"))
    let model = DeskModel(store: store)
    let project = Project(path: folder.path)
    model.state.projects = [project]
    model.state.chats = [Chat(id: "thread", projectID: project.id, title: "Chat", model: "")]
    model.recordUnreadCompletion(threadID: "thread", completionID: "latest")
    model.notices = [DeskNotice(threadID: "thread", title: "Ответ готов", detail: "", completionID: "latest"),
                     DeskNotice(threadID: "thread", title: "Требуется действие", detail: "")]
    model.chatID = "other"
    model.markResponseRead(threadID: "thread", completionID: "latest")
    #expect(model.state.chats[0].hasUnreadResponse)
    model.chatID = "thread"
    model.markResponseRead(threadID: "thread", completionID: "older")
    #expect(model.state.chats[0].hasUnreadResponse)
    model.loadingChat = true
    model.markResponseRead(threadID: "thread", completionID: "latest")
    #expect(model.state.chats[0].hasUnreadResponse)
    model.loadingChat = false
    model.showingJobs = true
    model.markResponseRead(threadID: "thread", completionID: "latest")
    #expect(model.state.chats[0].hasUnreadResponse)
    model.showingJobs = false
    model.markResponseRead(threadID: "thread", completionID: "latest")
    #expect(!model.state.chats[0].hasUnreadResponse)
    #expect(model.notices.count == 1)
    #expect(model.notices.first?.completionID == nil)
    // Drain the model's asynchronous persistence before removing its temporary home.
    for _ in 0..<100 {
        await Task.yield()
        if let saved = try await store.load().chats.first, !saved.hasUnreadResponse { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Read state was not persisted")
}

@Test @MainActor func unreadLongTranscriptOpensAtTopAndTracksTheActualEnd() {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    let items = [TranscriptItem(id: "reply", kind: "assistant", text: String(repeating: "Ответ агента\n", count: 100))]
    view.update(items: items, conversationID: "thread", followOutput: true, unreadCompletionID: "completion")
    view.layoutSubtreeIfNeeded()
    #expect(!view.isAtTranscriptEnd)
    view.transcript.scrollRangeToVisible(NSRange(location: view.transcript.string.utf16.count, length: 0))
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    view.contentView.scroll(to: .zero)
    view.reflectScrolledClipView(view.contentView)
    view.update(items: items + [TranscriptItem(id: "next", kind: "assistant", text: "Новый ответ")],
                conversationID: "thread", followOutput: true, unreadCompletionID: "next-completion")
    view.layoutSubtreeIfNeeded()
    #expect(!view.isAtTranscriptEnd)
}

@Test @MainActor func detachedTranscriptCannotAcknowledgeUnreadResponse() async throws {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    var acknowledged = false
    view.onReadToEnd = { _, _ in acknowledged = true }
    view.update(items: [TranscriptItem(id: "reply", kind: "assistant", text: "Короткий ответ")],
                conversationID: "thread", followOutput: true, unreadCompletionID: "completion")
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    try await Task.sleep(for: .milliseconds(20))
    #expect(!acknowledged)
}

@Test @MainActor func readingActionClearsOnlyItsNoticeWithoutApproving() {
    let model = DeskModel()
    let action = PendingAction(id: "request", rpcID: .string("request"),
                               method: "item/commandExecution/requestApproval",
                               params: .object(["threadId": .string("thread")]))
    model.pending = [action]
    model.notices = [
        DeskNotice(threadID: "thread", title: "Действие", detail: "", actionID: action.id),
        DeskNotice(threadID: "other", title: "Действие", detail: "", actionID: action.id),
        DeskNotice(threadID: "thread", title: "Ответ", detail: "", completionID: "unread")
    ]
    model.chatID = "other"
    model.markActionRead(action)
    #expect(model.notices.count == 3)
    model.chatID = "thread"
    model.loadingChat = true
    model.markActionRead(action)
    #expect(model.notices.count == 3)
    model.loadingChat = false
    model.showingJobs = true
    model.markActionRead(action)
    #expect(model.notices.count == 3)
    model.showingJobs = false
    model.markActionRead(action)
    #expect(model.notices.count == 2)
    #expect(model.notices.contains { $0.threadID == "other" })
    #expect(model.notices.contains { $0.completionID == "unread" })
    #expect(model.pending.map(\.id) == [action.id])
    model.markActionRead(action)
    #expect(model.notices.count == 2)
}

@Test @MainActor func completedAnswerCanBeReadWhileNextTurnIsRunning() {
    let view = TranscriptScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    let items = [TranscriptItem(id: "finished", kind: "assistant", text: "Готово ✅"),
                 TranscriptItem(id: "next", kind: "assistant", text: String(repeating: "Следующий ответ\n", count: 100))]
    view.update(items: items, conversationID: "thread", followOutput: false, isWorking: true,
                unreadCompletionID: "completion", unreadResponseItemID: "finished")
    view.layoutSubtreeIfNeeded()
    #expect(!view.isAtTranscriptEnd)
    #expect(view.isUnreadResponseVisible)
    view.update(items: items, conversationID: "thread", followOutput: false, isWorking: true,
                unreadCompletionID: "newer", unreadResponseItemID: "next")
    view.layoutSubtreeIfNeeded()
    #expect(!view.isUnreadResponseVisible)
}
