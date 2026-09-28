// Manual live acceptance harness. Uses the app-owned Supabase setup directory;
// prints metrics only, never credentials, transcripts or account identifiers.
// Compile with MobileRealtime.swift, MobileRemote.swift and Localization.swift.
import Foundation

@MainActor @main struct VerifyMobileRealtime {
    struct Setup: Decodable { let url: String; let key: String; let email: String }
    struct Secrets: Decodable { let ownerPassword: String }
    struct Auth: Decodable { let access_token: String; let user: User; struct User: Decodable { let id: String } }
    enum Failure: Error { case check(String) }
    static var requests = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.check(message) }
    }
    static func request(_ setup: Setup, _ path: String, method: String = "GET", body: [String: Any]? = nil,
                        token: String? = nil, accepted: Set<Int> = [200,201,204]) async throws -> Data {
        requests += 1
        var req = URLRequest(url: URL(string: setup.url + "/" + path)!)
        req.httpMethod = method; req.timeoutInterval = 15
        req.setValue(setup.key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard accepted.contains(code) else { throw Failure.check("HTTP \(code) for \(path.components(separatedBy: "?")[0])") }
        return data
    }
    static func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.check("Timed out: " + label)
    }
    static func run() async throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Context Desk/mobile-setup")
        let setup = try JSONDecoder().decode(Setup.self, from: Data(contentsOf: directory.appendingPathComponent("project.json")))
        let secrets = try JSONDecoder().decode(Secrets.self, from: Data(contentsOf: directory.appendingPathComponent("setup-secrets.json")))
        let owner = try JSONDecoder().decode(Auth.self, from: await request(setup, "auth/v1/token?grant_type=password", method: "POST", body: ["email":setup.email,"password":secrets.ownerPassword]))
        let version = try await request(setup, "rest/v1/rpc/remote_protocol_version", method: "POST", body: [:], token: owner.access_token)
        try expect(try JSONDecoder().decode(Int.self, from: version) == 2, "schema version")
        var components = URLComponents(string: setup.url)!
        components.scheme = "wss"; components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: setup.key), URLQueryItem(name: "vsn", value: "1.0.0")]
        let socketURL = components.url!
        let device = UUID().uuidString.lowercased(); let project = UUID().uuidString.lowercased()
        var phoneReads = 0; var lastSync: RemoteSnapshotDelta?
        var phoneEvents: [RemoteInvalidation] = []; var macEvents: [RemoteInvalidation] = []
        let creds = RemoteRealtimeCredentials(url: socketURL, owner: owner.user.id, token: owner.access_token)
        let phone = RemoteRealtime(role: "phone", device: UUID().uuidString, credentials: { creds }, ready: {
            let data = try await request(setup, "rest/v1/rpc/read_remote_changes", method: "POST", body: ["device_id":device,"since_revision":-1], token: owner.access_token)
            lastSync = try JSONDecoder().decode(RemoteSnapshotDelta?.self, from: data); phoneReads += 1
        }, monitorNetwork: false)
        let mac = RemoteRealtime(role: "mac", device: device, credentials: { creds }, ready: {}, monitorNetwork: false)
        let forbidden = RemoteRealtime(role: "phone", device: UUID().uuidString, credentials: {
            RemoteRealtimeCredentials(url: socketURL, owner: UUID().uuidString.lowercased(), token: owner.access_token)
        }, ready: { throw Failure.check("Other owner joined private channel") }, monitorNetwork: false)
        phone.onState = { print("phone:", String(describing: $0)) }
        mac.onState = { print("mac:", String(describing: $0)) }
        phone.onError = { print("phone transport:", String(describing: type(of: $0))) }
        mac.onError = { print("mac transport:", String(describing: type(of: $0))) }
        phone.onChange = { phoneEvents.append($0) }; mac.onChange = { macEvents.append($0) }
        defer { phone.stop(); mac.stop(); forbidden.stop() }
        phone.start(); mac.start(); forbidden.start()
        do {
            try await wait("two ready native clients") { phone.state == .connected && mac.state == .connected }
            try await wait("private owner rejection") { forbidden.state == .failed }
            try await wait("Mac presence") { phone.presence.macs.contains(device) }
            let projects: [[String: Any]] = [["id":project,"name":"Realtime verification"]]
            func chat(_ id: String, _ text: String) -> [String: Any] {
                ["id":id,"project":project,"title":"Synthetic fixture","running":false,
                 "messages":[["id":"message","role":"assistant","text":text]],"approvals":[]]
            }
            func patch(_ changed: [[String: Any]], order: [String] = ["a","b"]) async throws {
                _ = try await request(setup, "rest/v1/rpc/patch_remote_snapshot", method: "POST", body: [
                    "device_id":device,"device_name":"Realtime verification fixture","project_list":projects,
                    "chat_order":order,"changed_chats":changed
                ], token: owner.access_token)
            }
            let start = ContinuousClock.now
            try await patch([chat("a","first"),chat("b","unchanged")])
            try await wait("committed database notification") { phoneEvents.contains { $0.device == device && $0.entity == "device" } }
            print("snapshot event latency (request + commit + receive):", ContinuousClock.now - start)
            let firstData = try await request(setup, "rest/v1/rpc/read_remote_changes", method: "POST", body: ["device_id":device,"since_revision":-1], token: owner.access_token)
            let first = try JSONDecoder().decode(RemoteSnapshotDelta.self, from: firstData)
            try expect(first.chats.count == 2, "initial snapshot")
            let count = phoneEvents.count
            try await patch([])
            try await Task.sleep(for: .milliseconds(300))
            try expect(phoneEvents.count == count, "unchanged snapshot emitted an event")
            try await patch([chat("a","changed")])
            let deltaData = try await request(setup, "rest/v1/rpc/read_remote_changes", method: "POST", body: ["device_id":device,"since_revision":first.device.revision!], token: owner.access_token)
            let delta = try JSONDecoder().decode(RemoteSnapshotDelta.self, from: deltaData)
            try expect(delta.chats.count == 1 && delta.chats[0].id == "a", "changed chat only")
            _ = try await request(setup, "rest/v1/rpc/read_remote_changes", method: "POST", body: ["device_id":device,"since_revision":-1], accepted:[401,403])
            let command = UUID().uuidString.lowercased()
            let commandStart = ContinuousClock.now
            _ = try await request(setup, "rest/v1/remote_commands", method: "POST", body: ["id":command,"owner":owner.user.id,"device":device,"project":project,"chat":"a","kind":"send","text":"Synthetic verification; never dispatched"], token: owner.access_token)
            try await wait("command notification") { macEvents.contains { $0.command == command } }
            print("command event latency (request + commit + receive):", ContinuousClock.now - commandStart)
            let claim = try await request(setup,"rest/v1/rpc/claim_remote_command",method:"POST",body:["device_id":device],token:owner.access_token)
            try expect(try JSONDecoder().decode([RemoteCommand].self,from:claim).count == 1,"single claim")
            let again = try await request(setup,"rest/v1/rpc/claim_remote_command",method:"POST",body:["device_id":device],token:owner.access_token)
            try expect(try JSONDecoder().decode([RemoteCommand].self,from:again).isEmpty,"no duplicate claim")
            _ = try await request(setup,"rest/v1/remote_commands?id=eq."+command,method:"PATCH",body:["status":"uncertain"],token:owner.access_token)
            _ = try await request(setup,"rest/v1/remote_commands?id=eq."+command,method:"PATCH",body:["status":"pending"],token:owner.access_token,accepted:[400])
            phone.stop()
            try await patch([chat("a","while disconnected")], order:["a"])
            phone.start()
            try await wait("reconnect snapshot") { phoneReads == 2 && phone.state == .connected }
            try expect(lastSync?.order == ["a"] && lastSync?.chats.first?.messages.first?.text == "while disconnected", "reconnect lost state")
            // Covers a full heartbeat interval: no REST reads, claims or publications.
            let idleRequests = requests; let beforeReceived = phone.receivedBytes + mac.receivedBytes
            let beforeSent = phone.sentBytes + mac.sentBytes
            try await Task.sleep(for: .seconds(26))
            try expect(requests == idleRequests, "periodic REST request")
            try expect(phone.state == .connected && mac.state == .connected, "idle heartbeat failed")
            print("26s idle: REST requests=0; two-client WebSocket bytes sent=\(phone.sentBytes + mac.sentBytes - beforeSent), received=\(phone.receivedBytes + mac.receivedBytes - beforeReceived)")
            mac.stop()
            try await wait("Mac disconnect presence") { !phone.presence.macs.contains(device) }
            print("PASS: native sockets, private topic isolation / anonymous denial, database events, incremental reads, no-op suppression, reconnect, deletion, presence, heartbeat, no duplicate claims")
        } catch {
            _ = try? await request(setup,"rest/v1/remote_devices?id=eq."+device,method:"DELETE",token:owner.access_token)
            throw error
        }
        _ = try await request(setup,"rest/v1/remote_devices?id=eq."+device,method:"DELETE",token:owner.access_token)
        let cleanup = try await request(setup,"rest/v1/remote_devices?id=eq."+device,token:owner.access_token)
        try expect(String(decoding:cleanup,as:UTF8.self) == "[]", "fixture cleanup")
        print("PASS: synthetic fixture removed; no agent task dispatched")
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL:", error); exit(1) }
    }
}
