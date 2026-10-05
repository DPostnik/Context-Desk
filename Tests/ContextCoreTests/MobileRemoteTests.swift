@_spi(NativeProtocol) import CodexAdapter
import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test @MainActor func remoteHostReusesAuthenticationAcrossDisableAndReenable() async throws {
    var constructions = 0
    let host = MobileRemoteHost(makeClient: { url, key in
        constructions += 1
        return try RemoteAPI(url: url, key: key,
                             storage: RemoteSessionStorage(read: { _ in nil }, write: { _, _ in }))
    })
    host.url = "https://first.invalid"; host.key = "sb_publishable_fixture"
    let first = try host.connectionClient()
    await host.disable()
    #expect(try host.connectionClient() === first)
    #expect(constructions == 1)
    #expect(!host.enabled)

    host.url = "https://second.invalid"
    let second = try host.connectionClient()
    #expect(second !== first)
    host.key = "sb_publishable_other"
    let third = try host.connectionClient()
    #expect(third !== second)
    #expect(constructions == 3)

    host.url = "http://invalid.invalid"
    #expect(throws: RemoteFailure.self) { try host.connectionClient() }
    host.url = "https://second.invalid"
    #expect(try host.connectionClient() !== third)
    #expect(constructions == 5)
}

@Test @MainActor func remoteHostLeavesInstallerHandoffUntilSettingsAreOpened() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let setup = ["url": "https://example.supabase.co", "key": "sb_publishable_fixture", "email": "owner@example.invalid", "password": "fixture-only"]
    try JSONEncoder().encode(setup).write(to: file)
    let host = MobileRemoteHost(setupFile: file)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(host.password.isEmpty)
    host.prepareConnection()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(host.url == setup["url"])
    #expect(host.email == setup["email"])
    #expect(host.password == setup["password"])
    #expect(!host.enabled)
    host.prepareConnection()
    #expect(host.password == setup["password"])
}

@Test func remoteInstallerHandoffConsumesOnceAndRejectsPrivilegedKeys() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    var setup = ["url": "https://example.supabase.co", "key": "sb_secret_forbidden", "email": "owner@example.invalid", "password": "fixture-only"]
    try JSONEncoder().encode(setup).write(to: file)
    #expect(throws: RemoteFailure.self) { try RemoteSetup.consume(file) }
    #expect(FileManager.default.fileExists(atPath: file.path))
    setup["key"] = "sb_publishable_fixture"
    try JSONEncoder().encode(setup).write(to: file)
    #expect(try RemoteSetup.consume(file)?.email == setup["email"])
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try RemoteSetup.consume(file) == nil)
}

@Test func remoteJournalSurvivesRestartAndFailsClosedOnCorruption() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("journal.json")
    let command = RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString,
        project: UUID().uuidString, chat: "chat", kind: "send", text: "Привет / Hello")
    try await RemoteJournal(file: file).begin(command)
    await #expect(throws: RemoteFailure.self) { try await RemoteJournal(file: file).begin(command) }
    try Data("broken".utf8).write(to: file)
    let fresh = RemoteCommand(owner: command.owner, device: command.device, project: command.project,
        chat: "chat", kind: "send", text: "Second")
    await #expect(throws: (any Error).self) { try await RemoteJournal(file: file).begin(fresh) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
}
@Test func remoteCommandsRejectUnknownKindsEmptyMessagesAndStaleShape() throws {
    func command(_ kind: String, text: String = "") -> RemoteCommand {
        RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: UUID().uuidString, chat: "chat", kind: kind, text: text)
    }
    #expect(throws: RemoteFailure.self) { try command("shell", text: "echo bad").validate() }
    #expect(throws: RemoteFailure.self) { try command("send", text: " \n").validate() }
    #expect(throws: RemoteFailure.self) { try command("allow").validate() }
    #expect(throws: RemoteFailure.self) { try command("send", text: String(repeating: "я", count: 16_001)).validate() }
    try command("stop").validate()
    try command("send", text: "Русский / English").validate()
}
@Test func remoteConfigurationRejectsSecretsAndUnsafeEndpoints() {
    #expect(throws: RemoteFailure.self) { try RemoteAPI(url: "http://project.supabase.co", key: "sb_publishable_test") }
    #expect(throws: RemoteFailure.self) { try RemoteAPI(url: "https://user:password@project.supabase.co", key: "sb_publishable_test") }
    #expect(throws: RemoteFailure.self) { try RemoteAPI(url: "https://project.supabase.co", key: "sb_secret_private") }
    let payload = Data(#"{"role":"service_role"}"#.utf8).base64EncodedString()
    #expect(throws: RemoteFailure.self) { try RemoteAPI(url: "https://project.supabase.co", key: "ey.\(payload).signature") }
}
@Test @MainActor func remoteSnapshotOnlyIncludesSelectedProjectsAndSafePresentation() async throws {
    let model = DeskModel()
    let selected = Project(path: "/tmp/selected")
    let excluded = Project(path: "/tmp/private")
    model.state.projects = [selected, excluded]
    model.state.chats = [Chat(id: "one", projectID: selected.id, title: "Included", model: ""),
                         Chat(id: "two", projectID: excluded.id, title: "Excluded", model: "")]
    model.chatID = "one"
    model.items = [TranscriptItem(id: "message", kind: "assistant", text: "Привет / Hello"),
                   TranscriptItem(id: "tool", kind: "tool", text: "private tool output")]
    let result = await model.remoteSnapshot(projects: [selected.id.uuidString])
    #expect(result.projects.map(\.name) == ["selected"])
    #expect(result.chats.map(\.id) == ["one"])
    #expect(result.chats.first?.messages.map(\.text) == ["Привет / Hello"])
    let serialized = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(!serialized.contains("/tmp")); #expect(!serialized.contains("private"))
    let command = RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: excluded.id.uuidString, chat: "one", kind: "stop")
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(command) }
}

@Test(arguments: [false, true]) @MainActor func remoteSendPreservesDesktopDraftAndStopCannotTargetANewerTurn(visible: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("engine.py")
    try Data(#"""
    #!/usr/bin/python3
    import sys, json
    for line in sys.stdin:
        request = json.loads(line)
        if 'id' not in request: continue
        result = {'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if request.get('method') == 'turn/start': result = {'turn': {'id':'remote-turn'}}
        print(json.dumps({'id':request['id'], 'result':result}), flush=True)
    """#.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let connection = CodexConnection()
    try await connection.start(executable: executable, home: folder)
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: connection)), store: AppStore(file: folder.appendingPathComponent("state.sqlite")), summaryExecutable: executable, summaryHome: folder)
    let project = Project(path: folder.path)
    model.state.projects = [project]
    model.state.chats = [Chat(id: "remote-chat", projectID: project.id, title: "Remote", model: "")]
    model.projectID = project.id; model.draft = "Desktop draft"; model.connected = true; model.authenticated = true
    model.chatID = visible ? "remote-chat" : nil
    let send = RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: project.id.uuidString, chat: "remote-chat", kind: "send", text: "From phone")
    #expect(try await model.executeRemote(send) == "submitted")
    #expect(model.chatID == (visible ? "remote-chat" : nil)); #expect(model.draft == "Desktop draft")
    if visible {
        #expect(model.items.filter { $0.kind == "user" }.count == 1)
        TranscriptItem.merge(TranscriptItem(id: "native-user-1", kind: "user", text: "From phone"), into: &model.items)
        #expect(model.items.filter { $0.kind == "user" }.map(\.id) == ["native-user-1"])
        TranscriptItem.merge(TranscriptItem(id: "native-user-1", kind: "user", text: "From phone"), into: &model.items)
        #expect(model.items.filter { $0.kind == "user" }.count == 1)
        TranscriptItem.merge(TranscriptItem(id: "native-user-2", kind: "user", text: "From phone"), into: &model.items)
        #expect(model.items.filter { $0.kind == "user" }.count == 2)
    }
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(send) }
    let stop = RemoteCommand(owner: send.owner, device: send.device, project: send.project, chat: send.chat, kind: "stop", turn: "older-turn")
    await #expect(throws: RemoteFailure.self) { try await model.executeRemote(stop) }
    let correct = RemoteCommand(owner: send.owner, device: send.device, project: send.project, chat: send.chat, kind: "stop", turn: "remote-turn")
    #expect(try await model.executeRemote(correct) == "stop_requested")
    await connection.stop()
}
