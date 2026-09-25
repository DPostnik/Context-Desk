import Foundation
import CSQLite

/// SQLite metadata only. The official engine owns chat transcripts and credentials.
public actor AppStore {
    private let file: URL
    public init(file: URL) { self.file = file }
    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ClientFailure(L10n.text("Не удалось открыть хранилище", "Could not open storage"))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            throw ClientFailure(L10n.text("Не удалось подготовить хранилище", "Could not prepare storage"))
        }
        return try operation(db)
    }
    public func load() throws -> SavedState {
        try withDatabase { db in
            var s: OpaquePointer?; defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key='app'", -1, &s, nil) == SQLITE_OK else { throw ClientFailure(L10n.text("Ошибка чтения", "Could not read data")) }
            if sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) {
                return try JSONDecoder().decode(SavedState.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0))))
            }
            return SavedState()
        }
    }
    public func save(_ state: SavedState) throws {
        try put(key: "app", bytes: JSONEncoder().encode(state))
    }
    public func saveDeletingChat(_ state: SavedState, threadID: String) throws {
        let bytes = try JSONEncoder().encode(state)
        try withDatabase { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw ClientFailure(L10n.text("Не удалось начать удаление чата", "Could not begin deleting the chat"))
            }
            do {
                try put(db: db, key: "app", bytes: bytes)
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(db, "DELETE FROM state WHERE key=?", -1, &statement, nil) == SQLITE_OK else {
                    throw ClientFailure(L10n.text("Не удалось удалить метрики чата", "Could not delete chat metrics"))
                }
                let key = "usage:" + threadID
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
                guard sqlite3_step(statement) == SQLITE_DONE,
                      sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw ClientFailure(L10n.text("Не удалось сохранить удаление чата", "Could not save the chat deletion"))
                }
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }
    public func saveUsage(threadID: String, snapshot: UsageSnapshot) throws {
        try put(key: "usage:" + threadID, bytes: JSONEncoder().encode(snapshot))
    }
    public func loadUsage() throws -> [String: UsageSnapshot] {
        try withDatabase { db in
            var s: OpaquePointer?; defer { sqlite3_finalize(s) }
            guard sqlite3_prepare_v2(db, "SELECT key,value FROM state WHERE key LIKE 'usage:%'", -1, &s, nil) == SQLITE_OK else { throw ClientFailure(L10n.text("Ошибка чтения метрик", "Could not read metrics")) }
            var values: [String: UsageSnapshot] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                if let key = sqlite3_column_text(s, 0), let bytes = sqlite3_column_blob(s, 1) {
                    let id = String(cString: key).dropFirst(6)
                    values[String(id)] = try JSONDecoder().decode(UsageSnapshot.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 1))))
                }
            }
            return values
        }
    }
    private func put(key: String, bytes: Data) throws {
        try withDatabase { db in try put(db: db, key: key, bytes: bytes) }
    }
    private func put(db: OpaquePointer, key: String, bytes: Data) throws {
        var s: OpaquePointer?; defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &s, nil) == SQLITE_OK else { throw ClientFailure(L10n.text("Ошибка сохранения", "Could not save data")) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(s, 1, $0, -1, transient) }
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw ClientFailure(L10n.text("Не удалось сохранить состояние", "Could not save state")) }
    }
}
