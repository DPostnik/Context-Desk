import Foundation
import HeadroomIntegration
@testable import ContextDesk
import Testing
@testable import ContextCore

@Test func headroomProviderIsLocalAndKeepsCompactionIdentity() throws {
    let args = try RequestRoute.providerArguments(endpoint: URL(string: "http://127.0.0.1:19876")!)
    #expect(args.contains("model_providers.contextdesk_headroom.name=\"OpenAI\""))
    #expect(args.contains("model_providers.contextdesk_headroom.requires_openai_auth=true"))
    #expect(args.contains("model_providers.contextdesk_headroom.request_max_retries=0"))
    #expect(args.contains("model_providers.contextdesk_headroom.stream_max_retries=0"))
    #expect(args.contains("model_providers.contextdesk_headroom.base_url=\"http://127.0.0.1:19876/v1\""))
    #expect(!args.contains { $0.hasPrefix("model_provider=") })
    #expect(throws: ClientFailure.self) {
        try RequestRoute.providerArguments(endpoint: URL(string: "https://example.com:443")!)
    }
}

@Test func chatRoutesSurviveRestartAndLegacyChatsStayDirect() throws {
    let legacy = Data(#"{"id":"t","projectID":"00000000-0000-0000-0000-000000000001","title":"Old","model":"model","updated":0}"#.utf8)
    var chat = try JSONDecoder().decode(Chat.self, from: legacy)
    #expect((chat.route ?? .direct) == .direct)
    chat.route = .headroom
    var state = SavedState(); state.chats = [chat]; state.defaultRoute = .headroom
    let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
    #expect(restored.chats[0].route == .headroom)
    #expect(restored.defaultRoute == .headroom)
}

@Test(arguments: [false, true]) func headroomOwnsItsProcessAndChecksInstance(wrongIdentity: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("venv/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let launcher = bin.appendingPathComponent("python")
    try Data("#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".utf8).write(to: launcher)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    let script = #"""
    import argparse, json, pathlib
    from http.server import BaseHTTPRequestHandler, HTTPServer
    p = argparse.ArgumentParser()
    for key in ['state', 'ready-file', 'instance', 'parent']: p.add_argument('--'+key)
    a = p.parse_args()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            data = json.dumps({'instance': INSTANCE, 'version': '0.38.0', 'profile': 'cache-lossless',
                               'requests': 3, 'failed': 0, 'tokensSaved': 42}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data)
        def log_message(self, *args): pass
    server = HTTPServer(('127.0.0.1', 0), Handler)
    pathlib.Path(a.ready_file).write_text(json.dumps({'instance': a.instance, 'port': server.server_port}))
    server.serve_forever()
    """#.replacingOccurrences(of: "INSTANCE", with: wrongIdentity ? "'wrong'" : "a.instance")
    try Data(script.utf8).write(to: root.appendingPathComponent("headroom_server.py"))
    let runtime = HeadroomRuntime(root: root)
    if wrongIdentity {
        do {
            _ = try await runtime.start()
            Issue.record("Accepted a different proxy instance")
        } catch { #expect(error.localizedDescription.contains("несовместимого экземпляра")) }
    } else {
        let endpoint = try await runtime.start()
        #expect(endpoint.host == "127.0.0.1")
        let status = try await runtime.status()
        #expect(status.requests == 3)
        #expect(status.tokensSaved == 42)
        #expect(try await runtime.start() == endpoint)
    }
    await runtime.stop()
    await #expect(throws: ClientFailure.self) { try await runtime.status() }
}

@Test func headroomMissingRuntimeDoesNotConnectElsewhere() async {
    let runtime = HeadroomRuntime(root: URL(fileURLWithPath: "/tmp/contextdesk-missing-\(UUID().uuidString)"))
    await #expect(throws: ClientFailure.self) { try await runtime.start() }
}

@Test @MainActor func standaloneAppDefaultsToDirectAndHeadroomRequiresSelection() {
    let model = DeskModel()
    #expect(model.defaultRoute == .direct)
    #expect(!model.needsHeadroom)
    model.state.defaultRoute = .headroom
    #expect(model.defaultRoute == .headroom)
    #expect(model.needsHeadroom)
    model.state.defaultRoute = .direct
    var chat = Chat(id: "external", projectID: UUID(), title: "External", model: "")
    chat.route = .headroom
    model.state.chats = [chat]
    #expect(model.defaultRoute == .direct)
    #expect(model.needsHeadroom)
}
