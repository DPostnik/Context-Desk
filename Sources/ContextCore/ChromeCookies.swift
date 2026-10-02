import Foundation
import CommonCrypto
import CryptoKit
import Security
import CSQLite

public enum ChromeCookieError: Error, LocalizedError, Sendable {
    case sourceRunning, unavailable, invalidProfile, unsupportedSchema, keychain, sourceChanged, tooLarge
    case browserBusy, destinationRunning, uncertain, connection, missingEnvironment, empty

    public var errorDescription: String? { message(language: L10n.language) }
    public func message(language: AppLanguage) -> String {
        switch self {
        case .sourceRunning: return L10n.text("Заверши обычный Google Chrome через Cmd+Q, затем повтори импорт.", "Quit regular Google Chrome with Cmd+Q, then import again.", language: language)
        case .unavailable: return L10n.text("Не удалось прочитать cookies выбранного профиля Chrome.", "Could not read cookies from the selected Chrome profile.", language: language)
        case .invalidProfile: return L10n.text("Профиль Chrome недоступен или его путь изменился. Обнови список профилей.", "The Chrome profile is unavailable or its path changed. Refresh the profile list.", language: language)
        case .unsupportedSchema: return L10n.text("Этот формат cookies Chrome пока не поддерживается. Импорт не выполнен.", "This Chrome cookie format is not supported yet. Nothing was imported.", language: language)
        case .keychain: return L10n.text("Не получен доступ к Chrome Safe Storage в Связке ключей. Разреши доступ при следующем явном импорте.", "Access to Chrome Safe Storage in Keychain was not granted. Allow access during your next explicit import.", language: language)
        case .sourceChanged: return L10n.text("Профиль Chrome изменился во время чтения. Заверши Chrome и начни импорт заново.", "The Chrome profile changed during reading. Quit Chrome and start a new import.", language: language)
        case .tooLarge: return L10n.text("Профиль cookies превышает поддерживаемый размер. Импорт не выполнен.", "The cookie profile exceeds the supported size. Nothing was imported.", language: language)
        case .browserBusy: return L10n.text("Браузер чата занят. Дождись завершения текущей операции.", "This chat's browser is busy. Wait for its current operation to finish.", language: language)
        case .destinationRunning: return L10n.text("Перед импортом закрой Chrome for Testing этого чата через меню «Браузер». Импорт откроет его снова.", "Before importing, close this chat's Chrome for Testing from the Browser menu. Import will reopen it.", language: language)
        case .uncertain: return L10n.text("Результат импорта не подтверждён. Повтора не было. Проверь браузер и заверши его через Cmd+Q перед новым импортом.", "The import outcome is unconfirmed. Nothing was retried. Check the browser and quit it with Cmd+Q before a new import.", language: language)
        case .connection: return L10n.text("Не удалось подготовить проверенное подключение к браузеру чата. Cookies не отправлены.", "Could not prepare a verified connection to this chat's browser. Cookies were not sent.", language: language)
        case .missingEnvironment: return L10n.text("У чата ещё нет среды браузера. Примени настройку браузера и открой чат снова.", "This chat has no browser environment yet. Apply the browser setting and reopen the chat.", language: language)
        case .empty: return L10n.text("В профиле нет поддерживаемых действующих cookies для импорта.", "The profile has no supported, unexpired cookies to import.", language: language)
        }
    }
}

public struct ChromeCookieProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

/// Secret values stay in memory and travel only to the app-owned Chrome endpoint.
public struct ImportedChromeCookie: Sendable, Equatable {
    public let host: String
    public let name: String
    public let value: String
    public let path: String
    public let secure: Bool
    public let httpOnly: Bool
    public let sameSite: String?
    public let expires: Double?

    public var parameters: JSONValue {
        var fields: [String: JSONValue] = ["url": .string((secure ? "https://" : "http://") + host.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "/"),
            "name": .string(name), "value": .string(value), "path": .string(path), "secure": .bool(secure), "httpOnly": .bool(httpOnly)]
        if host.hasPrefix(".") { fields["domain"] = .string(host) }
        if let sameSite { fields["sameSite"] = .string(sameSite) }
        if let expires { fields["expires"] = .number(expires) }
        return .object(fields)
    }
    public func matches(_ stored: JSONValue, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard stored["domain"].string == host, stored["name"].string == name,
              stored["value"].string == value, stored["path"].string == path,
              stored["secure"].bool == secure, stored["httpOnly"].bool == httpOnly else { return false }
        if let sameSite, stored["sameSite"].string != sameSite { return false }
        if let expires {
            guard case .number(let actual) = stored["expires"], actual.isFinite, actual > now, actual <= expires + 1,
                  stored["session"].bool == false else { return false }
        } else if stored["session"].bool != true { return false }
        return true
    }
}

public struct ChromeCookieRead: Sendable {
    public var cookies: [ImportedChromeCookie] = []
    public var expired = 0
    public var partitioned = 0
    public var unsupported = 0
    public var skipped: Int { expired + partitioned + unsupported }
}

public enum ChromeCookieSource {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true) }
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumCookies = 20_000

    private static func profileID(_ value: String) -> Bool {
        value == "Default" || (value.hasPrefix("Profile ") && !value.dropFirst(8).isEmpty && value.dropFirst(8).allSatisfy { $0.isASCII && $0.isNumber })
    }
    private static func checked(_ relative: String, root: URL) throws -> URL {
        let source = root.appendingPathComponent(relative).standardizedFileURL
        guard source.resolvingSymlinksInPath().path == source.path,
              source.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ChromeCookieError.invalidProfile }
        return source
    }
    public static func profiles(root: URL = directory) throws -> [ChromeCookieProfile] {
        let file = try checked("Local State", root: root)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ChromeCookieError.unavailable }
        return try json["profile"]["info_cache"].object.keys.filter(profileID).sorted().compactMap { id in
            let folder = try checked(id, root: root)
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return ChromeCookieProfile(id: id, name: json["profile"]["info_cache"][id]["name"].string ?? id)
        }
    }

    /// Reads an encrypted database snapshot; never opens the user's database with SQLite.
    public static func read(profile: String, root: URL = directory, now: Double = Date().timeIntervalSince1970,
                            sourceIsRunning: () -> Bool, key: () throws -> Data = keychainKey) throws -> ChromeCookieRead {
        guard !sourceIsRunning() else { throw ChromeCookieError.sourceRunning }
        guard profileID(profile), try profiles(root: root).contains(where: { $0.id == profile }) else { throw ChromeCookieError.invalidProfile }
        let choices = try ["\(profile)/Network/Cookies", "\(profile)/Cookies"].map { try checked($0, root: root) }
        guard let source = choices.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw ChromeCookieError.unavailable }
        let wal = URL(fileURLWithPath: source.path + "-wal")
        // Require Chrome to finish checkpointing before taking a file-level snapshot.
        if ((try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 { throw ChromeCookieError.sourceRunning }
        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard before.isRegularFile == true, let size = before.fileSize, size <= maximumBytes else { throw ChromeCookieError.tooLarge }
        let bytes = try Data(contentsOf: source)
        guard bytes.count <= maximumBytes else { throw ChromeCookieError.tooLarge }
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard !sourceIsRunning(), before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
              !FileManager.default.fileExists(atPath: wal.path) || ((try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1) == 0 else { throw ChromeCookieError.sourceChanged }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("contextdesk-cookie-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("Cookies")
        try bytes.write(to: snapshot, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        return try decode(snapshot: snapshot, now: now, key: key)
    }

    static func decode(snapshot: URL, now: Double, key: () throws -> Data) throws -> ChromeCookieRead {
        var database: OpaquePointer?
        guard sqlite3_open_v2(snapshot.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = database else {
            if let database { sqlite3_close(database) }; throw ChromeCookieError.unavailable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &statement, nil) == SQLITE_OK else { throw ChromeCookieError.unsupportedSchema }
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        sqlite3_finalize(statement); statement = nil
        // Chromium's v24 adds the domain hash; future schemas require review.
        guard version == 23 || version == 24 else { throw ChromeCookieError.unsupportedSchema }
        let sql = "SELECT host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite,top_frame_site_key,has_expires FROM cookies LIMIT 20001"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let row = statement else { throw ChromeCookieError.unsupportedSchema }
        defer { sqlite3_finalize(row) }
        func text(_ column: Int32) -> String? {
            let length = Int(sqlite3_column_bytes(row, column))
            guard length <= 1024 * 1024 else { return nil }
            guard let bytes = sqlite3_column_text(row, column) else { return "" }
            let data = Data(bytes: bytes, count: length)
            guard !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        var result = ChromeCookieRead(), material: Data?, count = 0, outputBytes = 0
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            count += 1
            guard count <= maximumCookies else { throw ChromeCookieError.tooLarge }
            defer { step = sqlite3_step(row) }
            guard let host = text(0), let name = text(1), let path = text(4), let partition = text(9) else {
                result.unsupported += 1; continue
            }
            if !partition.isEmpty { result.partitioned += 1; continue }
            let expiry = sqlite3_column_int(row, 10) == 0 ? nil : Optional(Double(sqlite3_column_int64(row, 5)) / 1_000_000 - 11_644_473_600)
            if let expiry, expiry <= now { result.expired += 1; continue }
            let sameSite = sqlite3_column_int(row, 8)
            guard [-1, 0, 1, 2].contains(sameSite), !host.isEmpty, host.utf8.count <= 255,
                  host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
                  !host.hasSuffix("."), !host.contains(".."), !name.isEmpty, name.utf8.count <= 4096,
                  !name.contains(where: { $0.asciiValue.map { $0 <= 32 || $0 >= 127 } ?? true }),
                  !name.contains(where: { "()<>@,;:\\\"/[]?={}".contains($0) }), path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { result.unsupported += 1; continue }
            let length = Int(sqlite3_column_bytes(row, 3))
            guard length <= 1024 * 1024 else { throw ChromeCookieError.tooLarge }
            let encrypted = sqlite3_column_blob(row, 3).map { Data(bytes: $0, count: length) } ?? Data()
            let value: String
            if encrypted.isEmpty {
                guard let plain = text(2) else { result.unsupported += 1; continue }
                value = plain
            }
            else {
                guard encrypted.starts(with: Data("v10".utf8)) else { result.unsupported += 1; continue }
                if material == nil { material = try key() }
                guard let decoded = decrypt(encrypted, key: material!, host: host, schema: Int(version)) else { result.unsupported += 1; continue }
                value = decoded
            }
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { result.unsupported += 1; continue }
            outputBytes += value.utf8.count + name.utf8.count + host.utf8.count + path.utf8.count
            guard outputBytes <= 16 * 1024 * 1024 else { throw ChromeCookieError.tooLarge }
            result.cookies.append(.init(host: host, name: name, value: value, path: path, secure: sqlite3_column_int(row, 6) != 0,
                                        httpOnly: sqlite3_column_int(row, 7) != 0, sameSite: [0: "None", 1: "Lax", 2: "Strict"][sameSite], expires: expiry))
        }
        guard step == SQLITE_DONE else { throw ChromeCookieError.unavailable }
        return result
    }

    public static func keychainKey() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let secret = found as? Data, !secret.isEmpty else { throw ChromeCookieError.keychain }
        return try deriveKey(secret)
    }
    static func deriveKey(_ secret: Data) throws -> Data {
        let salt = Data("saltysalt".utf8); var result = Data(count: 16)
        let status = result.withUnsafeMutableBytes { output in secret.withUnsafeBytes { password in salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: Int8.self).baseAddress, secret.count,
                                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                1003, output.bindMemory(to: UInt8.self).baseAddress, 16)
        } } }
        guard status == kCCSuccess else { throw ChromeCookieError.keychain }; return result
    }
    static func decrypt(_ encrypted: Data, key: Data, host: String, schema: Int) -> String? {
        guard key.count == 16, encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3 else { return nil }
        let payload = Data(encrypted.dropFirst(3)), iv = Data(repeating: 0x20, count: 16)
        var output = Data(count: payload.count + 16), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { destination in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in payload.withUnsafeBytes { source in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, payload.count,
                    destination.baseAddress, capacity, &written)
        } } } }
        guard status == kCCSuccess else { return nil }
        output.count = written
        if schema >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard output.starts(with: digest) else { return nil }
            output.removeFirst(32)
        }
        return String(data: output, encoding: .utf8)
    }
}
