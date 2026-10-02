import Foundation
import Darwin

public struct ChromeCookieImportResult: Sendable {
    public let verified: Int
    public let skipped: Int
    public let unverified: Int
}

/// An explicit native UI operation, never an agent tool. All cookie values remain
/// in memory until Chrome persists them in this chat's existing dedicated profile.
public enum ChromeCookieImporter {
    public static func run(profile: String, environment: URL, runtime: URL, maxBrowsers: Int,
                           sourceIsRunning: @Sendable () -> Bool) async throws -> ChromeCookieImportResult {
        let read = try ChromeCookieSource.read(profile: profile, sourceIsRunning: sourceIsRunning)
        do { return try await transfer(read, environment: environment, runtime: runtime, maxBrowsers: maxBrowsers) }
        catch let error as ChromeCookieError { throw error }
        catch { throw ChromeCookieError.connection }
    }

    static func transfer(_ read: ChromeCookieRead, environment: URL, runtime: URL, maxBrowsers: Int,
                         browserRoot: URL = BrowserEnvironmentStore.directory) async throws -> ChromeCookieImportResult {
        guard !read.cookies.isEmpty else { throw ChromeCookieError.empty }
        let lock = try CookieImportLock(environment: environment, browserRoot: browserRoot)
        defer { lock.release() }
        try Task.checkCancellation()
        let endpoint = try prepare(environment: environment, runtime: runtime, maxBrowsers: maxBrowsers)
        let connection = try CookieCDP(endpoint: endpoint)
        defer { connection.close() }
        // A read confirms the connection before recording any possible mutation.
        _ = try await connection.call("Browser.getVersion")
        try Task.checkCancellation()
        let fence = environment.appendingPathComponent("executor-in-flight.json")
        return try await writeAndVerify(read, fence: fence) { method, parameters in
            try await connection.call(method, parameters: parameters)
        }
    }

    static func writeAndVerify(_ read: ChromeCookieRead, fence: URL,
                               call: @Sendable (String, JSONValue) async throws -> JSONValue) async throws -> ChromeCookieImportResult {
        guard !FileManager.default.fileExists(atPath: fence.path) else { throw ChromeCookieError.uncertain }
        let intent: JSONValue = .object(["client": .string("native-cookie-import"), "request": .string(UUID().uuidString),
                                        "tool": .string("chrome_cookie_import"), "state": .string("outcome_unknown")])
        try JSONEncoder().encode(intent).write(to: fence, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fence.path)
        do {
            // Exactly one write. Once intent is durable, every failure is uncertain.
            _ = try await call("Storage.setCookies", .object(["cookies": .array(read.cookies.map(\.parameters))]))
            let stored = try await call("Storage.getCookies", .object([:]))
            guard case .array(let values) = stored["cookies"] else { throw ChromeCookieError.uncertain }
            let indexed = Dictionary(grouping: values) { value in
                [value["domain"].string ?? "", value["name"].string ?? "", value["path"].string ?? ""]
            }
            let verified = read.cookies.filter { cookie in
                indexed[[cookie.host, cookie.name, cookie.path], default: []].contains { cookie.matches($0) }
            }.count
            // A completed read confirms the actual state, including partial rejection.
            try FileManager.default.removeItem(at: fence)
            return ChromeCookieImportResult(verified: verified, skipped: read.skipped, unverified: read.cookies.count - verified)
        } catch {
            // Never surface protocol errors: a remote response can contain secrets.
            throw ChromeCookieError.uncertain
        }
    }

    private static func prepare(environment: URL, runtime: URL, maxBrowsers: Int) throws -> URL {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", runtime.appendingPathComponent("chrome_host.py").path, "--root", environment.path,
                             "--prepare-cookie-import", "--max-browsers", String(min(8, max(1, maxBrowsers)))]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard data.count <= 32768, let result = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ChromeCookieError.connection }
        if result["code"].string == "destination_running" { throw ChromeCookieError.destinationRunning }
        if result["code"].string == "uncertain" { throw ChromeCookieError.uncertain }
        guard process.terminationStatus == 0, let address = result["webSocketURL"].string, let url = URL(string: address),
              url.scheme == "ws", url.host == "127.0.0.1", let port = url.port, (1024...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/devtools/browser/") else { throw ChromeCookieError.connection }
        return url
    }
}

/// Shared with the Python executor and native close operation.
final class CookieImportLock {
    private var descriptor: Int32
    init(environment: URL, browserRoot: URL) throws {
        let root = browserRoot.standardizedFileURL
        let path = environment.standardizedFileURL
        guard UUID(uuidString: path.lastPathComponent) != nil,
              path.deletingLastPathComponent().path == root.appendingPathComponent("environments").path,
              path.resolvingSymlinksInPath().path == path.path else { throw ChromeCookieError.missingEnvironment }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(path.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ChromeCookieError.browserBusy }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1; throw ChromeCookieError.browserBusy
        }
    }
    func release() { if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    deinit { release() }
}

/// Single caller, sequential CDP requests. No redirects, proxies, retry or logs.
final class CookieCDP: @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var sequence = 0
    init(endpoint: URL) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 24 * 1024 * 1024
        socket.resume()
    }
    func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    func call(_ method: String, parameters: JSONValue = .object([:])) async throws -> JSONValue {
        sequence += 1
        let id = sequence
        let request: JSONValue = .object(["id": .number(Double(id)), "method": .string(method), "params": parameters])
        let data = try JSONEncoder().encode(request)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { [socket] in
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                    for _ in 0..<128 {
                        let message = try await socket.receive()
                        let bytes: Data
                        switch message {
                        case .data(let value): bytes = value
                        case .string(let value): bytes = Data(value.utf8)
                        @unknown default: throw ChromeCookieError.connection
                        }
                        let response = try JSONDecoder().decode(JSONValue.self, from: bytes)
                        if response["id"] == .number(Double(id)) {
                            guard response["error"] == .null, case .object = response["result"] else { throw ChromeCookieError.connection }
                            return response["result"]
                        }
                        guard response["id"] == .null, response["method"].string != nil else { throw ChromeCookieError.connection }
                    }
                    throw ChromeCookieError.connection
                }
                group.addTask { [socket] in
                    try await Task.sleep(for: .seconds(15))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw ChromeCookieError.connection
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { [socket] in socket.cancel(with: .goingAway, reason: nil) }
    }
}
