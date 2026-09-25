import Foundation
import Testing
import ContextCore

@Test func projectReorderingPreservesIdentityAndRejectsUnknownDrops() {
    let a = Project(path: "/tmp/a"), b = Project(path: "/tmp/b"), c = Project(path: "/tmp/c")
    var state = SavedState()
    state.projects = [a, b, c]
    state.chats = [Chat(id: "chat", projectID: a.id, title: "Chat", model: "")]
    let changed1 = state.moveProject(a.id, to: c.id)
    #expect(changed1)
    #expect(state.projects.map(\.id) == [b.id, c.id, a.id])
    let changed2 = state.moveProject(a.id, to: b.id)
    #expect(changed2)
    #expect(state.projects == [a, b, c])
    let changed3 = state.moveProject(a.id, to: a.id)
    #expect(!changed3)
    let changed4 = state.moveProject(UUID(), to: b.id)
    #expect(!changed4)
    let changed5 = state.moveProject(a.id, to: UUID())
    #expect(!changed5)
    #expect(state.projects == [a, b, c])
    #expect(state.chats[0].projectID == a.id)
}

@Test func projectOrderAndCrossProjectPinsSurviveStoreReload() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("state.sqlite")
    var state = SavedState()
    let a = Project(path: "/tmp/a"), b = Project(path: "/tmp/b")
    state.projects = [a, b]
    state.chats = [Chat(id: "a", projectID: a.id, title: "A", model: ""),
                   Chat(id: "b", projectID: b.id, title: "B", model: "")]
    // Legacy records have no pin key at all.
    let legacy = try JSONEncoder().encode(state)
    #expect(!String(decoding: legacy, as: UTF8.self).contains("pinned"))
    #expect(try JSONDecoder().decode(SavedState.self, from: legacy).chats.allSatisfy { !$0.isPinned })
    let changed6 = state.moveProject(b.id, to: a.id)
    #expect(changed6)
    let changed7 = state.toggleChatPin("a")
    #expect(changed7)
    let changed8 = state.toggleChatPin("b")
    #expect(changed8)
    let changed9 = state.toggleChatPin("missing")
    #expect(!changed9)
    state.chats[1].archived = true
    try await AppStore(file: file).save(state)
    var restored = try await AppStore(file: file).load()
    #expect(restored.projects == [b, a])
    #expect(restored.chats.filter(\.isPinned).map(\.id) == ["a", "b"])
    #expect(restored.chats[1].isArchived)
    let changed10 = restored.toggleChatPin("a")
    #expect(changed10)
    try await AppStore(file: file).save(restored)
    #expect(try await AppStore(file: file).load().chats.filter(\.isPinned).map(\.id) == ["b"])
    restored.chats.removeAll { $0.id == "b" }
    try await AppStore(file: file).saveDeletingChat(restored, threadID: "b")
    #expect(try await AppStore(file: file).load().chats.filter(\.isPinned).isEmpty)
}

@Test func chatOrderingKeepsLegacyRecencyUntilReorderedAndScopesMoves() {
    let project = UUID(), other = UUID()
    var state = SavedState()
    for (index, id) in ["a", "b", "c", "foreign", "archive"].enumerated() {
        var chat = Chat(id: id, projectID: id == "foreign" ? other : project, title: id, model: "")
        chat.updated = Date(timeIntervalSince1970: Double(index))
        chat.archived = id == "archive"
        state.chats.append(chat)
    }
    #expect(state.orderedChats(projectID: project, archived: false).map(\.id) == ["c", "b", "a"])
    let changed = state.moveChat("a", to: "c")
    #expect(changed)
    #expect(state.orderedChats(projectID: project, archived: false).map(\.id) == ["a", "c", "b"])
    state.chats[1].updated = .distantFuture
    #expect(state.orderedChats(projectID: project, archived: false).map(\.id) == ["a", "c", "b"])
    let down = state.moveChat("a", to: "b")
    #expect(down)
    #expect(state.orderedChats(projectID: project, archived: false).map(\.id) == ["c", "b", "a"])
    let foreign = state.moveChat("a", to: "foreign")
    let archive = state.moveChat("a", to: "archive")
    let missing = state.moveChat("missing", to: "a")
    let same = state.moveChat("a", to: "a")
    #expect(!foreign && !archive && !missing && !same)
    #expect(state.chats[3].sidebarOrder == nil && state.chats[4].sidebarOrder == nil)
    state.chats.append(Chat(id: "new", projectID: project, title: "New", model: ""))
    #expect(state.orderedChats(projectID: project, archived: false).map(\.id) == ["new", "c", "b", "a"])
}

@Test func manualChatOrderSurvivesReloadAndDeletion() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("state.sqlite")
    let project = UUID()
    var state = SavedState()
    state.chats = (0..<8).map { index in
        var chat = Chat(id: "chat-\(index)", projectID: project, title: "Same title", model: "")
        chat.updated = Date(timeIntervalSince1970: Double(index))
        return chat
    }
    let legacy = try JSONEncoder().encode(state)
    #expect(!String(decoding: legacy, as: UTF8.self).contains("sidebarOrder"))
    #expect(try JSONDecoder().decode(SavedState.self, from: legacy).chats.allSatisfy { $0.sidebarOrder == nil })
    _ = state.moveChat("chat-0", to: "chat-7")
    try await AppStore(file: file).save(state)
    var restored = try await AppStore(file: file).load()
    #expect(restored.orderedChats(projectID: project, archived: false).map(\.id) == ["chat-0", "chat-7", "chat-6", "chat-5", "chat-4", "chat-3", "chat-2", "chat-1"])
    restored.chats.removeAll { $0.id == "chat-7" }
    try await AppStore(file: file).saveDeletingChat(restored, threadID: "chat-7")
    let loaded = try await AppStore(file: file).load()
    #expect(loaded.orderedChats(projectID: project, archived: false).prefix(3).map(\.id) == ["chat-0", "chat-6", "chat-5"])
}
