import Foundation
import AgentContract
import ContextCore

/// Transitional command boundary for the existing application. Event/approval
/// normalization and AgentIntegration adoption are separate stage-3 work.
public actor CodexClient {
    private let transport: CodexConnection
    public nonisolated let events: AsyncStream<JSONValue>

    public init() {
        let transport = CodexConnection()
        self.transport = transport; events = transport.events
    }

    @_spi(NativeProtocol) public init(transport: CodexConnection) {
        self.transport = transport
        events = transport.events
    }

    public func start(executable: URL, home: URL, extraArguments: [String] = []) async throws {
        try await transport.start(executable: executable, home: home, extraArguments: extraArguments)
    }
    public func stop() async { await transport.stop() }

    public func account() async throws -> CodexAccount {
        let result = try await transport.request("account/read", params: .object(["refreshToken": .bool(false)]))
        return CodexAccount(authenticated: result["account"] != .null, plan: result["account"]["planType"].string)
    }
    public func signInURL() async throws -> URL {
        let result = try await transport.request("account/login/start", params: .object(["type": .string("chatgpt")]))
        guard let text = result["authUrl"].string, let url = URL(string: text),
              url.scheme == "https", let host = url.host,
              host == "chatgpt.com" || host == "auth.openai.com" || host.hasSuffix(".openai.com") else {
            throw ClientFailure(L10n.text("Движок не вернул допустимую ссылку входа", "The engine did not return a valid sign-in link"))
        }
        return url
    }
    public func signOut() async throws { _ = try await transport.request("account/logout") }
    public func models() async throws -> [CodexModel] {
        let result = try await transport.request("model/list", params: .object(["limit": .number(100), "includeHidden": .bool(false)]))
        return result["data"].array.compactMap(CodexModel.init)
    }
    public func limits() async throws -> AccountLimits {
        AccountLimits(response: try await transport.request("account/rateLimits/read"))
    }
    public func registerWorkflows(at directory: URL) async throws {
        _ = try await transport.request("skills/extraRoots/set", params: .object(["extraRoots": .array([.string(directory.path)])]))
    }

    public func createSession(projectPath: String, access: AccessMode, model: String, route: RequestRoute) async throws -> AgentSessionReference {
        var params = access.threadParameters
        params["cwd"] = .string(projectPath)
        params["modelProvider"] = .string(route.providerID)
        if !model.isEmpty { params["model"] = .string(model) }
        let result = try await transport.request("thread/start", params: .object(params))
        guard let id = result["thread"]["id"].string, !id.isEmpty else {
            throw ClientFailure(L10n.text("Не получен ID разговора", "No conversation ID received"))
        }
        return AgentSessionReference(connection: .originalCodex, nativeID: id)
    }
    public func resume(_ session: AgentSessionReference, projectPath: String, access: AccessMode, route: RequestRoute) async throws {
        var params = access.threadParameters
        params["threadId"] = .string(try nativeID(session))
        params["cwd"] = .string(projectPath)
        params["modelProvider"] = .string(route.providerID)
        _ = try await transport.request("thread/resume", params: .object(params))
    }
    /// Acknowledges submission only. Never retries after any transport failure.
    public func send(_ text: String, to session: AgentSessionReference, projectPath: String,
                     access: AccessMode, model: String, effort: String) async throws -> String? {
        var params: [String: JSONValue] = [
            "threadId": .string(try nativeID(session)),
            "input": .array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])])
        ]
        params.merge(access.turnParameters(projectPath: projectPath)) { _, new in new }
        if !model.isEmpty { params["model"] = .string(model) }
        if !effort.isEmpty { params["effort"] = .string(effort) }
        return try await transport.request("turn/start", params: .object(params), timeout: 60)["turn"]["id"].string
    }
    public func interrupt(_ session: AgentSessionReference, turn: String) async throws {
        _ = try await transport.request("turn/interrupt", params: .object([
            "threadId": .string(try nativeID(session)), "turnId": .string(turn)
        ]))
    }
    public func rename(_ session: AgentSessionReference, title: String) async throws {
        _ = try await transport.request("thread/name/set", params: .object([
            "threadId": .string(try nativeID(session)), "name": .string(title)
        ]))
    }
    public func setArchived(_ archived: Bool, session: AgentSessionReference) async throws {
        _ = try await transport.request(archived ? "thread/archive" : "thread/unarchive",
                                       params: .object(["threadId": .string(try nativeID(session))]))
    }
    public func delete(_ session: AgentSessionReference) async throws {
        _ = try await transport.request("thread/delete", params: .object(["threadId": .string(try nativeID(session))]))
    }
    public func history(_ session: AgentSessionReference) async throws -> [CodexHistoryTurn] {
        try await read(session)["turns"].array.map(CodexHistoryTurn.init)
    }
    public func summarySource(_ session: AgentSessionReference) async throws -> SummarySource {
        try await SummarySource(thread: read(session))
    }
    private func read(_ session: AgentSessionReference) async throws -> JSONValue {
        let id = try nativeID(session)
        let result = try await transport.request("thread/read", params: .object([
            "threadId": .string(id), "includeTurns": .bool(true)
        ]))
        guard result["thread"]["id"].string == id else {
            throw ClientFailure(L10n.text("Получена история другого чата", "Received history for a different chat"))
        }
        guard case .array = result["thread"]["turns"] else {
            throw ClientFailure(L10n.text("История чата недоступна", "Conversation history is unavailable"))
        }
        return result["thread"]
    }
    private func nativeID(_ session: AgentSessionReference) throws -> String {
        guard session.connection == .originalCodex, !session.nativeID.isEmpty else { throw ConversationIdentity.unavailable }
        return session.nativeID
    }

    // Temporary bridge: remove when event and approval normalization is migrated.
    public func answer(id: JSONValue, result: JSONValue) async throws { try await transport.answer(id: id, result: result) }
    public func rejectUnknown(id: JSONValue) async throws { try await transport.rejectUnknown(id: id) }
}

public struct CodexAccount: Sendable {
    public let authenticated: Bool
    public let plan: String?
}

public struct CodexModel: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let defaultEffort: String
    public let efforts: [String]

    public init(id: String, displayName: String, isDefault: Bool = false, defaultEffort: String = "", efforts: [String] = []) {
        self.id = id; self.displayName = displayName; self.isDefault = isDefault
        self.defaultEffort = defaultEffort; self.efforts = efforts
    }
    init?(_ value: JSONValue) {
        guard let id = value["model"].string, !id.isEmpty else { return nil }
        self.init(id: id, displayName: value["displayName"].string ?? id,
                  isDefault: value["isDefault"].bool == true,
                  defaultEffort: value["defaultReasoningEffort"].string ?? "",
                  efforts: value["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string })
    }
}

public struct CodexHistoryTurn: Sendable {
    public let id: String?
    public let items: [TranscriptItem]
    private let startedAt: Date?
    private let completedAt: Date?
    private let duration: Double?

    init(_ turn: JSONValue) {
        id = turn["id"].string
        items = turn["items"].array.compactMap(TranscriptItem.parse)
        startedAt = turn["startedAt"].int.map { Date(timeIntervalSince1970: Double($0)) }
        completedAt = turn["completedAt"].int.map { Date(timeIntervalSince1970: Double($0)) }
        duration = turn["durationMs"].int.flatMap { $0 >= 0 ? Double($0) / 1_000 : nil }
    }
    public func timing(fallback: ResponseTiming?) -> ResponseTiming? {
        guard let completedAt = completedAt ?? fallback?.completedAt else { return nil }
        return ResponseTiming(startedAt: startedAt ?? fallback?.startedAt, completedAt: completedAt,
                              durationSeconds: duration ?? fallback?.durationSeconds, tokens: fallback?.tokens)
    }
}
