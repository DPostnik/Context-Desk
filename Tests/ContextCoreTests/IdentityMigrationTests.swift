import Foundation
import Testing
import CSQLite
import AgentContract
@testable import ContextCore
@testable import ContextDesk

private func identityDB(_ file: URL, _ body: (OpaquePointer) throws -> Void) throws {
    var handle: OpaquePointer?
    #expect(sqlite3_open(file.path, &handle) == SQLITE_OK)
    let db = try #require(handle)
    defer { sqlite3_close(db) }
    try body(db)
}
private func rawPut(_ db: OpaquePointer, _ key: String, _ value: Data) throws {
    #expect(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK)
    var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
    #expect(sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state VALUES (?,?)", -1, &statement, nil) == SQLITE_OK)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
    #expect(sqlite3_step(statement) == SQLITE_DONE)
}
private func rawRead(_ db: OpaquePointer, _ key: String) throws -> Data {
    var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
    #expect(sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK)
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    let pointer = try #require(sqlite3_column_blob(statement, 0))
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
}
private func legacyState() -> SavedState {
    var state = SavedState(); state.identityVersion = nil; state.defaultConnection = nil
    let project = Project(path: "/fixture")
    state.projects = [project]
    var chat = Chat(id: "legacy", projectID: project.id, title: "История", model: "old-model")
    chat.nativeSession = nil; chat.archived = true
    chat.unreadCompletionID = "turn:legacy:turn-1"
    state.chats = [chat]
    state.queuedMessages = [QueuedMessage(id: "q", threadID: "legacy", projectID: project.id, text: "Do not replay", model: "old-model", effort: "low")]
    state.model = "old-model"
    return state
}

@Test func identityMigrationPreservesEveryLegacyAssociationWithoutRekeying() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("metadata.sqlite"), legacy = legacyState()
    let snapshot = UsageSnapshot(event: .object([:]), date: Date(timeIntervalSince1970: 42))
    let timing = ResponseTiming(startedAt: nil, completedAt: Date(timeIntervalSince1970: 42))
    let summary = ArchiveSummaryRecord(threadID: "legacy", projectID: legacy.projects[0].id)
    let run = JobRun(jobID: UUID(), engine: .codex, name: "Old run", started: Date(), status: .uncertain, threadID: "legacy")
    var ledger = JobLedger(); ledger.runs = [run]
    let jobFile = folder.appendingPathComponent("jobs.json")
    let jobs = try JSONEncoder().encode(ledger); try jobs.write(to: jobFile)
    try identityDB(file) { db in
        try rawPut(db, "app", JSONEncoder().encode(legacy))
        try rawPut(db, "usage:legacy", JSONEncoder().encode(snapshot))
        try rawPut(db, "timing:legacy", JSONEncoder().encode(["turn-1": timing]))
        try rawPut(db, "archiveSummary:legacy", JSONEncoder().encode(summary))
    }
    let store = AppStore(file: file)
    let migrated = try await store.load()
    #expect(migrated.identityVersion == 2)
    #expect(migrated.chats[0].id == "legacy")
    #expect(migrated.chats[0].nativeSession == AgentSessionReference(connection: .originalCodex, nativeID: "legacy"))
    #expect(migrated.defaultConnection == .originalCodex)
    #expect(migrated.queuedMessages == legacy.queuedMessages)
    #expect(migrated.chats[0].unreadCompletionID == legacy.chats[0].unreadCompletionID)
    #expect(try await store.loadUsage()["legacy"] == snapshot)
    #expect(try await store.loadTimings(threadID: "legacy")["turn-1"] == timing)
    #expect(try await store.loadArchiveSummaries()["legacy"]?.status == .stale)
    #expect(try Data(contentsOf: jobFile) == jobs)
    let jobsStore = JobStore(file: jobFile)
    let restored = try await jobsStore.load()
    #expect(restored.runs[0].conversationID == migrated.chats[0].conversationID)
    #expect(restored.runs[0].status == .uncertain)
    await jobsStore.release()
    #expect(try await store.load().chats == migrated.chats)
}

@Test func identityMigrationRollsBackSummaryAndStateOnInterruptedCommit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("metadata.sqlite"), state = legacyState()
    let appBytes = try JSONEncoder().encode(state)
    let summaryBytes = try JSONEncoder().encode(ArchiveSummaryRecord(threadID: "legacy", projectID: state.projects[0].id))
    try identityDB(file) { db in
        try rawPut(db, "app", appBytes); try rawPut(db, "archiveSummary:legacy", summaryBytes)
        #expect(sqlite3_exec(db, "CREATE TRIGGER fail_migration BEFORE UPDATE ON state WHEN NEW.key='app' BEGIN SELECT RAISE(ABORT, 'fixture interruption'); END", nil, nil, nil) == SQLITE_OK)
    }
    await #expect(throws: (any Error).self) { try await AppStore(file: file).load() }
    try identityDB(file) { db in
        let restoredApp = try rawRead(db, "app")
        let restoredSummary = try rawRead(db, "archiveSummary:legacy")
        #expect(restoredApp == appBytes)
        #expect(restoredSummary == summaryBytes)
        #expect(sqlite3_exec(db, "DROP TRIGGER fail_migration", nil, nil, nil) == SQLITE_OK)
    }
    #expect(try await AppStore(file: file).load().identityVersion == 2)
}

@Test func persistedConnectionsWithCollidingNativeIDsRemainDistinct() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("metadata.sqlite"))
    var state = SavedState(); let project = Project(path: "/fixture"); state.projects = [project]
    let foreign = AgentConnectionID(agent: AgentID(rawValue: "uninstalled"), id: UUID())
    let a = Chat(session: AgentSessionReference(connection: .originalCodex, nativeID: "same"), projectID: project.id, title: "A", model: "model")
    let b = Chat(session: AgentSessionReference(connection: foreign, nativeID: "same"), projectID: project.id, title: "B", model: "foreign")
    state.chats = [a, b]; try await store.save(state)
    let restored = try await store.load()
    #expect(restored.chats == [a, b])
    #expect(a.id != b.id && a.id != "same")
    #expect(ConversationIdentity.appID(for: "same", in: restored) == a.id)
    #expect(ConversationIdentity.appID(for: "same", in: restored, connection: foreign) == b.id)
    #expect(throws: ClientFailure.self) { try ConversationIdentity.nativeID(for: b.id, in: restored) }
    let usageA = UsageSnapshot(event: .object([:]), date: Date(timeIntervalSince1970: 1))
    let usageB = UsageSnapshot(event: .object([:]), date: Date(timeIntervalSince1970: 2))
    try await store.saveUsage(threadID: a.id, snapshot: usageA)
    try await store.saveUsage(threadID: b.id, snapshot: usageB)
    #expect(try await store.loadUsage() == [a.id: usageA, b.id: usageB])
    var invalid = restored
    invalid.chats[0].nativeSession = nil
    await #expect(throws: ClientFailure.self) { try await store.save(invalid) }
    invalid.chats[0].nativeSession = AgentSessionReference(connection: .originalCodex, nativeID: "")
    #expect(throws: ClientFailure.self) { try ConversationIdentity.nativeID(for: a.id, in: invalid) }
    invalid = restored
    invalid.chats[1].nativeSession = a.nativeSession
    await #expect(throws: ClientFailure.self) { try await store.save(invalid) }
    state.chats[0].nativeSession = AgentSessionReference(connection: .originalCodex, nativeID: "replacement")
    await #expect(throws: ClientFailure.self) { try await store.save(state) }
    #expect(try await store.load().chats == [a, b])
}

@Test func transcriptSchemaChecksSourceCompletenessRevisionAndDeletion() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("metadata.sqlite"))
    var state = SavedState(); let chat = Chat(id: "legacy", projectID: UUID(), title: "Title", model: "model")
    state.chats = [chat]; try await store.save(state)
    let snapshot = AgentTranscriptSnapshot(conversation: chat.conversationID, source: try #require(chat.nativeSession),
        revision: "r2", capturedAt: Date(), completeness: .partial,
        items: [AgentTranscriptItem(id: "i", kind: .assistant, text: "Historical evidence · История")])
    try await store.saveTranscript(snapshot)
    #expect(try await store.loadTranscript(conversationID: chat.id) == snapshot)
    let wrong = AgentTranscriptSnapshot(conversation: chat.conversationID,
        source: AgentSessionReference(connection: .originalCodex, nativeID: "foreign"),
        revision: "r3", capturedAt: Date(), completeness: .complete, items: [])
    await #expect(throws: ClientFailure.self) { try await store.saveTranscript(wrong) }
    state.chats = []
    try await store.saveDeletingChat(state, threadID: chat.id)
    #expect(try await store.loadTranscript(conversationID: chat.id) == nil)
}

@Test @MainActor func unavailableConnectionsNeverSendOrGenerateAndKeepQueuesPaused() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = DeskModel(store: AppStore(file: folder.appendingPathComponent("metadata.sqlite")), summaryResources: nil)
    let project = Project(path: "/fixture")
    let foreign = AgentConnectionID(agent: .codex, id: UUID())
    let chat = Chat(session: AgentSessionReference(connection: foreign, nativeID: "same"), projectID: project.id, title: "Saved", model: "foreign-model")
    model.state.projects = [project]; model.state.chats = [chat]
    model.state.queuedMessages = [QueuedMessage(id: "q", threadID: chat.id, projectID: project.id, text: "Keep me", model: "foreign-model", effort: "")]
    model.connected = true; model.authenticated = true
    await model.openChat(chat)
    model.draft = "Do not route this to the original account"
    #expect(!model.canSend && model.queuePaused)
    #expect(model.error == ConversationIdentity.unavailable.message)
    await model.send()
    await model.sendQueuedMessageNow("q")
    model.resumeQueue()
    #expect(model.queuePaused)
    model.generateChatTitle(chat.id, firstMessage: "private", model: "foreign-model", route: .direct)
    #expect(model.titleTasks.isEmpty && model.queuedMessages.count == 1)
    #expect(model.state.chats == [chat])
}

@Test @MainActor func nativeEventsResolveOnlyWithinOriginalConnectionAndPersistAppKeys() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = AppStore(file: folder.appendingPathComponent("metadata.sqlite"))
    let model = DeskModel(store: store, summaryResources: nil)
    let project = Project(path: "/fixture")
    let original = Chat(session: AgentSessionReference(connection: .originalCodex, nativeID: "same"), projectID: project.id, title: "Original", model: "model")
    let foreign = Chat(session: AgentSessionReference(connection: AgentConnectionID(agent: .claudeCode, id: UUID()), nativeID: "same"), projectID: project.id, title: "Foreign", model: "foreign")
    model.state.projects = [project]; model.state.chats = [original, foreign]
    try await store.save(model.state)
    model.chatID = original.id
    await model.receive(.object(["method": .string("item/completed"), "params": .object([
        "threadId": .string("same"), "turnId": .string("v"),
        "item": .object(["id": .string("i"), "type": .string("agentMessage"), "text": .string("Scoped reply")])])]))
    #expect(model.items.map(\.text) == ["Scoped reply"])
    await model.receive(.object(["method": .string("thread/tokenUsage/updated"), "params": .object([
        "threadId": .string("same"), "tokenUsage": .object(["last": .object(["totalTokens": .number(17)])])])]))
    #expect(model.usage[original.id]?.last == 17)
    #expect(model.usage[foreign.id] == nil)
    #expect(try await store.loadUsage()[original.id]?.last == 17)
    #expect(try await store.loadUsage()["same"] == nil)
    model.chatID = foreign.id; model.items = []
    await model.receive(.object(["method": .string("item/completed"), "params": .object([
        "threadId": .string("same"), "item": .object(["id": .string("i"), "type": .string("agentMessage"), "text": .string("Must stay out")])])]))
    #expect(model.items.isEmpty)
    await model.receive(.object(["method": .string("thread/tokenUsage/updated"), "params": .object(["threadId": .string("unknown")])]))
    #expect(model.usage.count == 1)
}

@Test func unsupportedIdentityAndSnapshotVersionsFailClosed() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("metadata.sqlite")
    var state = legacyState(); state.identityVersion = 99
    let original = try JSONEncoder().encode(state)
    try identityDB(file) { try rawPut($0, "app", original) }
    await #expect(throws: ClientFailure.self) { try await AppStore(file: file).load() }
    try identityDB(file) { db in
        let after = try rawRead(db, "app"); #expect(after == original)
        var current = SavedState()
        current.chats = [Chat(id: "legacy", projectID: UUID(), title: "Saved", model: "model")]
        try rawPut(db, "app", JSONEncoder().encode(current))
        let snapshot = AgentTranscriptSnapshot(conversation: ConversationID("legacy"),
            source: try #require(current.chats[0].nativeSession), revision: "r1", capturedAt: Date(), completeness: .partial, items: [])
        var raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot)).object
        raw["version"] = .number(99)
        try rawPut(db, "transcript:legacy", JSONEncoder().encode(JSONValue.object(raw)))
    }
    await #expect(throws: ClientFailure.self) { try await AppStore(file: file).loadTranscript(conversationID: "legacy") }
}
