import Foundation
import Testing
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
