import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

private func controlRequest(job: ManagedJob? = nil) throws -> ScheduleControlRequest {
    var object: [String: Any] = ["version": 1, "id": UUID().uuidString, "expires": Date().addingTimeInterval(60).timeIntervalSinceReferenceDate, "operation": job == nil ? "list" : "update"]
    if let job { object["expected"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) }
    return try JSONDecoder().decode(ScheduleControlRequest.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func scheduleControlPreservesPermissionsAndRequiresPausedSource() throws {
    var job = ManagedJob(); job.name = "Test"; job.prompt = "old"; job.projectID = UUID(); job.source = "codex:test"
    job.model = "selected-model"; job.effort = "medium"
    var request = try controlRequest(job: job); request.enabled = true; request.prompt = "new"; request.confirmSourceDisabled = true
    #expect(throws: (any Error).self) { try ScheduleControl.updated(request, originalPaused: false) }
    let result = try ScheduleControl.updated(request, originalPaused: true)
    #expect(result.enabled && result.sourceDisabled && result.prompt == "new")
    #expect(result.projectID == job.projectID && result.route == job.route && result.model == job.model && result.effort == job.effort)
    #expect(result.acceptsExternalPolicy == job.acceptsExternalPolicy)
}

@Test func scheduleControlRejectsConcurrentChangesAndBusyJobs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    var job = ManagedJob(); job.name = "Test"; job.prompt = "old"; job.projectID = UUID()
    _ = try await store.save(job)
    var other = job; other.prompt = "UI edit"; _ = try await store.save(other)
    job.prompt = "stale edit"
    await #expect(throws: (any Error).self) { try await store.save(job, expected: job) }
    #expect(try await store.load().jobs.first?.prompt == "UI edit")
    _ = try await store.claim(other.id, manual: true)
    await #expect(throws: (any Error).self) { try await store.save(other, expected: other) }
    await store.release()
}

@Test @MainActor func scheduleControlClaimsOnceAndRejectsExpiredCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let request = try controlRequest()
    let file = root.appendingPathComponent(request.id.uuidString + ".request.json")
    let data = try JSONEncoder().encode(request)
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var count = 0
    try await ScheduleControl.drain(directory: root) { _ in count += 1; return [] }
    #expect(count == 1)
    // Resubmission with the same ID and a lost reply cannot repeat a mutation.
    try FileManager.default.removeItem(at: root.appendingPathComponent(request.id.uuidString + ".response.json"))
    try data.write(to: file)
    try await ScheduleControl.drain(directory: root) { _ in count += 1; return [] }
    #expect(count == 1)
    var expired = try controlRequest(); expired.expires = Date().addingTimeInterval(-1)
    try JSONEncoder().encode(expired).write(to: root.appendingPathComponent(expired.id.uuidString + ".request.json"))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(expired.id.uuidString + ".request.json").path)
    try await ScheduleControl.drain(directory: root) { _ in count += 1; return [] }
    let reply = try JSONDecoder().decode(ScheduleControlReply.self, from: Data(contentsOf: root.appendingPathComponent(expired.id.uuidString + ".response.json")))
    #expect(reply.status == "rejected" && count == 1)
}

@Test @MainActor func scheduleControlUpdatesLiveModelAndPersistsWithoutDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inbox = root.appendingPathComponent("control"), originals = root.appendingPathComponent("originals")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: originals.appendingPathComponent("test"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("version = 1\nid = \"test\"\nname = \"Original\"\nkind = \"cron\"\nstatus = \"PAUSED\"\n".utf8).write(to: originals.appendingPathComponent("test/automation.toml"))
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    let project = Project(path: root.path); model.state.projects = [project]; model.schedulerReady = true
    var job = ManagedJob(); job.name = "Test"; job.prompt = "old"; job.projectID = project.id; job.source = "codex:test"
    #expect(await model.saveJob(job))
    var request = try controlRequest(job: job); request.enabled = true; request.prompt = "no submissions"; request.confirmSourceDisabled = true
    let file = inbox.appendingPathComponent(request.id.uuidString + ".request.json")
    try JSONEncoder().encode(request).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    await model.processScheduleControl(directory: inbox, originals: originals)
    let updated = try #require(model.jobLedger.jobs.first)
    #expect(updated.enabled && updated.sourceDisabled && updated.prompt == "no submissions")
    #expect(updated.nextRun != nil && model.jobLedger.runs.isEmpty)
    #expect(try await store.load().jobs.first == updated)
    await model.stopScheduler()
}

@Test @MainActor func scheduleControlFailsClosedAndReportsUncertainPersistence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let request = try controlRequest()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    object["shell"] = "must never execute"
    let file = root.appendingPathComponent(request.id.uuidString + ".request.json")
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var called = false
    try await ScheduleControl.drain(directory: root) { _ in called = true; return [] }
    #expect(!called)
    let second = try controlRequest()
    let secondFile = root.appendingPathComponent(second.id.uuidString + ".request.json")
    try JSONEncoder().encode(second).write(to: secondFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secondFile.path)
    try await ScheduleControl.drain(directory: root) { _ in throw ScheduleControlUncertain() }
    let reply = try JSONDecoder().decode(ScheduleControlReply.self, from: Data(contentsOf: root.appendingPathComponent(second.id.uuidString + ".response.json")))
    #expect(reply.status == "uncertain")
}

private func importFixture(_ root: URL, rule: String = "FREQ=DAILY;BYHOUR=9;BYMINUTE=30") throws -> URL {
    let folder = root.appendingPathComponent("sources/routine")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("version = 1\nid = \"routine\"\nname = \"Routine\"\nkind = \"heartbeat\"\nstatus = \"ACTIVE\"\nprompt = \"Read, never send.\"\nrrule = \"\(rule)\"\n".utf8).write(to: folder.appendingPathComponent("automation.toml"))
    return folder.deletingLastPathComponent()
}

@Test func scheduleImportPreservesSourceAndRejectsDriftFiniteRulesAndPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let originals = try importFixture(root)
    let file = originals.appendingPathComponent("routine/automation.toml")
    let bytes = try Data(contentsOf: file)
    let source = try ScheduleImports.source("routine", directory: originals)
    let project = ScheduleProject(id: UUID(), path: root.path)
    var input = ScheduleImport(sourceID: "routine", sourceDigest: source.digest, projectID: project.id,
        timeZone: "Europe/Warsaw", model: "test-model", effort: "medium", recurring: true)
    let job = try ScheduleImports.prepare(input, directory: originals, project: project)
    #expect(!job.enabled && !job.sourceDisabled && job.nextRun == nil)
    #expect(job.source == "codex:routine" && job.prompt == "Read, never send.")
    #expect(job.schedule.rule == source.definition.rawRule && job.schedule.timeZone == "Europe/Warsaw")
    #expect(job.route == .direct && job.acceptsExternalPolicy == nil && job.routine == nil)
    #expect(try Data(contentsOf: file) == bytes)
    input.recurring = false
    #expect(throws: (any Error).self) { try ScheduleImports.prepare(input, directory: originals, project: project) }
    input.recurring = true; input.sourceDigest = "stale"
    #expect(throws: (any Error).self) { try ScheduleImports.prepare(input, directory: originals, project: project) }
    #expect(throws: (any Error).self) { try ScheduleImports.source("../routine", directory: originals) }
    let linked = originals.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: originals.appendingPathComponent("routine"))
    #expect(throws: (any Error).self) { try ScheduleImports.source("linked", directory: originals) }
    _ = try importFixture(root, rule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=30;UNTIL=20261026T225959Z")
    input.sourceDigest = try ScheduleImports.source("routine", directory: originals).digest
    #expect(throws: (any Error).self) { try ScheduleImports.prepare(input, directory: originals, project: project) }
    try Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "id = \"routine\"", with: "id = \"other\"").utf8).write(to: file)
    #expect(throws: (any Error).self) { try ScheduleImports.source("routine", directory: originals) }
}

@Test @MainActor func scheduleControlImportsDisabledOnceThroughOwningScheduler() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let originals = try importFixture(root)
    let inbox = root.appendingPathComponent("control")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    let project = Project(path: root.path); model.state.projects = [project]; model.schedulerReady = true
    var request = try controlRequest(); request.operation = "import"
    request.importRequest = ScheduleImport(sourceID: "routine", sourceDigest: try ScheduleImports.source("routine", directory: originals).digest,
        projectID: project.id, timeZone: "Europe/Warsaw", model: "test-model", effort: "medium", recurring: true)
    func post(_ request: ScheduleControlRequest) throws {
        let file = inbox.appendingPathComponent(request.id.uuidString + ".request.json")
        try JSONEncoder().encode(request).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    try post(request)
    await model.processScheduleControl(directory: inbox, originals: originals)
    let job = try #require(model.jobLedger.jobs.first)
    #expect(!job.enabled && !job.sourceDisabled && model.jobLedger.runs.isEmpty)
    #expect(job.projectID == project.id && job.source == "codex:routine")
    #expect(try ScheduleImports.source("routine", directory: originals).definition.status == "ACTIVE")
    await model.processScheduleControl(directory: inbox, originals: originals)
    #expect(model.jobLedger.jobs.count == 1)
    request.id = UUID(); try post(request)
    await model.processScheduleControl(directory: inbox, originals: originals)
    let reply = try JSONDecoder().decode(ScheduleControlReply.self, from: Data(contentsOf: inbox.appendingPathComponent(request.id.uuidString + ".response.json")))
    #expect(reply.status == "rejected" && model.jobLedger.jobs.count == 1)
    var update = try controlRequest(job: job); update.enabled = true; update.confirmSourceDisabled = true
    try post(update); await model.processScheduleControl(directory: inbox, originals: originals)
    #expect(model.jobLedger.jobs.first?.enabled == false)
    var catalog = try controlRequest(); catalog.operation = "catalog"; try post(catalog)
    await model.processScheduleControl(directory: inbox, originals: originals)
    let listed = try JSONDecoder().decode(ScheduleControlReply.self, from: Data(contentsOf: inbox.appendingPathComponent(catalog.id.uuidString + ".response.json")))
    #expect(listed.catalog?.projects.first?.id == project.id && listed.catalog?.sources.count == 1)
    #expect(try await store.load().jobs == model.jobLedger.jobs)
    await model.stopScheduler()
}

@Test func scheduleControlChangesModelPairWithoutChangingScope() throws {
    var job = ManagedJob(); job.name = "Coordinator"; job.prompt = "existing"; job.projectID = UUID()
    job.model = "gpt-6-sol"; job.effort = "high"
    var request = try controlRequest(job: job)
    request.model = "gpt-6-astra"; request.effort = "medium"
    let updated = try ScheduleControl.updated(request, originalPaused: false)
    var expected = job; expected.model = "gpt-6-astra"; expected.effort = "medium"
    #expect(updated == expected)
    request.model = nil
    #expect(throws: (any Error).self) { try ScheduleControl.updated(request, originalPaused: false) }
    request.model = "gpt-6-astra"; request.effort = nil
    #expect(throws: (any Error).self) { try ScheduleControl.updated(request, originalPaused: false) }
    request.effort = "unknown"
    #expect(throws: (any Error).self) { try ScheduleControl.updated(request, originalPaused: false) }
    request.effort = "medium"; request.model = " "
    #expect(throws: (any Error).self) { try ScheduleControl.updated(request, originalPaused: false) }
}

@Test @MainActor func scheduleControlModelPairTransportAndReadOnlyRejection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var job = ManagedJob(); job.name = "Coordinator"; job.prompt = "existing"; job.projectID = UUID()
    for operation in ["update", "list", "catalog"] {
        var request = try controlRequest(job: operation == "update" ? job : nil)
        request.operation = operation; request.model = "gpt-6-astra"; request.effort = "medium"
        let path = root.appendingPathComponent(request.id.uuidString + ".request.json")
        try JSONEncoder().encode(request).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        var called = false
        try await ScheduleControl.drain(directory: root) { incoming in
            called = true
            return [try ScheduleControl.updated(incoming, originalPaused: false)]
        }
        let reply = try JSONDecoder().decode(ScheduleControlReply.self, from: Data(contentsOf: root.appendingPathComponent(request.id.uuidString + ".response.json")))
        #expect(called == (operation == "update"))
        #expect(reply.status == (operation == "update" ? "completed" : "rejected"))
        if operation == "update" { #expect(reply.jobs?.first?.model == "gpt-6-astra") }
    }
}
