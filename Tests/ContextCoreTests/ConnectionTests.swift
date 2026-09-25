import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

/// Local protocol simulator: no authentication, network or model requests.
private func fixture() throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let executable = folder.appendingPathComponent("engine.py")
    let script = #"""
    #!/usr/bin/python3
    import json, os, sys
    def emit(value):
        data = (json.dumps(value) + "\n").encode()
        os.write(1, data[:7])
        os.write(1, data[7:])
    for line in sys.stdin:
        m = json.loads(line)
        method = m.get("method")
        if method == "initialize":
            emit({"id": m["id"], "result": {"userAgent": "fixture"}})
        elif method == "test/echo":
            emit({"id": m["id"], "result": m["params"]})
        elif method == "account/read":
            emit({"id": m["id"], "result": {"account": None}})
        elif method == "test/approval":
            emit({"method": "item/commandExecution/requestApproval", "id": 42, "params": {"threadId": "t", "turnId": "v"}})
            emit({"id": m["id"], "result": {}})
        elif method == "test/crash":
            sys.exit(3)
        elif method == "test/wait" or method == "turn/start" or method == "turn/steer":
            pass
        elif method == "test/error":
            emit({"id": m["id"], "error": {"code": -32602, "message": "Invalid fixture input"}})
        elif "id" in m and "result" in m:
            emit({"method": "test/answered", "params": m})
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (folder, executable)
}

@Test @MainActor func successfulResponseClearsStaleConnectionErrorOnly() async throws {
    let (folder, executable) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = CodexConnection()
    let model = DeskModel(connection: client, store: AppStore(file: folder.appendingPathComponent("state.sqlite")))
    await model.refreshAccount()
    #expect(model.error == "Codex не подключён")

    try await client.start(executable: executable, home: folder)
    await model.refreshAccount()
    #expect(model.error == nil)

    model.error = "Не удалось сохранить состояние"
    await model.refreshAccount()
    #expect(model.error == "Не удалось сохранить состояние")

    await client.stop()
    await model.refreshAccount()
    #expect(model.error == "Codex не подключён")
}

@Test func fragmentedRepliesAndExplicitApproval() async throws {
    let (folder, executable) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = CodexConnection()
    try await client.start(executable: executable, home: folder)
    let echo: JSONValue = .object(["message": .string("Привет\nUnicode ✅")])
    #expect(try await client.request("test/echo", params: echo) == echo)
    _ = try await client.request("test/approval")
    var events = client.events.makeAsyncIterator()
    let action = await events.next()
    #expect(action?["id"] == .number(42))
    try await client.answer(id: .number(42), result: .object(["decision": .string("decline")]))
    let answered = await events.next()
    #expect(answered?["params"]["result"]["decision"].string == "decline")
    do {
        _ = try await client.request("test/error")
        Issue.record("Expected protocol error")
    } catch { #expect(error.localizedDescription == "Invalid fixture input") }
    await client.stop()
}

@Test(arguments: ["turn/start", "turn/steer"]) func timeoutDoesNotRetryAndConnectionCanRestart(method: String) async throws {
    let (folder, executable) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = CodexConnection()
    try await client.start(executable: executable, home: folder)
    do {
        _ = try await client.request(method, timeout: 1)
        Issue.record("Expected timeout")
    } catch { #expect(error.localizedDescription.contains("не повторён")) }
    // Ambiguous turn/start closes the transport instead of permitting a second send.
    do {
        _ = try await client.request("test/echo")
        Issue.record("Timed-out turn left connection open")
    } catch { #expect(error.localizedDescription.contains("не подключён")) }
    try await client.start(executable: executable, home: folder)
    #expect(try await client.request("test/echo", params: .string("reconnected")) == .string("reconnected"))
    await client.stop()
}

@Test func processExitRejectsPendingCall() async throws {
    let (folder, executable) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = CodexConnection()
    try await client.start(executable: executable, home: folder)
    do {
        _ = try await client.request("test/crash", timeout: 3)
        Issue.record("Expected disconnect")
    } catch { #expect(error.localizedDescription.contains("закрыто")) }
    await client.stop()
}
