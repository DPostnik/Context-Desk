import Foundation
import CryptoKit

/// Persistent browser ownership; stores no authentication material.
public enum BrowserEnvironmentStore {
    public static var directory: URL { Locations.root.appendingPathComponent("browser", isDirectory: true) }
    /// Host-owned identity, independent of MCP process IDs and model arguments.
    public static func bindingPath(session: String, root: URL) -> URL {
        let key = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("bindings").appendingPathComponent(key + ".json")
    }

    public static func existingEnvironment(session: String, root: URL = directory) throws -> URL? {
        let path = bindingPath(session: session, root: root)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: path))
        return root.appendingPathComponent("environments").appendingPathComponent(id.uuidString.lowercased())
    }

    public static func environment(session: String, root: URL) throws -> UUID {
        let path = bindingPath(session: session, root: root)
        if FileManager.default.fileExists(atPath: path.path) {
            return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: path))
        }
        let id = UUID()
        try bind(id, session: session, root: root)
        return id
    }

    public static func bind(_ id: UUID, session: String, root: URL) throws {
        let path = bindingPath(session: session, root: root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(id).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

}
