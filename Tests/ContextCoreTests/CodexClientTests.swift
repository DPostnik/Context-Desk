import Foundation
import Testing
import AgentContract
import ContextCore
@_spi(NativeProtocol) import CodexAdapter

private func commandFixture() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!/usr/bin/python3
    import json, os, pathlib, sys
    root = pathlib.Path(os.environ['CODEX_HOME'])
    calls = []
    for line in sys.stdin:
        m = json.loads(line)
        if 'id' not in m: continue
        method, p = m.get('method'), m.get('params', {})
        result = {}
        if method == 'test/calls': result = calls
        else:
            calls.append({'method': method, 'params': p})
            if method == 'initialize': result = {'userAgent': 'fixture'}
            if method == 'thread/start': result = {'thread': {'id': 'native-session'}}
            if method == 'turn/start': result = {'turn': {'id': 'native-turn'}}
            if method == 'account/read': result = {'account': {'planType': 'fixture-plan'}}
            if method == 'account/login/start':
                result = {'authUrl': (root/'url').read_text() if (root/'url').exists() else 'https://auth.openai.com/login'}
            if method == 'model/list': result = {'data': [
                {'model': 'fixture-model', 'displayName': 'Fixture', 'isDefault': True,
                 'defaultReasoningEffort': 'low', 'supportedReasoningEfforts': [{'reasoningEffort': 'low'}]},
                {'displayName': 'Missing identifier'}]}
            if method == 'thread/read':
                result = {'thread': {'id': p['threadId'], 'turns': []}}
                if (root/'history').exists(): result = json.loads((root/'history').read_text())
        print(json.dumps({'id': m['id'], 'result': result}), flush=True)
    """#.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (root, executable)
}

@Test func typedCommandsPreserveNativeRoutingAndPermissionPayloads() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection(), client: CodexClient
    client = CodexClient(transport: wire)
    try await client.start(executable: executable, home: root)
    let session = try await client.createSession(projectPath: "/workspace", access: .standard,
                                                 model: "fixture-model", route: .direct)
    #expect(session == AgentSessionReference(connection: .originalCodex, nativeID: "native-session"))
    try await client.resume(session, projectPath: "/workspace", access: .standard, route: .direct)
    #expect(try await client.send("literal $() and `data`", to: session, projectPath: "/workspace", access: .standard,
                                 model: "fixture-model", effort: "low") == "native-turn")
    _ = try await client.send("full", to: session, projectPath: "/workspace", access: .fullAccess, model: "", effort: "")
    try await client.interrupt(session, turn: "native-turn")
    try await client.rename(session, title: "Проверка / Check")
    try await client.setArchived(true, session: session)
    try await client.setArchived(false, session: session)
    try await client.delete(session)
    let calls = try await wire.request("test/calls").array
    let starts = calls.filter { $0["method"].string == "turn/start" }
    #expect(starts.count == 2)
    #expect(starts[0]["params"]["threadId"].string == session.nativeID)
    #expect(starts[0]["params"]["input"].array.first?["text"].string == "literal $() and `data`")
    #expect(starts[0]["params"]["sandboxPolicy"]["networkAccess"].bool == false)
    #expect(starts[0]["params"]["sandboxPolicy"]["writableRoots"] == .array([.string("/workspace")]))
    #expect(starts[0]["params"]["approvalPolicy"].string == "on-request")
    #expect(starts[1]["params"]["sandboxPolicy"]["type"].string == "dangerFullAccess")
    #expect(starts[1]["params"]["approvalPolicy"].string == "never")
    #expect(starts[1]["params"]["model"] == .null && starts[1]["params"]["effort"] == .null)
    #expect(calls.first { $0["method"].string == "thread/start" }?["params"]["modelProvider"].string == "openai")
    for method in ["thread/start", "thread/resume"] {
        #expect(calls.first { $0["method"].string == method }?["params"]["developerInstructions"].string == AgentAutonomy.instructions())
    }
    #expect(calls.first { $0["method"].string == "turn/interrupt" }?["params"]["turnId"].string == "native-turn")
    #expect(calls.suffix(3).compactMap { $0["method"].string } == ["thread/archive", "thread/unarchive", "thread/delete"])
    await client.stop()
}

@Test func typedCommandsRejectForeignSessionsBeforeAnyDispatch() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection(), client: CodexClient
    client = CodexClient(transport: wire)
    try await client.start(executable: executable, home: root)
    for session in [AgentSessionReference(connection: AgentConnectionID(agent: .codex, id: UUID()), nativeID: "same"),
                    AgentSessionReference(connection: AgentConnectionID(agent: .claudeCode, id: UUID()), nativeID: "same"),
                    AgentSessionReference(connection: .originalCodex, nativeID: "")] {
        await #expect(throws: ClientFailure.self) { try await client.resume(session, projectPath: "/tmp", access: .standard, route: .direct) }
        await #expect(throws: ClientFailure.self) { try await client.send("x", to: session, projectPath: "/tmp", access: .standard, model: "", effort: "") }
        await #expect(throws: ClientFailure.self) { try await client.interrupt(session, turn: "t") }
        await #expect(throws: ClientFailure.self) { try await client.rename(session, title: "x") }
        await #expect(throws: ClientFailure.self) { try await client.setArchived(true, session: session) }
        await #expect(throws: ClientFailure.self) { try await client.delete(session) }
        await #expect(throws: ClientFailure.self) { try await client.history(session) }
        await #expect(throws: ClientFailure.self) { try await client.summarySource(session) }
    }
    #expect(try await wire.request("test/calls").array.compactMap { $0["method"].string } == ["initialize"])
    await client.stop()
}

@Test func typedDiscoveryAndHistoryRejectMalformedIdentityWithoutFallback() async throws {
    let (root, executable) = try commandFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = CodexClient()
    try await client.start(executable: executable, home: root)
    let account = try await client.account()
    #expect(account.authenticated && account.plan == "fixture-plan")
    let models = try await client.models()
    #expect(models == [CodexModel(id: "fixture-model", displayName: "Fixture", isDefault: true, defaultEffort: "low", efforts: ["low"])])
    #expect(try await client.signInURL().host == "auth.openai.com")
    for url in ["https://auth.openai.com.evil.test/login", "http://auth.openai.com/login", "file:///tmp/login"] {
        try Data(url.utf8).write(to: root.appendingPathComponent("url"))
        await #expect(throws: ClientFailure.self) { try await client.signInURL() }
    }
    let session = AgentSessionReference(connection: .originalCodex, nativeID: "expected")
    #expect(try await client.history(session).isEmpty)
    for raw in [#"{"thread":{"id":"other","turns":[]}}"#,
                #"{"thread":{"id":"expected"}}"#] {
        try Data(raw.utf8).write(to: root.appendingPathComponent("history"))
        await #expect(throws: ClientFailure.self) { try await client.history(session) }
        await #expect(throws: ClientFailure.self) { try await client.summarySource(session) }
    }
    await client.stop()
}
