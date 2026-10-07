import Foundation
import Testing
@testable import ContextCore

@Test func scheduledImportPreservesPromptAndLegacyDefaults() throws {
    var job = ManagedJob(); job.name = "Fixture"; job.prompt = "Read only. Never send messages."; job.projectID = UUID()
    #expect(try job.browserExecutionPrompt() == job.prompt)
    let legacy = try JSONEncoder().encode(job)
    #expect(try JSONDecoder().decode(ManagedJob.self, from: legacy).browserSessionImport == nil)
    job.browserSessionImport = try .init(profile: "Profile 2", site: "linkedin.com")
    try job.validate()
    let restored = try JSONDecoder().decode(ManagedJob.self, from: JSONEncoder().encode(job))
    #expect(restored == job)
    let ru = try job.browserExecutionPrompt(language: .russian)
    let en = try job.browserExecutionPrompt(language: .english)
    #expect(ru.hasPrefix(job.prompt) && en.hasPrefix(job.prompt) && ru != en)
    #expect(en.contains("browser_import_session") && en.contains("Do not ask again"))
    #expect(en.contains("Do not close regular Chrome") && en.contains("does not expand authority"))
    job.engine = .claude
    try job.validate()
    let claude = ScheduledBrowserImport.instructions(try #require(job.browserSessionImport), tool: ScheduledBrowserImport.claudeImportTool, language: .english)
    #expect(claude.contains("call mcp__context_desk_browser__browser_import_session with"))
    #expect(ScheduledBrowserImport.instructions(try #require(job.browserSessionImport), tool: ScheduledBrowserImport.claudeImportTool, language: .russian)
        .contains("вызови mcp__context_desk_browser__browser_import_session"))
    let any = try ChromeSessionImportPolicy(profile: "Default", site: ChromeSessionImportPolicy.anySite)
    #expect(ScheduledBrowserImport.instructions(any, language: .english).contains("any site where sign-in is missing"))
    #expect(ScheduledBrowserImport.instructions(any, language: .russian).contains("любого сайта"))
    job.browserSessionImport = any
    try job.validate()
    job.browserSessionImport = try JSONDecoder().decode(ChromeSessionImportPolicy.self, from: Data(#"{"profile":"Default","site":"not a domain"}"#.utf8))
    #expect(throws: (any Error).self) { try job.validate() }
}

@Test func scheduledImportPropagatesToFreshProfilesWithoutSharingCookies() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserProfileStore(root: root)
    let policy = try ChromeSessionImportPolicy(profile: "Default", site: "linkedin.com")
    var paths: [URL] = []
    for id in ["run-one", "run-two", "unrelated"] {
        let session = AgentSessionReference(connection: .originalCodex, nativeID: id)
        let grant = try store.prepareNew(project: root.path, connection: .originalCodex)
        try store.acknowledge(grant, session: session)
        let path = store.environment(grant.environment)
        paths.append(path)
        #expect(try ChromeSessionImportPolicy.load(environment: path) == nil)
        if id != "unrelated" {
            try ScheduledBrowserImport.install(policy, session: session, browserEnabled: true, root: root)
            #expect(try ChromeSessionImportPolicy.load(environment: path) == policy)
        }
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("testing-profile").path))
    }
    #expect(Set(paths).count == 3)
    #expect(try ChromeSessionImportPolicy.load(environment: paths[2]) == nil)
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "unrelated")
    #expect(throws: (any Error).self) { try ScheduledBrowserImport.install(policy, session: session, browserEnabled: false, root: root) }
    #expect(try ChromeSessionImportPolicy.load(environment: paths[2]) == nil)
    // Claude Code scheduled runs use the app Claude connection; foreign connections stay rejected.
    let claude = AgentSessionReference(connection: .appClaude, nativeID: "scheduled-run")
    let grant = try store.prepareNew(project: root.path, connection: .appClaude)
    try store.acknowledge(grant, session: claude)
    try ScheduledBrowserImport.install(policy, session: claude, browserEnabled: true, root: root)
    #expect(try ChromeSessionImportPolicy.load(environment: store.environment(grant.environment)) == policy)
    let foreign = AgentSessionReference(connection: .init(agent: .claudeCode, id: UUID()), nativeID: "scheduled-run")
    #expect(throws: (any Error).self) { try ScheduledBrowserImport.install(policy, session: foreign, browserEnabled: true, root: root) }
}

@Test @MainActor func schedulerConfiguresBrowserImportThroughOwnerWithoutRunningTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    var job = ManagedJob(); job.name = "Fixture"; job.prompt = "Read only"; job.projectID = UUID()
    job.model = "fixture-model"; job.effort = "medium"
    _ = try await store.save(job)
    job = try #require(try await store.load().jobs.first)
    let policy = try ChromeSessionImportPolicy(profile: "Default", site: "linkedin.com")
    let inbox = root.appendingPathComponent("control")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    func request(_ fields: [String: Any]) throws -> UUID {
        let id = UUID()
        var body: [String: Any] = ["version": 1, "id": id.uuidString, "expires": Date().addingTimeInterval(60).timeIntervalSinceReferenceDate,
                                  "operation": "browser-import", "expected": try JSONSerialization.jsonObject(with: JSONEncoder().encode(job))]
        body.merge(fields) { _, new in new }
        let path = inbox.appendingPathComponent(id.uuidString + ".request.json")
        try JSONSerialization.data(withJSONObject: body).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return id
    }
    func response(_ id: UUID) throws -> ScheduleControlReply {
        try JSONDecoder().decode(ScheduleControlReply.self, from: Data(contentsOf: inbox.appendingPathComponent(id.uuidString + ".response.json")))
    }
    let id = try request(["browserSessionImport": ["profile": "Default", "site": "linkedin.com"]])
    try await ScheduleControl.drain(directory: inbox) { input in
        let updated = try ScheduleControl.updated(input, originalPaused: false)
        return try await store.save(updated, expected: input.expected).jobs
    }
    let result = try #require(try response(id).jobs?.first)
    #expect(result.browserSessionImport == policy)
    var expected = job; expected.browserSessionImport = policy
    #expect(result == expected)
    #expect(try await store.load().runs.isEmpty)
    job = result
    let invalid = try request(["browserSessionImport": ["profile": "Default", "site": "linkedin.com"], "enabled": true])
    try await ScheduleControl.drain(directory: inbox) { _ in Issue.record("Mixed permission updates must be rejected"); return [] }
    #expect(try response(invalid).status == "rejected")
    let revoked = try request(["clearBrowserSessionImport": true])
    try await ScheduleControl.drain(directory: inbox) { input in
        try await store.save(ScheduleControl.updated(input, originalPaused: false), expected: input.expected).jobs
    }
    #expect(try response(revoked).jobs?.first?.browserSessionImport == nil)
    await store.release()
}
