import Foundation

/// App-owned consent metadata. No cookies or Keychain material are persisted here.
public struct ChromeSessionImportPolicy: Codable, Equatable, Sendable {
    public let profile: String
    public let site: String

    /// Wildcard site: any website, limited per import to the cookies Chrome would send to the agent tab's host.
    public static let anySite = "*"
    public var coversAnySite: Bool { site == Self.anySite }

    public init(profile: String, site: String) throws {
        let domain = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard domain == Self.anySite || Self.validDomain(domain),
              profile == "Default" || (profile.hasPrefix("Profile ") && !profile.dropFirst(8).isEmpty &&
                  profile.dropFirst(8).allSatisfy { $0.isASCII && $0.isNumber }) else { throw ChromeCookieError.invalidProfile }
        self.profile = profile
        self.site = domain
    }

    static func validDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return domain.utf8.count <= 253 && labels.count >= 2 &&
            labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
                $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
    }

    public static func includes(host: String, site: String) -> Bool {
        let host = host.lowercased().hasPrefix(".") ? String(host.lowercased().dropFirst()) : host.lowercased()
        return host == site || host.hasSuffix("." + site)
    }

    /// RFC 6265 domain matching: host-only cookies of exactly this host plus domain cookies of the host or its parents.
    /// Chrome never stores domain cookies on public suffixes, so this never spans unrelated sites.
    public static func sent(cookieHost: String, toPageHost page: String) -> Bool {
        let cookie = cookieHost.lowercased(), page = page.lowercased()
        guard cookie.hasPrefix(".") else { return cookie == page }
        let domain = String(cookie.dropFirst())
        return page == domain || page.hasSuffix("." + domain)
    }

    /// Resolves the source profile and cookie filter for an agent request: the chat's own policy first, then the
    /// app-wide policy saved in the browser root.
    public static func resolve(site: String, environment: URL, browserRoot: URL) throws -> (profile: String, site: String?, pageHost: String?)? {
        let host = site.lowercased()
        guard validDomain(host) else { return nil }
        for policy in [try load(environment: environment), try load(environment: browserRoot)].compactMap({ $0 }) {
            if policy.site == host { return (policy.profile, host, nil) }
            if policy.coversAnySite { return (policy.profile, nil, host) }
        }
        return nil
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

extension ChromeSessionImportPolicy {
    /// App-wide consent shared by every chat browser; stored next to `environments/`, never inside a profile.
    public static func loadShared(browserRoot: URL = BrowserEnvironmentStore.directory) throws -> Self? {
        try load(environment: browserRoot)
    }

    public static func saveShared(_ policy: Self?, browserRoot: URL = BrowserEnvironmentStore.directory) throws {
        let file = browserRoot.appendingPathComponent("chrome-session-import.json")
        guard browserRoot.resolvingSymlinksInPath().path == browserRoot.path,
              file.resolvingSymlinksInPath().path == file.path else { throw ChromeCookieError.invalidProfile }
        if let policy {
            try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
              let scope = try ChromeSessionImportPolicy.resolve(site: site, environment: environment, browserRoot: root),
              endpoint.scheme == "ws", endpoint.host == "127.0.0.1", let port = endpoint.port,
              (1024...65535).contains(port), endpoint.path.hasPrefix("/devtools/browser/"),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
        else { throw ChromeCookieError.invalidProfile }
        let read = try ChromeCookieSource.read(profile: scope.profile, site: scope.site, pageHost: scope.pageHost, sourceIsRunning: sourceIsRunning)
        guard !read.cookies.isEmpty else { throw ChromeCookieError.empty }
        let connection = try CookieCDP(endpoint: endpoint)
        defer { connection.close() }
        _ = try await connection.call("Browser.getVersion")
        return try await writeAndVerify(read, fence: environment.appendingPathComponent("executor-in-flight.json"), executorFence: true) { method, parameters in
            try await connection.call(method, parameters: parameters)
        }
    }
}
