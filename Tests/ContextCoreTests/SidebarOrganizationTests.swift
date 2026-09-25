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
