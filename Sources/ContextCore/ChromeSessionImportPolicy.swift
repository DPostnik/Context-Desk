import Foundation

/// App-owned consent metadata. No cookies or Keychain material are persisted here.
public struct ChromeSessionImportPolicy: Codable, Equatable, Sendable {
    public let profile: String
    public let site: String

    public init(profile: String, site: String) throws {
        let domain = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
                  $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
              profile == "Default" || (profile.hasPrefix("Profile ") && !profile.dropFirst(8).isEmpty &&
                  profile.dropFirst(8).allSatisfy { $0.isASCII && $0.isNumber }) else { throw ChromeCookieError.invalidProfile }
        self.profile = profile
        self.site = domain
    }

    public static func includes(host: String, site: String) -> Bool {
        let host = host.lowercased().hasPrefix(".") ? String(host.lowercased().dropFirst()) : host.lowercased()
        return host == site || host.hasSuffix("." + site)
    }

    public static func load(environment: URL) throws -> Self? {
        let file = environment.appendingPathComponent("chrome-session-import.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard file.resolvingSymlinksInPath().path == file.path,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4096 else { throw ChromeCookieError.invalidProfile }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        return try Self(profile: value.profile, site: value.site)
    }

    public static func save(_ policy: Self?, environment: URL, grant: BrowserProfileGrant?,
                            browserRoot: URL = BrowserEnvironmentStore.directory) throws {
        let lock = try CookieImportLock(environment: environment, browserRoot: browserRoot)
        defer { lock.release() }
        guard let id = UUID(uuidString: environment.lastPathComponent) else { throw ChromeCookieError.missingEnvironment }
        try BrowserProfileStore(root: browserRoot).validate(grant, environment: id, allowHuman: true)
        let file = environment.appendingPathComponent("chrome-session-import.json")
        if let policy {
            try JSONEncoder().encode(policy).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

extension ChromeCookieImporter {
    /// The executor holds operation.lock and has verified the lease and owned endpoint.
    /// Secrets stay inside this native process and the destination CDP connection.
    public static func importSession(environment: URL, site: String, endpoint: URL,
                                     sourceIsRunning: @Sendable () -> Bool) async throws -> ChromeCookieImportResult {
        let root = BrowserEnvironmentStore.directory.standardizedFileURL
        guard environment.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("environments").path,
              environment.resolvingSymlinksInPath().path == environment.path,
              UUID(uuidString: environment.lastPathComponent) != nil,
              let policy = try ChromeSessionImportPolicy.load(environment: environment), policy.site == site,
              endpoint.scheme == "ws", endpoint.host == "127.0.0.1", let port = endpoint.port,
              (1024...65535).contains(port), endpoint.path.hasPrefix("/devtools/browser/"),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw ChromeCookieError.invalidProfile }
        let read = try ChromeCookieSource.read(profile: policy.profile, site: site, sourceIsRunning: sourceIsRunning)
        guard !read.cookies.isEmpty else { throw ChromeCookieError.empty }
        let connection = try CookieCDP(endpoint: endpoint)
        defer { connection.close() }
        _ = try await connection.call("Browser.getVersion")
        return try await writeAndVerify(read, fence: environment.appendingPathComponent("executor-in-flight.json"), executorFence: true) { method, parameters in
            try await connection.call(method, parameters: parameters)
        }
    }
}
