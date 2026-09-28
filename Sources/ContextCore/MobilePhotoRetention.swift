import Foundation

/// Temporary app-owned image files only; never traverses links or deletes conversation data.
public enum MobilePhotoRetention {
    public static let lifetime: TimeInterval = 3600
    private static let metadataName = "retention.json"
    private struct Record: Codable {
        var chat: String?
        var expires: Date?
    }
    public static func register(folder: URL, chat: String) throws {
        try save(Record(chat: chat, expires: nil), folder: folder)
    }
    private static func save(_ record: Record, folder: URL) throws {
        let file = folder.appendingPathComponent(metadataName)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Start the one-hour grace period only when the owning chat is no longer active.
    /// Legacy folders and interrupted runs receive a fresh grace period on first observation.
    @discardableResult public static func sweep(root: URL, activeChats: Set<String>, now: Date = Date()) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { return 0 }
        var removed = 0
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // Unknown files or symlinks fail closed, including a substituted metadata file.
            guard try children.allSatisfy({ file in
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true &&
                    (file.lastPathComponent == metadataName || (file.pathExtension == "jpg" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil))
            }) else { continue }
            let metadata = folder.appendingPathComponent(metadataName)
            var record: Record
            if fm.fileExists(atPath: metadata.path) {
                guard let decoded = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: metadata)) else { continue }
                record = decoded
            } else { record = Record(chat: nil, expires: nil) }
            let active = record.chat.map { activeChats.contains($0) } ?? !activeChats.isEmpty
            if active {
                if record.expires != nil { record.expires = nil; try save(record, folder: folder) }
            } else if let expiry = record.expires {
                if expiry <= now { try fm.removeItem(at: folder); removed += 1 }
            } else {
                record.expires = now.addingTimeInterval(lifetime)
                try save(record, folder: folder)
            }
        }
        return removed
    }
}
