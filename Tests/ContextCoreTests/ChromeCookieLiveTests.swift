import Foundation
import Testing
@testable import ContextCore

/// Opt-in real-browser verification. All cookies, profiles and pages are fixtures.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CONTEXTDESK_COOKIE_SMOKE"] == "1"))
func chromeCookieLiveTransmissionPersistenceAndIsolation() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cookie-live-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let runtime = repository.appendingPathComponent("build/Context Desk.app/Contents/Resources/BrowserRuntime")
    #expect(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("chrome_host.py").path))
    let fixtureScript = #"""
import http.server, json, pathlib, sys, urllib.parse
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        if parsed.path == '/probe':
            visible = params.get('visible', [''])[0]
            (root / ('probe-' + params['run'][0] + '.json')).write_text(json.dumps({
                'sent': 'auth=fixture-secret' in self.headers.get('Cookie', ''),
                'httpOnly': 'auth=' not in visible,
                'visible': 'visible=fixture-visible' in visible}))
            body = b'ok'
        else:
            run = params.get('run', ['first'])[0]
            body = ("<script>fetch('/probe?run=" + run + "&visible='+encodeURIComponent(document.cookie))</script>").encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
"""#
    let server = Process(), output = Pipe(), serverExited = DispatchSemaphore(value: 0)
    server.terminationHandler = { _ in serverExited.signal() }
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", "-c", fixtureScript, root.path]
    server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    defer {
        if server.isRunning { server.terminate() }
        let exited = { serverExited.wait(timeout: .now() + 5) == .success }()
        #expect(exited)
    }
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]), line.count < 8 { line.append(byte) }
    let port = try #require(Int(String(decoding: line, as: UTF8.self)))
    let a = root.appendingPathComponent("environments/" + UUID().uuidString)
    let b = root.appendingPathComponent("environments/" + UUID().uuidString)
    defer { _ = try? control(a, close: true); _ = try? control(b, close: true) }
    func control(_ environment: URL, close: Bool) throws -> JSONValue {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", runtime.appendingPathComponent("chrome_host.py").path, "--root", environment.path,
                             close ? "--close" : "--prepare-cookie-import"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func connection(_ environment: URL) throws -> CookieCDP {
        let owner = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: environment.appendingPathComponent("testing-chrome-owner.json")))
        let port = try #require(owner["port"].int), path = try #require(owner["browserPath"].string)
        return try CookieCDP(endpoint: #require(URL(string: "ws://127.0.0.1:\(port)\(path)")))
    }
    func visit(_ cdp: CookieCDP, run: String) async throws -> JSONValue {
        _ = try await cdp.call("Target.createTarget", parameters: .object(["url": .string("http://127.0.0.1:\(port)/?run=\(run)")]))
        let file = root.appendingPathComponent("probe-" + run + ".json")
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(JSONValue.self, from: data) { return result }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClientFailure("Loopback cookie probe timed out")
    }
    var read = ChromeCookieRead()
    read.cookies = [
        .init(host: "127.0.0.1", name: "auth", value: "fixture-secret", path: "/", secure: false, httpOnly: true, sameSite: "Lax", expires: Date().timeIntervalSince1970 + 3600),
        .init(host: "127.0.0.1", name: "visible", value: "fixture-visible", path: "/", secure: false, httpOnly: false, sameSite: nil, expires: nil)
    ]
    let imported = try await ChromeCookieImporter.transfer(read, environment: a, runtime: runtime, maxBrowsers: 2, browserRoot: root)
    #expect(imported.verified == 2 && imported.unverified == 0)
    let first = try connection(a)
    // Agent path uses the already open destination under the executor's fence.
    let fence = a.appendingPathComponent("executor-in-flight.json")
    try Data(#"{"tool":"browser_import_session","state":"outcome_unknown"}"#.utf8).write(to: fence)
    let agentImport = try await ChromeCookieImporter.writeAndVerify(read, fence: fence, executorFence: true) { method, parameters in
        try await first.call(method, parameters: parameters)
    }
    #expect(agentImport.verified == 2 && agentImport.unverified == 0)
    #expect(!FileManager.default.fileExists(atPath: fence.path))
    let firstProbe = try await visit(first, run: "first")
    #expect(firstProbe["sent"] == .bool(true) && firstProbe["httpOnly"] == .bool(true) && firstProbe["visible"] == .bool(true))
    first.close()
    // Import may not silently overwrite an open destination.
    do {
        _ = try await ChromeCookieImporter.transfer(read, environment: a, runtime: runtime, maxBrowsers: 2, browserRoot: root)
        Issue.record("An open destination must reject import")
    } catch { #expect(error is ChromeCookieError) }
    #expect(try control(a, close: true)["running"] == .bool(false))
    _ = try control(a, close: false)
    let restarted = try connection(a)
    let restartProbe = try await visit(restarted, run: "restart")
    #expect(restartProbe["sent"] == .bool(true) && restartProbe["httpOnly"] == .bool(true))
    restarted.close()
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    _ = try control(b, close: false)
    let other = try connection(b)
    let otherProbe = try await visit(other, run: "isolated")
    #expect(otherProbe["sent"] == .bool(false) && otherProbe["visible"] == .bool(false))
    other.close()
}
