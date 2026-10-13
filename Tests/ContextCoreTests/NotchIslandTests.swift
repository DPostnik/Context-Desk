import Foundation
import Testing
@testable import ContextCore

@Test func notchGeometryComesFromTheMenuBarAreasBesideTheCutout() {
    // MacBook Pro 14": 1512 pt wide, 32 pt safe area, 185 pt notch.
    #expect(NotchGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5)
            == NotchGeometry(width: 185, height: 32))
    #expect(NotchGeometry(screenWidth: 2560, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil) == nil)
    #expect(NotchGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: nil, auxiliaryRightWidth: 600) == nil)
    #expect(NotchGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: 100, auxiliaryRightWidth: 100) == nil)
}

@Test func notchChatsLeadWithTheOneThatNeedsTheUser() {
    let now = Date()
    #expect(NotchChat.phase(running: true, waiting: true, unread: true) == .waiting)
    #expect(NotchChat.phase(running: true, waiting: false, unread: true) == .working)
    #expect(NotchChat.phase(running: false, waiting: false, unread: true) == .finished)
    #expect(NotchChat.phase(running: false, waiting: false, unread: false) == nil)
    let chats = [
        NotchChat(id: "done", title: "", project: "", phase: .finished, updated: now),
        NotchChat(id: "old-work", title: "", project: "", phase: .working, updated: now.addingTimeInterval(-60)),
        NotchChat(id: "work", title: "", project: "", phase: .working, updated: now),
        NotchChat(id: "wait", title: "", project: "", phase: .waiting, updated: now.addingTimeInterval(-600))
    ]
    #expect(NotchChat.ordered(chats).map(\.id) == ["wait", "work", "old-work", "done"])
    #expect(NotchChat.ordered(chats, limit: 2).map(\.id) == ["wait", "work"])
    #expect(NotchSummary(chats) == .waiting(1))
    #expect(NotchSummary(Array(chats.prefix(3))) == .working(2))
    #expect(NotchSummary(Array(chats.prefix(1))) == .finished(1))
    #expect(NotchSummary([]) == .idle)
}

@Test func notchTrackerAnnouncesOnlyChangesAfterTheBaseline() {
    var tracker = NotchTracker()
    // Restored state at launch never replays sounds.
    #expect(tracker.update(working: ["a"], waitingRequests: ["r1"], waitingChats: ["b"]).isEmpty)
    #expect(tracker.update(working: ["a", "c"], waitingRequests: ["r1", "r2"], waitingChats: ["b", "c"])
            == NotchTransition(finished: [], newlyWaiting: ["r2"]))
    // "a" finished; "c" stopped to wait for the user and is not announced as finished.
    #expect(tracker.update(working: [], waitingRequests: ["r2"], waitingChats: ["c"]) == NotchTransition(finished: ["a"], newlyWaiting: []))
    #expect(tracker.update(working: [], waitingRequests: [], waitingChats: []).isEmpty)
}

@Test func notchModeFollowsHoverRequestsAndAutoHide() {
    let hide = NotchPreferences(autoHide: true, sound: true), keep = NotchPreferences(autoHide: false, sound: false)
    #expect(NotchPolicy.restingMode(summary: .idle, preferences: hide) == .hidden)
    #expect(NotchPolicy.restingMode(summary: .idle, preferences: keep) == .compact)
    #expect(NotchPolicy.restingMode(summary: .working(1), preferences: hide) == .compact)
    #expect(NotchPolicy.mode(resting: .hidden, hovering: true, pinnedOpen: false, peeking: true) == .expanded)
    #expect(NotchPolicy.mode(resting: .compact, hovering: false, pinnedOpen: true, peeking: false) == .expanded)
    #expect(NotchPolicy.mode(resting: .hidden, hovering: false, pinnedOpen: false, peeking: true) == .peek)
    #expect(NotchPolicy.mode(resting: .compact, hovering: false, pinnedOpen: false, peeking: false) == .compact)
}

@Test func notchPreferencesPersistAndDurationsAreLocalized() throws {
    let defaults = try #require(UserDefaults(suiteName: "notch-tests-\(UUID().uuidString)"))
    #expect(NotchPreferences.load(from: defaults) == NotchPreferences(autoHide: true, sound: true))
    NotchPreferences(autoHide: false, sound: false).save(to: defaults)
    #expect(NotchPreferences.load(from: defaults) == NotchPreferences(autoHide: false, sound: false))
    let start = Date(timeIntervalSince1970: 0)
    #expect(NotchPolicy.duration(since: start, now: start.addingTimeInterval(42), language: .russian) == "42 с")
    #expect(NotchPolicy.duration(since: start, now: start.addingTimeInterval(42), language: .english) == "42s")
    #expect(NotchPolicy.duration(since: start, now: start.addingTimeInterval(3_900), language: .russian) == "1 ч 5 мин")
    #expect(NotchPolicy.duration(since: start, now: start.addingTimeInterval(3_900), language: .english) == "1h 5m")
}
