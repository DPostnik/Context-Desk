import Foundation
import Testing
import AgentContract
import ContextCore
@testable import ContextDesk

@Test @MainActor func restartRequestsCoalesceAndCanBeCancelled() {
    let restart = AppRestartController()
    restart.enqueueRestart()
    restart.enqueueRestart()
    #expect(restart.requested)
    restart.cancel()
    #expect(!restart.requested)
    restart.terminating = true
    restart.enqueueRestart()
    #expect(!restart.requested)
}

@Test func restartHelperWaitsForOwnerAndPreservesLiteralPaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("App ' quoted $(literal).app")
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["1"]
    try owner.run()
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", AppRestartController.helperScript.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/touch"),
                        "test-relaunch", String(owner.processIdentifier), marker.path]
    try helper.run()
    try await Task.sleep(for: .milliseconds(200))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    for _ in 0..<60 {
        if !helper.isRunning { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!helper.isRunning)
    if helper.isRunning { helper.terminate() }
    #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func restartHelperDoesNotReopenWhenOwnerStaysAlive() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    let script = AppRestartController.helperScript
        .replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/touch")
        .replacingOccurrences(of: "-ge 120", with: "-ge 2")
        .replacingOccurrences(of: "/bin/sleep 1", with: "/bin/sleep 0.01")
    helper.arguments = ["-c", script, "test-timeout", String(ProcessInfo.processInfo.processIdentifier), marker.path]
    try helper.run()
    for _ in 0..<50 {
        if !helper.isRunning { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!helper.isRunning)
    if helper.isRunning { helper.terminate() }
    else { #expect(helper.terminationStatus == 1) }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func restartContinuationMapsOnlyMatchingUnarchivedChats() {
    let project = UUID()
    let claude = Chat(session: .init(connection: .appClaude, nativeID: "claude-1"), projectID: project, title: "c", model: "")
    let codex = Chat(session: .init(connection: .originalCodex, nativeID: "thread-1"), projectID: project, title: "x", model: "")
    var archived = Chat(session: .init(connection: .appClaude, nativeID: "claude-2"), projectID: project, title: "a", model: "")
    archived.archived = true
    let chats = [claude, codex, archived]
    let info = RestartContinuation.requesterInfo(environment: ["CLAUDE_CODE_SESSION_ID": "claude-1", "CODEX_THREAD_ID": "", "PATH": "/bin"])
    #expect(info == [RestartContinuation.claudeSessionKey: "claude-1"])
    #expect(RestartContinuation.chatID(requestedBy: info, in: chats) == claude.id)
    #expect(RestartContinuation.chatID(requestedBy: [RestartContinuation.codexThreadKey: "thread-1"], in: chats) == codex.id)
    // A session ID never matches a chat of the other agent, an archived chat or an unknown session.
    #expect(RestartContinuation.chatID(requestedBy: [RestartContinuation.codexThreadKey: "claude-1"], in: chats) == nil)
    #expect(RestartContinuation.chatID(requestedBy: [RestartContinuation.claudeSessionKey: "claude-2"], in: chats) == nil)
    #expect(RestartContinuation.chatID(requestedBy: nil, in: chats) == nil)
    #expect(RestartContinuation.requesterInfo(environment: ["CLAUDE_CODE_SESSION_ID": String(repeating: "a", count: 129)]).isEmpty)
}

@Test func restartContinuationIsConsumedOnceAndExpires() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let now = Date()
    try RestartContinuation(chatIDs: ["a", "b"], requestedAt: now).save(to: url)
    #expect(RestartContinuation.take(from: url, now: now.addingTimeInterval(5)) == ["a", "b"])
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(RestartContinuation.take(from: url, now: now).isEmpty)
    try RestartContinuation(chatIDs: ["a"], requestedAt: now).save(to: url)
    #expect(RestartContinuation.take(from: url, now: now.addingTimeInterval(RestartContinuation.maximumAge + 1)).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
