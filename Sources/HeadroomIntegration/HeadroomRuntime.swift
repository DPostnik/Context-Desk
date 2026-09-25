import Foundation
import ContextCore

extension RequestRoute {
    public static func providerArguments(endpoint: URL) throws -> [String] {
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let port = endpoint.port, (1...65535).contains(port),
              endpoint.path == "", endpoint.query == nil, endpoint.user == nil else {
            throw ClientFailure(L10n.text("Headroom должен работать на локальном адресе приложения", "Headroom must use the app’s local address"))
        }
        // Codex uses the exact display name OpenAI to retain remote compaction.
        let values = [
            "model_providers.contextdesk_headroom.name=\"OpenAI\"",
            "model_providers.contextdesk_headroom.base_url=\"http://127.0.0.1:\(port)/v1\"",
            "model_providers.contextdesk_headroom.wire_api=\"responses\"",
            "model_providers.contextdesk_headroom.requires_openai_auth=true",
            "model_providers.contextdesk_headroom.supports_websockets=true",
            "model_providers.contextdesk_headroom.request_max_retries=0",
            "model_providers.contextdesk_headroom.stream_max_retries=0"
        ]
        return values.flatMap { ["-c", $0] }
    }
}

public struct HeadroomStatus: Codable, Sendable, Equatable {
    public var instance: String
    public var version: String
    public var profile: String
    public var requests: Int
    public var failed: Int
    public var tokensSaved: Int
}

/// Owns a loopback-only proxy. Never attaches to an unrelated listener or retries a turn.
public actor HeadroomRuntime {
    public static let pinnedVersion = "0.38.0"
    public static var defaultRoot: URL { Locations.root.appendingPathComponent("headroom", isDirectory: true) }
    private let root: URL
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var endpoint: URL?
    private var instance = ""
    private var readyFile: URL?
    private let session: URLSession

    public init(root: URL = HeadroomRuntime.defaultRoot) {
        self.root = root
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        session = URLSession(configuration: config)
    }

    public func start() async throws -> URL {
        if let endpoint, process?.isRunning == true { _ = try await status(); return endpoint }
        stop()
        let python = root.appendingPathComponent("venv/bin/python")
        let script = root.appendingPathComponent("headroom_server.py")
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: script.path) else {
            throw ClientFailure(L10n.text("Headroom не установлен. Выполни scripts/install-headroom.sh в папке приложения.", "Headroom is not installed. Run scripts/install-headroom.sh in the app’s folder."))
        }
        instance = UUID().uuidString
        let ready = root.appendingPathComponent("ready-\(instance).json")
        readyFile = ready
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = python
        child.arguments = [script.path, "--state", root.path, "--ready-file", ready.path,
                           "--instance", instance, "--parent", String(ProcessInfo.processInfo.processIdentifier)]
        // Deliberately pass no provider keys or inherited Headroom configuration.
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1",
                   "CODEX_HOME": Locations.codexHome.path]
        for key in ["LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        child.environment = env
        child.currentDirectoryURL = root
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        stderr.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        do {
            try child.run()
            process = child; output = stdout; errors = stderr
            for _ in 0..<600 {
                try Task.checkCancellation()
                guard child.isRunning else { throw ClientFailure(L10n.text("Headroom завершился при запуске (код \(child.terminationStatus))", "Headroom exited during startup (code \(child.terminationStatus))")) }
                if let data = try? Data(contentsOf: ready), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                   value["instance"].string == instance, let port = value["port"].int, (1...65535).contains(port) {
                    let url = URL(string: "http://127.0.0.1:\(port)")!
                    endpoint = url
                    _ = try await status()
                    return url
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ClientFailure(L10n.text("Headroom не успел запуститься. Проверь установку и подключись заново.", "Headroom startup timed out. Check the installation and reconnect."))
        } catch { stop(); throw error }
    }

    public func status() async throws -> HeadroomStatus {
        guard process?.isRunning == true, let endpoint else { throw ClientFailure(L10n.text("Headroom остановлен", "Headroom is stopped")) }
        let (data, response) = try await session.data(from: endpoint.appendingPathComponent("contextdesk/status"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientFailure(L10n.text("Headroom недоступен", "Headroom is unavailable")) }
        let value = try JSONDecoder().decode(HeadroomStatus.self, from: data)
        guard value.instance == instance, value.version == Self.pinnedVersion, value.profile == "cache-lossless" else {
            throw ClientFailure(L10n.text("Ответ получен от несовместимого экземпляра Headroom", "An incompatible Headroom instance responded"))
        }
        return value
    }

    public func stop() {
        if process?.isRunning == true { process?.terminate() }
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        process = nil; output = nil; errors = nil; endpoint = nil
        if let readyFile { try? FileManager.default.removeItem(at: readyFile) }
        readyFile = nil
    }
}
