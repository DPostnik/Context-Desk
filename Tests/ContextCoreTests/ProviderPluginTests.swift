import Foundation
import Testing
@testable import ContextCore
@testable import ContextDesk

private func writePlugin(in root: URL, id: String = "experiment", schema: Int = 1,
                         executable: String = "venv/bin/python", fault: String = "") throws -> URL {
    let directory = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
    let manifest: JSONValue = .object(["schemaVersion": .number(Double(schema)), "id": .string(id),
        "title": .string("Тестовый плагин"), "version": .string("1.0.0"), "executable": .string(executable),
        "arguments": .array([.string("server.py")])])
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("plugin.json"))
    let launcher = directory.appendingPathComponent("venv/bin/python")
    try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: launcher)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    let script = #"""
    import argparse, json, pathlib
    from http.server import BaseHTTPRequestHandler, HTTPServer
    p = argparse.ArgumentParser()
    for key in ['state', 'ready-file', 'instance', 'parent']: p.add_argument('--'+key)
    a = p.parse_args()
    manifest = json.loads(pathlib.Path('plugin.json').read_text())
    fault = 'FAULT'
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            data = json.dumps({'instance': 'wrong' if fault == 'identity' else a.instance,
                'protocolVersion': 99 if fault == 'protocol' else 1,
                'pluginID': 'wrong' if fault == 'id' else manifest['id'],
                'pluginVersion': '9.0.0' if fault == 'version' else manifest['version'],
                'detail': 'Работает', 'metrics': [{'id': 'requests', 'title': 'Запросов', 'value': 3}]}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data)
        def log_message(self, *args): pass
    server = HTTPServer(('127.0.0.1', 0), Handler)
    ready = pathlib.Path(a.ready_file)
    temporary = ready.with_suffix('.tmp')
    temporary.write_text(json.dumps({'protocolVersion': 1, 'pluginID': manifest['id'],
                                    'instance': a.instance, 'port': server.server_port}))
    temporary.replace(ready)
    server.serve_forever()
    """#.replacingOccurrences(of: "FAULT", with: fault)
    try Data(script.utf8).write(to: directory.appendingPathComponent("server.py"))
    return directory
}

@Test func providerPluginsAreDiscoveredWithoutExecutionAndRejectInvalidManifests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(PluginCatalog.scan(directory: root).plugins.isEmpty)
    let first = try writePlugin(in: root, id: "first")
    _ = try writePlugin(in: root, id: "second")
    _ = try writePlugin(in: root, id: "future", schema: 99)
    _ = try writePlugin(in: root, id: "escape", executable: "../outside")
    _ = try writePlugin(in: root, id: "direct")
    let catalog = PluginCatalog.scan(directory: root)
    #expect(catalog.plugins.map(\.id) == ["first", "second"])
    #expect(catalog.issues.count == 3)
    #expect(!FileManager.default.fileExists(atPath: first.appendingPathComponent("data").path))
    try FileManager.default.removeItem(at: first)
    #expect(PluginCatalog.scan(directory: root).plugins.map(\.id) == ["second"])
}

@Test func pluginProviderOverridesAreScopedAndCannotChangeProjectPermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = try ProviderPlugin(directory: writePlugin(in: root))
    let args = try plugin.providerArguments(endpoint: URL(string: "http://127.0.0.1:19876")!)
    #expect(args.contains("model_providers.contextdesk_experiment.name=\"OpenAI\""))
    #expect(args.contains("model_providers.contextdesk_experiment.request_max_retries=0"))
    #expect(args.contains("model_providers.contextdesk_experiment.stream_max_retries=0"))
    #expect(args.enumerated().filter { $0.offset % 2 == 1 }.allSatisfy { $0.element.hasPrefix("model_providers.contextdesk_experiment.") })
    for address in ["https://example.com:443", "http://localhost:1234", "http://user@127.0.0.1:1234", "http://127.0.0.1:1234/#fragment"] {
        #expect(throws: ClientFailure.self) { try plugin.providerArguments(endpoint: URL(string: address)!) }
    }
}

@Test func pluginRoutesPreserveLegacyAndUnknownProviderIDs() throws {
    for id in ["direct", "headroom", "future_plugin"] {
        let route = try JSONDecoder().decode(RequestRoute.self, from: Data("\"\(id)\"".utf8))
        #expect(route.rawValue == id)
        #expect(String(data: try JSONEncoder().encode(route), encoding: .utf8) == "\"\(id)\"")
    }
    let legacy = Data(#"{"id":"t","projectID":"00000000-0000-0000-0000-000000000001","title":"Old","model":"model","updated":0,"route":"headroom"}"#.utf8)
    let chat = try JSONDecoder().decode(Chat.self, from: legacy)
    #expect(chat.route?.providerID == "contextdesk_headroom")
    var state = SavedState(); state.chats = [chat]; state.defaultRoute = chat.route
    let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
    #expect(restored.defaultRoute == chat.route)
    #expect(restored.chats[0].route == chat.route)
}

@Test(arguments: ["", "identity", "protocol", "id", "version"])
func pluginRuntimeChecksProtocolAndIdentityAndStops(fault: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try writePlugin(in: root, fault: fault)
    let runtime = ProviderPluginRuntime(plugin: try ProviderPlugin(directory: directory), codexHome: root.appendingPathComponent("private-home"))
    if fault.isEmpty {
        let endpoint = try await runtime.start()
        #expect(endpoint.host == "127.0.0.1")
        #expect(try await runtime.status().metrics.first?.value == 3)
        #expect(try await runtime.start() == endpoint)
    } else {
        await #expect(throws: ClientFailure.self) { try await runtime.start() }
    }
    await runtime.stop()
    await #expect(throws: ClientFailure.self) { try await runtime.status() }
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("data").path)
    #expect(!files.contains { $0.hasPrefix("ready-") })
}

@Test @MainActor func missingPluginKeepsItsRouteAndCannotSendOrFallBack() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(pluginDirectory: root)
    #expect(model.defaultRoute == .direct)
    #expect(model.neededPluginIDs.isEmpty)
    _ = try writePlugin(in: root, id: "first")
    _ = try writePlugin(in: root, id: "second")
    model.refreshPlugins()
    #expect(model.plugins.count == 2)
    #expect(model.neededPluginIDs.isEmpty)
    let project = Project(path: root.path)
    model.state.projects = [project]; model.projectID = project.id
    var chat = Chat(id: "external", projectID: project.id, title: "External", model: "")
    chat.route = RequestRoute(rawValue: "first")
    model.state.chats = [chat]; model.chatID = chat.id
    model.connected = true; model.authenticated = true; model.draft = "Hello"
    try FileManager.default.removeItem(at: root.appendingPathComponent("first"))
    model.refreshPlugins()
    #expect(model.currentRoute.rawValue == "first")
    #expect(model.neededPluginIDs == ["first"])
    #expect(model.availableRoutes.contains(model.currentRoute))
    #expect(!model.canSend)
    #expect(model.routeTitle(model.currentRoute).contains("не установлен"))
    #expect(model.plugins.map(\.id) == ["second"])
}

@Test func twoProviderProcessesHaveIndependentLifetimes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = ProviderPluginRuntime(plugin: try ProviderPlugin(directory: writePlugin(in: root, id: "first")), codexHome: root.appendingPathComponent("home"))
    let second = ProviderPluginRuntime(plugin: try ProviderPlugin(directory: writePlugin(in: root, id: "second")), codexHome: root.appendingPathComponent("home"))
    do {
        let firstURL = try await first.start()
        let secondURL = try await second.start()
        #expect(firstURL.port != secondURL.port)
        #expect(try await first.status().pluginID == "first")
        #expect(try await second.status().pluginID == "second")
        await first.stop()
        #expect(try await second.status().pluginID == "second")
        await second.stop()
    } catch {
        await first.stop(); await second.stop()
        throw error
    }
}
