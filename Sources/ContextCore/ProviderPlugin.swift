import Foundation

public struct PluginManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let title: String
    public let version: String
    public let executable: String
    public let arguments: [String]

    public func validate() throws {
        guard schemaVersion == 1, id != "direct",
              id.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
              !title.isEmpty, title.count <= 100, !version.isEmpty, version.count <= 64,
              Self.isRelativePath(executable), arguments.count <= 16,
              arguments.allSatisfy({ $0.count <= 1024 && !$0.contains("\0") }) else {
            throw ClientFailure("Некорректный или несовместимый манифест плагина")
        }
    }
    private static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct ProviderPlugin: Identifiable, Sendable {
    public let manifest: PluginManifest
    public let directory: URL
    public var id: String { manifest.id }
    public var route: RequestRoute { RequestRoute(rawValue: id) }
    public init(directory: URL) throws {
        let file = directory.appendingPathComponent("plugin.json")
        let data = try Data(contentsOf: file)
        guard data.count <= 65_536 else { throw ClientFailure("Слишком большой манифест плагина") }
        manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        guard directory.lastPathComponent == manifest.id else { throw ClientFailure("ID плагина не совпадает с папкой установки") }
        self.directory = directory
    }
    public func providerArguments(endpoint: URL) throws -> [String] {
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let port = endpoint.port, (1...65535).contains(port),
              endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.user == nil, endpoint.password == nil else { throw ClientFailure("Плагин должен использовать локальный адрес") }
        // Plugins expose Responses proxies. They cannot supply arbitrary Codex settings.
        let prefix = "model_providers." + route.providerID
        let values = ["\(prefix).name=\"OpenAI\"", "\(prefix).base_url=\"http://127.0.0.1:\(port)/v1\"",
                      "\(prefix).wire_api=\"responses\"", "\(prefix).requires_openai_auth=true",
                      "\(prefix).supports_websockets=true", "\(prefix).request_max_retries=0", "\(prefix).stream_max_retries=0"]
        return values.flatMap { ["-c", $0] }
    }
}

public enum PluginCatalog {
    public static var defaultDirectory: URL { Locations.root.appendingPathComponent("plugins", isDirectory: true) }
    /// Discovery only reads manifests. It never executes newly discovered code.
    public static func scan(directory: URL) -> (plugins: [ProviderPlugin], issues: [String]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        do {
            let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var plugins: [ProviderPlugin] = [], issues: [String] = []
            for folder in folders {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                do { plugins.append(try ProviderPlugin(directory: folder)) }
                catch { issues.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
            }
            return (plugins, issues)
        } catch { return ([], [error.localizedDescription]) }
    }
}

public struct PluginMetric: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let value: Int
}
public struct PluginStatus: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let pluginID: String
    public let pluginVersion: String
    public let instance: String
    public let detail: String
    public let metrics: [PluginMetric]
}

/// Protocol v1: a separately installed executable serves a loopback Responses proxy.
public actor ProviderPluginRuntime {
    private let plugin: ProviderPlugin
    private let codexHome: URL
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var endpoint: URL?
    private var instance = ""
    private var readyFile: URL?
    private let session: URLSession

    public init(plugin: ProviderPlugin, codexHome: URL = Locations.codexHome) {
        self.plugin = plugin
        self.codexHome = codexHome
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        session = URLSession(configuration: config, delegate: PluginHTTPDelegate(), delegateQueue: nil)
    }
    public func start() async throws -> URL {
        if let endpoint, process?.isRunning == true { _ = try await status(); return endpoint }
        stop()
        let executable = plugin.directory.appendingPathComponent(plugin.manifest.executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ClientFailure("Плагин не установлен полностью: \(plugin.manifest.title)") }
        let root = plugin.directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        instance = UUID().uuidString
        let ready = root.appendingPathComponent("ready-\(instance).json")
        readyFile = ready
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executable
        child.arguments = plugin.manifest.arguments + ["--state", root.path, "--ready-file", ready.path,
            "--instance", instance, "--parent", String(ProcessInfo.processInfo.processIdentifier)]
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1", "CODEX_HOME": codexHome.path]
        for key in ["LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        child.environment = env
        child.currentDirectoryURL = plugin.directory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        stderr.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        do {
            try child.run()
            process = child; output = stdout; errors = stderr
            for _ in 0..<600 {
                try Task.checkCancellation()
                guard child.isRunning else { throw ClientFailure("Плагин завершился при запуске: \(plugin.manifest.title) (\(child.terminationStatus))") }
                if let data = try? Data(contentsOf: ready), data.count <= 4096,
                   let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    guard value["instance"].string == instance, value["protocolVersion"].int == 1,
                          value["pluginID"].string == plugin.id,
                          let port = value["port"].int, (1...65535).contains(port) else {
                        throw ClientFailure("Несовместимый ответ плагина при запуске")
                    }
                    let url = URL(string: "http://127.0.0.1:\(port)")!
                    endpoint = url
                    _ = try await status()
                    return url
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ClientFailure("Плагин не успел запуститься: \(plugin.manifest.title)")
        } catch { stop(); throw error }
    }
    public func status() async throws -> PluginStatus {
        guard process?.isRunning == true, let endpoint else { throw ClientFailure("Плагин остановлен: \(plugin.manifest.title)") }
        let (data, response) = try await session.data(from: endpoint.appendingPathComponent("contextdesk/status"))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
              response.url?.host == "127.0.0.1", response.url?.port == endpoint.port else {
            throw ClientFailure("Плагин недоступен: \(plugin.manifest.title)")
        }
        let value = try JSONDecoder().decode(PluginStatus.self, from: data)
        guard value.instance == instance, value.protocolVersion == 1, value.pluginID == plugin.id,
              value.pluginVersion == plugin.manifest.version, value.detail.count <= 1024,
              value.metrics.count <= 20, Set(value.metrics.map(\.id)).count == value.metrics.count,
              value.metrics.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 && $0.title.count <= 100 }) else {
            throw ClientFailure("Ответ получен от несовместимого экземпляра плагина")
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

private final class PluginHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
