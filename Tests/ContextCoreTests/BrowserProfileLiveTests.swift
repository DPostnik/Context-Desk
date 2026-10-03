import Foundation
import Testing
@testable import ContextCore

/// Actual pinned Chrome, disposable profiles, loopback website only. No provider call.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CONTEXTDESK_PROFILE_SMOKE"] == "1"))
func browserProfileLiveHandoffRetainsCookiesLocalStorageAndIndexedDB() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("profile-live-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let runtime = repository.appendingPathComponent("build/Context Desk.app/Contents/Resources/BrowserRuntime")
    let server = Process(), pipe = Pipe(), serverExited = DispatchSemaphore(value: 0)
    server.terminationHandler = { _ in serverExited.signal() }
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", "-c", #"""
import http.server, json, pathlib, sys, urllib.parse
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(p.query)
        if p.path=='/probe':
            (root/('probe-'+q['run'][0]+'.json')).write_text(json.dumps({
                'cookie':'auth=fixture-auth' in self.headers.get('Cookie',''),
                'local':q.get('local',[''])[0]=='fixture-local',
                'idb':q.get('idb',[''])[0]=='fixture-idb'}))
            body=b'ok'
        else:
            run=q['run'][0]; seed=run=='seed'
            body=('''<script>(async()=>{
              const seed=%s;
              if(seed)localStorage.setItem('auth','fixture-local');
              const db=await new Promise((ok,no)=>{let r=indexedDB.open('auth-fixture',1);
                r.onupgradeneeded=()=>r.result.createObjectStore('tokens');r.onsuccess=()=>ok(r.result);r.onerror=no;});
              if(seed)await new Promise((ok,no)=>{let t=db.transaction('tokens','readwrite');t.objectStore('tokens').put('fixture-idb','auth');t.oncomplete=ok;t.onerror=no;});
              const token=await new Promise((ok,no)=>{let r=db.transaction('tokens').objectStore('tokens').get('auth');r.onsuccess=()=>ok(r.result||'');r.onerror=no;});db.close();
              await fetch('/probe?run=%s&local='+encodeURIComponent(localStorage.getItem('auth')||'')+'&idb='+encodeURIComponent(token));
            })();</script>''' % ('true' if seed else 'false',run)).encode()
        self.send_response(200);self.send_header('Content-Type','text/html')
        if p.path=='/' and q.get('run')==['seed']:self.send_header('Set-Cookie','auth=fixture-auth; HttpOnly; Path=/; Max-Age=3600; SameSite=Lax')
        self.end_headers();self.wfile.write(body)
    def log_message(self,*_):pass
s=http.server.HTTPServer(('127.0.0.1',0),Handler);print(s.server_port,flush=True);s.serve_forever()
"""#, root.path]
    server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    defer {
        if server.isRunning { server.terminate() }
        let exited = { serverExited.wait(timeout: .now() + 5) == .success }()
        #expect(exited)
    }
    var line = Data()
    while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]), line.count < 8 { line.append(byte) }
    let port = try #require(Int(String(decoding: line, as: UTF8.self)))
    let store = BrowserProfileStore(root: root)
    let a = AgentSessionReference(connection: .originalCodex, nativeID: "fixture-a")
    let b = AgentSessionReference(connection: .originalCodex, nativeID: "fixture-b")
    let separate = AgentSessionReference(connection: .originalCodex, nativeID: "fixture-separate")
    let initial = try store.prepareNew(project: root.path, connection: .originalCodex)
    try store.acknowledge(initial, session: a)
    try store.rename(session: a, name: "Fixture")
    var current = initial
    let other = try store.prepareNew(project: root.path, connection: .originalCodex)
    try store.acknowledge(other, session: separate)
    defer {
        _ = try? BrowserProfileControl.status(environment: store.environment(current.environment), runtime: runtime, grant: current, close: true)
        _ = try? BrowserProfileControl.status(environment: store.environment(other.environment), runtime: runtime, grant: other, close: true)
    }
    func visit(_ grant: BrowserProfileGrant, run: String) async throws -> JSONValue {
        try store.validate(grant, environment: grant.environment)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", runtime.appendingPathComponent("chrome_host.py").path, "--root", store.environment(grant.environment).path, "--prepare-cookie-import"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let result = try JSONDecoder().decode(JSONValue.self, from: output.fileHandleForReading.readDataToEndOfFile())
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let address = try #require(result["webSocketURL"].string)
        let connection = try CookieCDP(endpoint: #require(URL(string: address)))
        defer { connection.close() }
        _ = try await connection.call("Target.createTarget", parameters: .object(["url": .string("http://127.0.0.1:\(port)/?run=\(run)")]))
        for _ in 0..<100 {
            if let bytes = try? Data(contentsOf: root.appendingPathComponent("probe-" + run + ".json")),
               let probe = try? JSONDecoder().decode(JSONValue.self, from: bytes) { return probe }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClientFailure("Loopback profile fixture timed out")
    }
    let seeded = try await visit(initial, run: "seed")
    #expect(seeded["cookie"] == .bool(true) && seeded["local"] == .bool(true) && seeded["idb"] == .bool(true))
    #expect(try BrowserProfileControl.status(environment: store.environment(initial.environment), runtime: runtime, grant: initial, close: true).running == false)
    try store.release(session: a) { try BrowserProfileControl.verifyClosed(environment: $0, runtime: runtime) }
    let reused = try store.prepareNew(project: root.path, connection: .originalCodex, selection: .init(id: initial.environment)) {
        try BrowserProfileControl.verifyClosed(environment: $0, runtime: runtime)
    }
    try store.acknowledge(reused, session: b); current = reused
    #expect(throws: BrowserProfileError.released) { try store.validate(initial, environment: initial.environment) }
    let restored = try await visit(reused, run: "reused")
    #expect(restored["cookie"] == .bool(true) && restored["local"] == .bool(true) && restored["idb"] == .bool(true))
    let isolated = try await visit(other, run: "separate")
    #expect(isolated["cookie"] == .bool(false) && isolated["local"] == .bool(false) && isolated["idb"] == .bool(false))
}
