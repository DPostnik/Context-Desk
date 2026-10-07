import Foundation
import Darwin
import ContextCore
import AgentContract

/// Interactive CLI integration using an app-owned configuration/credential namespace.
public actor ClaudeIntegration: AgentIntegration {
    public nonisolated let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation
    private var context = AgentContext(connection: .appClaude, accountRevision: UUID())
    private var home: URL?
    private var executable: URL?
    private var signedIn = false
    private var accountIdentity: String?
    private var sessions: [String: Session] = [:]
    private var wires: [String: ClaudeWire] = [:]
    private var readers: [String: Task<Void, Never>] = [:]
    private var consumed = Set<UUID>()
    private var submitting = Set<String>()
    private var seenRequests: [String: Set<String>] = [:]
    private struct Session: Codable {
        var version = 1
        let id: String
        let cwd: String
        var access: AccessMode
        var sent = false
        var active: String?
        var turns: [AgentHistoryTurn] = []
        var current: [TranscriptItem] = []
        var tokens: TokenCounters?
        var contextWindow: Int?
        var lastContext: Int?
    }
    private struct Interaction {
        let session: String
        let requestID: String
        let input: JSONValue
        let questions: Set<String>?
        let epoch: UUID
    }
    private var interactions: [UUID: Interaction] = [:]
    private var interrupted = Set<String>()
    private var messageIDs: [String: String] = [:]
    private var meters: [String: ClaudeUsageMeter] = [:]
    public init() { let stream = AsyncStream<AgentEvent>.makeStream(); events = stream.stream; sink = stream.continuation }
    public func optimizerEnvironment(home: URL) -> AgentResult<[String: String]> { .rejected(.routeUnavailable) }
    public func connect(_ configuration: AgentConnectionConfiguration) async -> AgentResult<AgentDescriptor> {
        guard configuration.optimizers.isEmpty, !configuration.browserEnabled else { return .rejected(.routeUnavailable) }
        await disconnect()
        do {
            let binary = try configuration.executable ?? ClaudeJobRunner.executable()
            try FileManager.default.createDirectory(at: configuration.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let (code, version) = try await ClaudeProfile.command(executable: binary, home: configuration.home, arguments: ["--version"])
            guard code == 0, String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == ClaudeJobRunner.version + " (Claude Code)" else { return .rejected(.incompatibleContract) }
            home = configuration.home; executable = binary
            context = .init(connection: .appClaude, accountRevision: UUID())
            _ = await account()
            return descriptor()
        } catch { return failed(error) }
    }
    public func descriptor() -> AgentResult<AgentDescriptor> {
        guard home != nil, executable != nil else { return .unavailable }
        return .success(.init(context: context, identityMode: .appOwnedHome,
            capabilities: [.interactiveSessions, .history, .streaming, .usage, .approvals, .userQuestions, .interruption, .authenticationManagement, .archive],
            permissions: .claudeRestrictedFiles, routes: [.direct]))
    }
    public func observe(sessions: [AgentSessionReference]) {}
    public func disconnect() async {
        for wire in wires.values { await wire.close() }
        for id in Array(wires.keys) { finish(id, outcome: .uncertain) }
        wires.removeAll(); readers.removeAll(); interactions.removeAll(); seenRequests.removeAll()
        sessions.removeAll(); messageIDs.removeAll(); interrupted.removeAll(); meters.removeAll()
        home = nil; executable = nil; signedIn = false; accountIdentity = nil
        context = .init(connection: .appClaude, accountRevision: UUID())
    }
    public func account() async -> AgentResult<AgentAccountInfo> {
        guard let home, let executable else { return .unavailable }
        let epoch = context
        signedIn = false
        do {
            let (_, data) = try await ClaudeProfile.command(executable: executable, home: home, arguments: ["auth", "status", "--json"])
            guard context == epoch else { return .rejected(.staleContext) }
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let loggedIn = value["loggedIn"].bool else { return .rejected(.invalidResponse) }
            // Only the isolated first-party account is supported; never inherit alternate API routes.
            signedIn = loggedIn && value["apiProvider"].string == "firstParty"
            let identity = signedIn ? [value["email"].string ?? "", value["orgId"].string ?? "", value["authMethod"].string ?? ""].joined(separator: "|") : "signed-out"
            if let previous = accountIdentity, previous != identity {
                for wire in wires.values { await wire.close() }
                for id in Array(wires.keys) { finish(id, outcome: .uncertain) }
                wires.removeAll(); interactions.removeAll()
                context = .init(connection: .appClaude, accountRevision: UUID())
                sink.yield(.init(session: nil, payload: .accountChanged(error: nil)))
            }
            accountIdentity = identity
            return .success(.init(authenticated: signedIn, plan: nil))
        } catch { signedIn = false; return failed(error) }
    }
    public func authenticate(_ action: AgentAuthenticationAction) async -> AgentResult<AgentAuthenticationStep> {
        guard let home, let executable, submitting.isEmpty, sessions.values.allSatisfy({ $0.active == nil }) else { return .unavailable }
        do {
            switch action {
            case .beginSignIn:
                func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let path = home.appendingPathComponent("Sign in to Claude.command")
                let env = ClaudeProfile.environment(home: home).sorted { $0.key < $1.key }.map { quote($0.key + "=" + $0.value) }.joined(separator: " ")
                let script = "#!/bin/zsh\ncd " + quote(home.path) + " || exit 1\nexec /usr/bin/env -i " + env + " " + quote(executable.path) + " auth login --claudeai\n"
                try Data(script.utf8).write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
                return .success(.openLocalSignIn(path))
            case .signOut:
                let (code, _) = try await ClaudeProfile.command(executable: executable, home: home, arguments: ["auth", "logout"])
                guard code == 0 else { return .rejected(.invalidResponse) }
                _ = await account(); return .success(.complete)
            }
        } catch { return failed(error) }
    }
    public func models() -> AgentResult<[AgentModelInfo]> { .rejected(.unsupported(.modelDiscovery)) }
    public func limits() -> AgentResult<AccountLimits> { .rejected(.unsupported(.accountLimits)) }
    public func configure(_ tools: AgentToolConfiguration, context: AgentContext) -> AgentResult<Void> { .rejected(.unsupported(.toolRegistration)) }
    private func validate(_ request: AgentExecutionRequest) -> AgentRejection? {
        guard case .success(let descriptor) = descriptor() else { return .staleContext }
        if let rejection = descriptor.validate(request) { return rejection }
        guard ClaudeEffort.isDispatchable(request.model.effort), request.kind == .interactive else { return .invalidInput }
        return nil
    }
    public func prepare(_ request: AgentExecutionRequest) -> AgentResult<AgentSessionReference> {
        if let issue = validate(request) { return .rejected(issue) }
        guard signedIn else { return .unavailable }
        do {
            let id = request.session?.nativeID ?? UUID().uuidString
            guard UUID(uuidString: id) != nil else { return .rejected(.invalidInput) }
            let access: AccessMode = { if case .unrestricted = request.permissions { return .fullAccess }; return .standard }()
            if request.session != nil {
                let old = try load(id)
                guard old.cwd == request.projectPath, !submitting.contains(id), wires[id] == nil || old.active == nil else { return .rejected(.unsupportedPermissions) }
                // A fresh explicit user submission may continue native history; old work is never resent.
                if old.active != nil { finish(id, outcome: .uncertain) }
                sessions[id]?.access = access; try save(id)
            } else {
                sessions[id] = Session(id: id, cwd: request.projectPath, access: access); try save(id)
            }
            return .success(reference(id))
        } catch { return failed(error) }
    }
    public func submit(_ request: AgentExecutionRequest) async -> AgentResult<AgentExecutionHandle> {
        if let issue = validate(request) { return .rejected(issue) }
        guard consumed.insert(request.id).inserted else { return .rejected(.unknownRequest) }
        guard let id = request.session?.nativeID, let executable, let home, signedIn else { return .unavailable }
        guard submitting.insert(id).inserted else { return .rejected(.invalidInput) }
        defer { submitting.remove(id) }
        var delivered = false
        do {
            let record = try load(id)
            guard record.active == nil, record.cwd == request.projectPath else { return .rejected(.invalidInput) }
            let expectedAccess: AccessMode = { if case .unrestricted = request.permissions { return .fullAccess }; return .standard }()
            sessions[id]?.access = expectedAccess
            _ = try await account().value()
            guard request.model.context == context, signedIn else { return .rejected(.staleContext) }
            let wire: ClaudeWire
            if let current = wires[id] { wire = current }
            else {
                wire = ClaudeWire()
                let arguments = Self.arguments(id: id, resumed: record.sent, access: expectedAccess,
                                               model: request.model.model, effort: request.model.effort)
                try await wire.start(executable: executable, arguments: arguments, environment: ClaudeProfile.environment(home: home), cwd: URL(fileURLWithPath: record.cwd))
                wires[id] = wire
                seenRequests[id] = []
                readers[id] = Task { [weak self] in for await value in wire.frames { await self?.receive(value, session: id, wire: wire) } }
                _ = try await wire.control(.object(["subtype": .string("initialize"), "hooks": .null]))
            }
            guard request.model.context == context, signedIn, wires[id] === wire else { await wire.close(); return .rejected(.staleContext) }
            let turn = request.id.uuidString
            sessions[id]?.active = turn; sessions[id]?.sent = true; sessions[id]?.current = []
            try save(id) // Durable uncertain claim before a byte of the user turn is sent.
            delivered = true
            let meter = ClaudeUsageMeter(base: record.tokens, window: record.contextWindow, last: record.lastContext)
            meters[id] = meter
            // Turn-less report: the cumulative baseline for this turn's response tokens.
            sink.yield(.init(session: reference(id), payload: .usage(turn: nil, total: meter.total, snapshot: meter.snapshot())))
            sink.yield(.init(session: reference(id), payload: .started(turn: turn)))
            emit(TranscriptItem(id: "user:" + turn, kind: "user", text: request.prompt), session: id)
            try await wire.send(.object(["type": .string("user"), "session_id": .string(id), "uuid": .string(UUID().uuidString),
                "message": .object(["role": .string("user"), "content": .string(request.prompt)])]))
            return .success(.init(context: context, requestID: request.id, session: reference(id), turnID: turn))
        } catch {
            if delivered { finish(id, outcome: .uncertain) }
            if let wire = wires.removeValue(forKey: id) { await wire.close() }
            return failed(error, uncertain: delivered)
        }
    }
    static func arguments(id: String, resumed: Bool, access: AccessMode, model: String, effort: String?) -> [String] {
        var args = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--permission-prompt-tool", "stdio", "--setting-sources", "", "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    resumed ? "--resume" : "--session-id", id]
        if access == .standard {
            args += ["--restricted", "--tools", "Read,Glob,Grep,Write,Edit,AskUserQuestion", "--permission-mode", "default"]
        } else { args += ["--permission-mode", "bypassPermissions"] }
        if !model.isEmpty { args += ["--model", model] }
        // Only a documented level is forwarded; an unset value leaves the CLI default in place.
        if let level = ClaudeEffort.accepted(effort) { args += ["--effort", level.rawValue] }
        args += ["--append-system-prompt", AgentAutonomy.instructions()]
        return args
    }
    public func cancel(_ execution: AgentExecutionHandle) async -> AgentResult<AgentCancellation> {
        guard execution.context == context, let id = execution.session?.nativeID,
              execution.session?.connection == .appClaude, sessions[id]?.active == execution.turnID,
              let wire = wires[id] else { return .rejected(.unknownRequest) }
        interrupted.insert(id)
        do { _ = try await wire.control(.object(["subtype": .string("interrupt")])) }
        catch { await wire.close(); return .success(.uncertain) }
        let turn = execution.turnID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.expireInterrupt(session: id, turn: turn, wire: wire)
        }
        return .success(.requested)
    }
    private func expireInterrupt(session: String, turn: String?, wire: ClaudeWire) async {
        if wires[session] === wire, sessions[session]?.active == turn { await wire.close() }
    }
    public func answer(_ id: UUID, session: AgentSessionReference, context: AgentContext, response: AgentInteractionResponse) async -> AgentResult<Void> {
        guard context == self.context, session.connection == .appClaude, let interaction = interactions[id], interaction.session == session.nativeID,
              interaction.epoch == context.accountRevision, let wire = wires[interaction.session] else { return .rejected(.unknownRequest) }
        var result: JSONValue
        switch response {
        case .deny: result = .object(["behavior": .string("deny"), "message": .string(L10n.text("Отклонено пользователем", "Denied by user"))])
        case .allowOnce:
            guard interaction.questions == nil else { return .rejected(.invalidResponse) }
            result = .object(["behavior": .string("allow"), "updatedInput": interaction.input])
        case .answers(let answers):
            guard let questions = interaction.questions, Set(answers.keys) == questions else { return .rejected(.invalidResponse) }
            var input = interaction.input.object; input["answers"] = .object(answers.mapValues(JSONValue.string))
            result = .object(["behavior": .string("allow"), "updatedInput": .object(input)])
        case .completed: return .rejected(.invalidResponse)
        }
        interactions.removeValue(forKey: id)
        do {
            try await respond(wire, requestID: interaction.requestID, response: result)
            sink.yield(.init(session: session, payload: .resolved(id))); return .success(())
        } catch { await wire.close(); return failed(error, uncertain: true) }
    }
    public func rejectInteraction(_ id: UUID) async {
        guard let interaction = interactions[id] else { return }
        _ = await answer(id, session: reference(interaction.session), context: context, response: .deny)
    }
    private func receive(_ value: JSONValue, session id: String, wire: ClaudeWire) async {
        guard wires[id] === wire else { return }
        if let native = value["session_id"].string, native != id { await wire.close(); return }
        switch value["type"].string {
        case "transport_closed":
            wires.removeValue(forKey: id); finish(id, outcome: .uncertain)
        case "control_request": await permission(value, session: id, wire: wire)
        case "stream_event":
            guard let turn = sessions[id]?.active else { return }
            let event = value["event"], main = value["parent_tool_use_id"].string == nil
            if event["type"].string == "message_start", let message = event["message"]["id"].string {
                messageIDs[id] = message
                if main { meters[id]?.current = message; observeUsage(event["message"]["usage"], message: message, session: id, turn: turn) }
            }
            if event["type"].string == "message_delta", main, let message = meters[id]?.current {
                observeUsage(event["usage"], message: message, session: id, turn: turn)
            }
            if event["type"].string == "content_block_delta", event["delta"]["type"].string == "text_delta",
               let text = event["delta"]["text"].string, let message = messageIDs[id] {
                sink.yield(.init(session: reference(id), payload: .delta(turn: turn, item: message, text: text)))
            }
        case "assistant":
            guard let turn = sessions[id]?.active else { return }
            let message = value["message"], parts = message["content"].array
            if value["parent_tool_use_id"].string == nil, let key = message["id"].string {
                observeUsage(message["usage"], message: key, session: id, turn: turn)
            }
            let text = parts.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
            if !text.isEmpty, let key = message["id"].string { emit(.init(id: key, kind: "assistant", text: text), session: id) }
            for part in parts where part["type"].string == "tool_use" {
                if let key = part["id"].string { emit(.init(id: key, kind: "activity", text: (part["name"].string ?? "") + "\n" + part["input"].display), session: id) }
            }
        case "user":
            for part in value["message"]["content"].array where part["type"].string == "tool_result" {
                if let key = part["tool_use_id"].string { emit(.init(id: key + ":result", kind: "activity", text: part["content"].display), session: id) }
            }
        case "result":
            guard value["session_id"].string == id, value["is_error"].bool != nil else { await wire.close(); return }
            wires.removeValue(forKey: id)
            if let turn = sessions[id]?.active, var meter = meters[id] {
                meter.complete(result: value); meters[id] = meter
                sink.yield(.init(session: reference(id), payload: .usage(turn: turn, total: meter.total, snapshot: meter.snapshot())))
            }
            finish(id, outcome: interrupted.contains(id) ? .cancelled : value["is_error"].bool == true ? .failed : .completed)
            await wire.close()
        case "system":
            if value["subtype"].string == "init", let model = value["model"].string { meters[id]?.model = model }
        default: break // Notifications are data; only recognized control requests can obtain an answer.
        }
    }
    private func permission(_ value: JSONValue, session id: String, wire: ClaudeWire) async {
        guard let requestID = value["request_id"].string else { await wire.close(); return }
        guard seenRequests[id, default: []].insert(requestID).inserted else { await wire.close(); return }
        let request = value["request"], input = request["input"], name = request["tool_name"].string ?? ""
        guard request["subtype"].string == "can_use_tool" else { await wire.close(); return }
        guard let turn = sessions[id]?.active,
              ["Read", "Glob", "Grep", "Write", "Edit", "Bash", "AskUserQuestion"].contains(name) else {
            try? await respond(wire, requestID: requestID, response: .object(["behavior": .string("deny"), "message": .string(L10n.text("Неподдерживаемый запрос", "Unsupported request"))]))
            return
        }
        if sessions[id]?.access == .standard {
            let outside: Bool
            if let path = input["file_path"].string ?? input["path"].string, let cwd = sessions[id]?.cwd {
                outside = !Self.isWithinProject(path, cwd: cwd)
            } else { outside = false }
            if name == "Bash" || outside {
                try? await respond(wire, requestID: requestID, response: .object(["behavior": .string("deny"), "message": .string(L10n.text("Действие выходит за разрешённые границы проекта", "Outside the supported project restrictions"))]))
                return
            }
        }
        var questions: Set<String>?
        let kind: AgentInteraction.Kind
        if name == "AskUserQuestion" {
            let fields = input["questions"].array.compactMap { question -> AgentInteraction.Field? in
                guard question["multiSelect"].bool != true, let text = question["question"].string, !text.isEmpty else { return nil }
                return .init(id: text, text: text, options: question["options"].array.compactMap { $0["label"].string }, secret: false, required: true)
            }
            guard !fields.isEmpty, fields.count <= 16, fields.count == input["questions"].array.count, Set(fields.map(\.id)).count == fields.count else {
                try? await respond(wire, requestID: requestID, response: .object(["behavior": .string("deny"), "message": .string(L10n.text("Неподдерживаемая схема вопроса", "Unsupported question schema"))]))
                return
            }
            questions = Set(fields.map(\.id)); kind = .questions(fields)
        } else { kind = .approval(canAllow: true) }
        let token = UUID()
        interactions[token] = .init(session: id, requestID: requestID, input: input, questions: questions, epoch: context.accountRevision)
        sink.yield(.init(session: reference(id), payload: .interaction(.init(id: token, session: reference(id), turn: turn,
            kind: kind, reason: name, details: input.display))))
    }
    /// Resolve existing ancestors through POSIX, including /var versus /private/var.
    /// Missing leaf components are allowed; inaccessible paths and dangling symlinks fail closed.
    static func isWithinProject(_ path: String, cwd: String) -> Bool {
        func canonical(_ raw: String) -> String? {
            guard raw.hasPrefix("/"), !raw.utf8.contains(0) else { return nil }
            var candidate = raw, suffix: [String] = []
            for _ in 0..<256 {
                if let resolved = realpath(candidate, nil) {
                    defer { free(resolved) }
                    let base = String(cString: resolved)
                    return suffix.reversed().reduce(base) { ($0 as NSString).appendingPathComponent($1) }
                }
                guard errno == ENOENT, candidate != "/",
                      (try? FileManager.default.attributesOfItem(atPath: candidate)[.type] as? FileAttributeType) != .typeSymbolicLink else { return nil }
                let leaf = (candidate as NSString).lastPathComponent
                guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return nil }
                suffix.append(leaf); candidate = (candidate as NSString).deletingLastPathComponent
            }
            return nil
        }
        guard let root = canonical(cwd), let target = canonical(path.hasPrefix("/") ? path : cwd + "/" + path) else { return false }
        return target == root || target.hasPrefix(root == "/" ? "/" : root + "/")
    }
    private func respond(_ wire: ClaudeWire, requestID: String, response: JSONValue) async throws {
        try await wire.send(.object(["type": .string("control_response"), "response": .object([
            "subtype": .string("success"), "request_id": .string(requestID), "response": response])]))
    }
    private func observeUsage(_ usage: JSONValue, message: String, session id: String, turn: String) {
        guard var meter = meters[id], meter.observe(message: message, usage: usage) else { return }
        meters[id] = meter
        sink.yield(.init(session: reference(id), payload: .usage(turn: turn, total: meter.total, snapshot: meter.snapshot())))
    }
    private func emit(_ value: TranscriptItem, session id: String) {
        guard let turn = sessions[id]?.active else { return }
        var item = value; item.turnID = turn; item.agentName = "Claude"
        TranscriptItem.merge(item, into: &sessions[id]!.current)
        do { try save(id) } catch {
            sink.yield(.init(session: reference(id), payload: .diagnostic(error.localizedDescription)))
            if let wire = wires[id] { Task { await wire.close() } }
        }
        sink.yield(.init(session: reference(id), payload: .item(item)))
    }
    private func finish(_ id: String, outcome: AgentExecutionOutcome) {
        guard let turn = sessions[id]?.active else { return }
        let history = AgentHistoryTurn(id: turn, items: sessions[id]?.current ?? [], startedAt: nil, completedAt: Date(), duration: nil, isComplete: false)
        sessions[id]?.turns.append(history); sessions[id]?.active = nil; sessions[id]?.current = []
        if var meter = meters.removeValue(forKey: id) {
            meter.abandon() // No-op after a terminal result; otherwise observed calls still count.
            sessions[id]?.tokens = meter.base; sessions[id]?.contextWindow = meter.window; sessions[id]?.lastContext = meter.last
        }
        interrupted.remove(id)
        for (token, value) in interactions where value.session == id {
            interactions.removeValue(forKey: token); sink.yield(.init(session: reference(id), payload: .resolved(token)))
        }
        do { try save(id) } catch { sink.yield(.init(session: reference(id), payload: .diagnostic(error.localizedDescription))) }
        sink.yield(.init(session: reference(id), payload: .completed(.init(id: turn, status: outcome, hasError: outcome == .failed || outcome == .uncertain,
            error: outcome == .uncertain ? L10n.text("Результат Claude неизвестен. Проверь историю перед новой отправкой; повторов не было.", "Claude's outcome is uncertain. Review history before sending again; nothing was retried.") : nil, history: history))))
    }
    private func reference(_ id: String) -> AgentSessionReference { .init(connection: .appClaude, nativeID: id) }
    private func file(_ id: String) throws -> URL {
        guard let home, UUID(uuidString: id) != nil else { throw ConversationIdentity.unavailable }
        return home.appendingPathComponent("contextdesk-sessions").appendingPathComponent(id + ".json")
    }
    private func load(_ id: String) throws -> Session {
        if let value = sessions[id] { return value }
        let value = try JSONDecoder().decode(Session.self, from: Data(contentsOf: file(id)))
        guard value.version == 1, value.id == id else { throw ConversationIdentity.invalidStorage }
        sessions[id] = value; return value
    }
    private func save(_ id: String) throws {
        let path = try file(id)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(sessions[id]).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private func checked(_ session: AgentSessionReference, context: AgentContext) -> Bool {
        session.connection == .appClaude && context == self.context && home != nil
    }
    public func history(_ session: AgentSessionReference, context: AgentContext) -> AgentResult<[AgentHistoryTurn]> {
        guard checked(session, context: context) else { return .rejected(.wrongConnection) }
        do {
            let value = try load(session.nativeID)
            return .success(value.turns + (value.active.map { [.init(id: $0, items: value.current, startedAt: nil, completedAt: nil, duration: nil)] } ?? []))
        } catch { return failed(error) }
    }
    public func rename(_ session: AgentSessionReference, title: String, context: AgentContext) -> AgentResult<Void> { checked(session, context: context) ? .success(()) : .rejected(.wrongConnection) }
    public func setArchived(_ archived: Bool, session: AgentSessionReference, context: AgentContext) -> AgentResult<Void> { checked(session, context: context) ? .success(()) : .rejected(.wrongConnection) }
    public func delete(_ session: AgentSessionReference, context: AgentContext) async -> AgentResult<Void> {
        guard checked(session, context: context), sessions[session.nativeID]?.active == nil else { return .rejected(.wrongConnection) }
        if let wire = wires.removeValue(forKey: session.nativeID) { await wire.close() }
        // Native execution files stay in the isolated engine home; app deletion only hides the chat.
        return .success(())
    }
    public func summarySource(_ session: AgentSessionReference, context: AgentContext) -> AgentResult<AgentSummarySource> { .rejected(.unsupported(.isolatedGeneration)) }
    public func generate(_ request: AgentGenerationRequest, environment: AgentGenerationEnvironment, willStart: @escaping @Sendable () async throws -> Void) -> AgentResult<AgentGenerationOutput> { .rejected(.unsupported(.isolatedGeneration)) }
    public func cancelGeneration(_ id: UUID) {}
    private func failed<T: Sendable>(_ error: any Error, uncertain: Bool = false) -> AgentResult<T> { .failed(.init(delivery: uncertain ? .uncertain : .notSent, diagnostic: error.localizedDescription)) }
}
