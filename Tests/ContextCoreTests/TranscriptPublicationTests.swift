import AppKit
import Combine
import ContextCore
import ContextTranscript
import AgentContract
import Testing
@testable import ContextDesk

@Test @MainActor func transcriptBatchesTextAndMetadataWithoutPublishingWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let chat = Chat(id: "stream", projectID: UUID(), title: "Fixture", model: "fixture")
    model.state.chats = [chat]; model.chatID = chat.id
    let source = try #require(chat.nativeSession)
    var workspaceChanges = 0, transcriptChanges = 0, remoteChanges = 0
    let workspace = model.objectWillChange.sink { workspaceChanges += 1 }
    let transcript = model.transcript.objectWillChange.sink { transcriptChanges += 1 }
    let remote = model.objectWillChange.merge(with: model.transcript.objectWillChange).sink { remoteChanges += 1 }
    defer { workspace.cancel(); transcript.cancel(); remote.cancel() }
    for _ in 0..<200 {
        await model.receive(.init(session: source, payload: .delta(turn: "turn", item: "reply", text: "я🙂")))
    }
    model.transcript.flush()
    #expect(model.items.count == 1)
    #expect(model.items.first?.text == String(repeating: "я🙂", count: 200))
    #expect(model.items.first?.turnID == "turn")
    #expect(workspaceChanges == 0)
    #expect(transcriptChanges < 10)
    #expect(remoteChanges == transcriptChanges)
    let published = transcriptChanges
    model.items = model.items
    model.transcript.flush()
    #expect(transcriptChanges == published)
}

@Test @MainActor func transcriptDelayedPublicationAndCancellationKeepConversationScope() async throws {
    let state = TranscriptPresentation(interval: .milliseconds(10))
    state.enqueue(id: "reply", text: "Old", turn: "a")
    state.cancelPending()
    state.replace([])
    state.enqueue(id: "reply", text: "New", turn: "b") { $0.phase = "metadata" }
    for _ in 0..<100 where state.items.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(state.items.first?.text == "New")
    #expect(state.items.first?.turnID == "b")
    #expect(state.items.first?.phase == "metadata")
    state.enqueue(id: "second", text: "Two", turn: "b") { $0.phase = "metadata" }
    state.enqueue(id: "third", text: "Three", turn: "b") { $0.phase = "metadata" }
    state.flush()
    #expect(state.items.map(\.id) == ["reply", "second", "third"])
}

@Test @MainActor func switchingChatDiscardsPendingTextAndFinalItemPublishesImmediately() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root, summaryResources: nil,
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let first = Chat(id: "first", projectID: UUID(), title: "One", model: "fixture")
    let second = Chat(id: "second", projectID: first.projectID, title: "Two", model: "fixture")
    model.state.chats = [first, second]; model.chatID = first.id
    let source = try #require(first.nativeSession), other = try #require(second.nativeSession)
    await model.receive(.init(session: source, payload: .delta(turn: "a", item: "reply", text: "Old")))
    model.chatID = second.id; model.items = []
    await model.receive(.init(session: other, payload: .delta(turn: "b", item: "reply", text: "New")))
    await model.receive(.init(session: source, payload: .delta(turn: "a", item: "reply", text: " late")))
    await model.receive(.init(session: other, payload: .item(.init(id: "reply", kind: "assistant", text: "New final"))))
    #expect(model.items.map(\.text) == ["New final"])
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.items.map(\.text) == ["New final"])
    await model.receive(.init(session: other, payload: .delta(turn: "b", item: "completed", text: "Last fragment")))
    // Exercise the immediate flush without delivering a system notification from the test runner.
    await model.receive(.init(session: nil, payload: .completed(.init(id: "b", status: .completed,
        hasError: false, error: nil, history: AgentHistoryTurn(id: "b", items: [], startedAt: nil, completedAt: nil, duration: nil, isComplete: true)))))
    #expect(model.items.last?.text == "Last fragment")
    await model.receive(.init(session: other, payload: .delta(turn: "b", item: "next", text: "Before disconnect")))
    await model.receive(.init(session: nil, payload: .disconnected))
    #expect(model.items.last?.text == "Before disconnect")
}

@Test @MainActor func nativeWorkingIndicatorStopsWhenHiddenAndKeepsFixedSize() {
    _ = NSApplication.shared
    let view = WorkingIndicatorView()
    #expect(view.intrinsicContentSize == NSSize(width: 20, height: 20))
    #expect(!view.isAnimating)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView = container; container.addSubview(view)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    view.refreshAnimation()
    if window.occlusionState.contains(.visible) && !view.reduceMotion && !NSApp.isHidden { #expect(view.isAnimating) }
    view.isHidden = true
    #expect(!view.isAnimating)
    view.isHidden = false; view.isWorking = false
    #expect(!view.isAnimating)
    view.isWorking = true
    window.orderOut(nil); view.refreshAnimation()
    #expect(!view.isAnimating)
    #expect(view.frame.size == NSSize(width: 20, height: 20))
    for language in AppLanguage.allCases {
        #expect(!L10n.text("Загрузка", "Loading", language: language).isEmpty)
    }
}
