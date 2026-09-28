import AppKit
import Testing
import ContextCore
@testable import ContextTranscript

@MainActor private func readingItems() -> [TranscriptItem] {
    (0..<20).map { TranscriptItem(id: "message-\($0)", kind: "assistant",
        text: String(repeating: "Reading line / Строка чтения\n", count: 12)) }
}

@MainActor private func readingView(_ positions: TranscriptReadingPositions) -> TranscriptScrollView {
    let view = TranscriptScrollView(positions: positions)
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    return view
}

@Test @MainActor func readingPositionSurvivesSwitchAndViewRecreation() {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    view.contentView.scroll(to: NSPoint(x: 0, y: 900))
    view.reflectScrolledClipView(view.contentView)
    let y = view.contentView.bounds.origin.y
    #expect(y > 0)
    #expect(!view.isAtTranscriptEnd)
    view.update(items: items, conversationID: "b", followOutput: true)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    view.update(items: items, conversationID: "a", followOutput: true, unreadCompletionID: "new")
    view.layoutSubtreeIfNeeded()
    #expect(abs(view.contentView.bounds.origin.y - y) < 2)

    let recreated = readingView(positions)
    recreated.update(items: items, conversationID: "a", followOutput: true, unreadCompletionID: "new")
    recreated.layoutSubtreeIfNeeded()
    #expect(abs(recreated.contentView.bounds.origin.y - y) < 2)
}

@Test @MainActor func readingAnchorSurvivesPrependedHistoryAndNewAnswers() throws {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: true)
    view.layoutSubtreeIfNeeded()
    view.contentView.scroll(to: NSPoint(x: 0, y: 1800))
    view.reflectScrolledClipView(view.contentView)
    guard case let .anchor(id, character, _, _) = try #require(positions.values["a"]) else {
        Issue.record("Expected a reading anchor"); return
    }
    let expanded = [TranscriptItem(id: "older", kind: "user", text: String(repeating: "Older history\n", count: 30))]
        + items + [TranscriptItem(id: "new", kind: "assistant", text: "New answer")]
    view.update(items: expanded, conversationID: "a", followOutput: true, unreadCompletionID: "new")
    view.layoutSubtreeIfNeeded()
    guard case let .anchor(restoredID, restoredCharacter, _, _) = try #require(positions.values["a"]) else {
        Issue.record("Expected the restored reading anchor"); return
    }
    #expect(restoredID == id)
    #expect(restoredCharacter == character)
    #expect(!view.isAtTranscriptEnd)
}

@Test @MainActor func returningFromEndFollowsNewContentWithFollowingDisabled() {
    let positions = TranscriptReadingPositions()
    let items = readingItems()
    let view = readingView(positions)
    view.update(items: items, conversationID: "a", followOutput: false)
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
    view.update(items: items, conversationID: "b", followOutput: false)
    view.layoutSubtreeIfNeeded()
    view.update(items: items + [TranscriptItem(id: "new", kind: "assistant", text: String(repeating: "New\n", count: 50))],
                conversationID: "a", followOutput: false, unreadCompletionID: "new")
    view.layoutSubtreeIfNeeded()
    #expect(view.isAtTranscriptEnd)
}
