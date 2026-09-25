import Foundation

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var accessMode: AccessMode?
    public init(path: String) {
        self.id = UUID(); self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.name = URL(fileURLWithPath: path).lastPathComponent
    }
}
public enum AccessMode: String, Codable, CaseIterable, Sendable {
    case standard, fullAccess

    public var title: String { self == .fullAccess ? L10n.text("Полный доступ", "Full access") : L10n.text("С подтверждениями", "Ask for approval") }
    public var threadParameters: [String: JSONValue] {
        ["approvalPolicy": .string(self == .fullAccess ? "never" : "on-request"),
         "sandbox": .string(self == .fullAccess ? "danger-full-access" : "workspace-write")]
    }
    public func turnParameters(projectPath: String) -> [String: JSONValue] {
        ["approvalPolicy": threadParameters["approvalPolicy"]!,
         "sandboxPolicy": self == .fullAccess
            ? .object(["type": .string("dangerFullAccess")])
            : .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(projectPath)]), "networkAccess": .bool(false)])]
    }
}
public struct Chat: Identifiable, Codable, Hashable, Sendable {
    /// The latest completion remains unread until its transcript end is visible.
    public var unreadCompletionID: String?
    public var hasUnreadResponse: Bool { unreadCompletionID != nil }
    public var archived: Bool?
    public var isArchived: Bool { archived == true }
    public var route: RequestRoute?
    public var id: String
    public var projectID: UUID
    public var title: String
    public var model: String
    public var updated: Date
    public init(id: String, projectID: UUID, title: String, model: String) {
        self.id = id; self.projectID = projectID; self.title = title; self.model = model; updated = Date()
    }
}
public struct QueuedMessage: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var threadID: String
    public var projectID: UUID
    public var text: String
    public var model: String
    public var effort: String
    public init(id: String, threadID: String, projectID: UUID, text: String, model: String, effort: String) {
        self.id = id; self.threadID = threadID; self.projectID = projectID
        self.text = text; self.model = model; self.effort = effort
    }
}
public struct SavedState: Codable, Sendable {
    public var defaultRoute: RequestRoute?
    public var queuedMessages: [QueuedMessage]?
    public var projects: [Project] = []
    public var chats: [Chat] = []
    public var model: String = ""
    public init() {}
}
public struct TranscriptItem: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var text: String
    public var phase: String?
    public init(id: String, kind: String, text: String, phase: String? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.phase = phase
    }
    public static func parse(_ raw: JSONValue) -> Self? {
        guard let id = raw["id"].string, let type = raw["type"].string else { return nil }
        switch type {
        case "userMessage":
            return Self(id: id, kind: "user", text: raw["content"].array.compactMap { $0["text"].string }.joined(separator: "\n"))
        case "agentMessage": return Self(id: id, kind: "assistant", text: raw["text"].string ?? "", phase: raw["phase"].string)
        case "contextCompaction": return Self(id: id, kind: "activity", text: L10n.text("Контекст разговора сжат", "Conversation context compacted"))
        case "commandExecution": return Self(id: id, kind: "activity", text: raw["command"].string ?? L10n.text("Выполнение команды", "Running command"))
        case "fileChange": return Self(id: id, kind: "activity", text: L10n.text("Изменение файлов · \(raw["status"].string ?? "")", "File changes · \(raw["status"].string ?? "")"))
        case "mcpToolCall": return Self(id: id, kind: "activity", text: raw["tool"].string ?? L10n.text("Вызов инструмента", "Calling tool"))
        default: return nil
        }
    }
    public static func merge(_ item: Self, into items: inout [Self]) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else if item.kind == "user", let index = items.firstIndex(where: {
            $0.kind == "user" && $0.id.hasPrefix("local-user:") && $0.text == item.text
        }) {
            items[index] = item
        } else { items.append(item) }
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var last: Int?
    public var window: Int?
    public var input: Int?
    public var cached: Int?
    public var output: Int?
    public var measuredAt: Date
    public init(event: JSONValue, date: Date = Date()) {
        let usage = event["tokenUsage"]
        last = usage["last"]["totalTokens"].int; window = usage["modelContextWindow"].int
        input = usage["total"]["inputTokens"].int; cached = usage["total"]["cachedInputTokens"].int
        output = usage["total"]["outputTokens"].int; measuredAt = date
    }
    public var contextFraction: Double? {
        guard let last, let window, last >= 0, window > 0 else { return nil }
        return min(1, Double(last) / Double(window))
    }
    public var uncached: Int? {
        guard let input, let cached, input >= cached else { return nil }; return input - cached
    }
}

public enum Locations {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Context Desk", isDirectory: true)
    }
    public static var codexHome: URL { root.appendingPathComponent("codex", isDirectory: true) }
    public static var automations: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/automations") }
    public static func codexExecutable() throws -> URL {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClientFailure(L10n.text("Codex не найден. Установи официальный Codex CLI или приложение ChatGPT.", "Codex was not found. Install the official Codex CLI or the ChatGPT app."))
        }
        return URL(fileURLWithPath: path)
    }
}
