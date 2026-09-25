import Foundation

/// One process and one ordered JSONL stream. Never retries model turns.
public actor CodexConnection {
    public nonisolated let events: AsyncStream<JSONValue>
    private let eventSink: AsyncStream<JSONValue>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var sequence = 0
    private var generation = UUID()
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var reader: Task<Void, Never>?

    public init() {
        let pair = AsyncStream<JSONValue>.makeStream()
        events = pair.stream; eventSink = pair.continuation
    }

    public func start(executable: URL, home: URL, extraArguments: [String] = []) async throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let token = UUID(); generation = token
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\"",
                           "-c", "analytics.enabled=false"] + extraArguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        // Account login belongs to this app, even when started from a configured shell.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] {
            environment.removeValue(forKey: key)
        }
        child.environment = environment
        child.currentDirectoryURL = home
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        let chunks = AsyncStream<Data>.makeStream()
        stdout.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { chunks.continuation.finish() }
            else { chunks.continuation.yield(data) }
        }
        // Drain diagnostics without storing prompts, credentials or raw server logs.
        stderr.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        child.terminationHandler = { [weak self] child in
            Task { await self?.terminated(token: token, status: child.terminationStatus) }
        }
        do { try child.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child; input = stdin.fileHandleForWriting; outputPipe = stdout; errorPipe = stderr
        reader = Task { [weak self] in
            for await data in chunks.stream { await self?.ingest(data, token: token) }
        }
        do {
            _ = try await request("initialize", params: .object([
                "clientInfo": .object(["name": .string("context_desk"), "title": .string("Context Desk"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            try send(.object(["method": .string("initialized"), "params": .object([:])]))
        } catch { stop(); throw error }
    }

    public func request(_ method: String, params: JSONValue = .object([:]), timeout: UInt64 = 30) async throws -> JSONValue {
        guard process?.isRunning == true else { throw ClientFailure(L10n.text("Codex не подключён", "Codex is not connected")) }
        sequence += 1; let id = String(sequence)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.object(["id": .string(id), "method": .string(method), "params": params]))
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                    await self?.expired(id, method: method)
                }
            } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    public func answer(id: JSONValue, result: JSONValue) throws {
        try send(.object(["id": id, "result": result]))
    }
    public func rejectUnknown(id: JSONValue) throws {
        try send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("Unsupported client request")])]))
    }
    private func send(_ value: JSONValue) throws {
        guard let input else { throw ClientFailure(L10n.text("Соединение закрыто", "Connection closed")) }
        var bytes = try JSONEncoder().encode(value); bytes.append(10)
        try input.write(contentsOf: bytes)
    }
    private func ingest(_ data: Data, token: UUID) {
        guard token == generation else { return }
        buffer.append(data)
        guard buffer.count <= 32 * 1024 * 1024 else {
            eventSink.yield(.object(["method": .string("client/error"), "params": .object(["message": .string(L10n.text("Ответ движка превышает допустимый размер", "The engine response exceeds the size limit"))])]))
            stop(); return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            if message["method"].string != nil { eventSink.yield(message); continue }
            guard let id = message["id"].string, let c = pending.removeValue(forKey: id) else { continue }
            timeouts.removeValue(forKey: id)?.cancel()
            if message["error"] != .null {
                c.resume(throwing: ClientFailure(message["error"]["message"].string ?? L10n.text("Ошибка протокола", "Protocol error")))
            } else { c.resume(returning: message["result"]) }
        }
    }
    private func expired(_ id: String, method: String) {
        timeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: ClientFailure(L10n.text("Истекло время ожидания \(method). Запрос не повторён автоматически.", "\(method) timed out. The request was not retried automatically.")))
        if method == "turn/start" || method == "turn/steer" {
            stop()
            eventSink.yield(.object(["method": .string("client/disconnected"), "params": .object([:])]))
        }
    }
    private func terminated(token: UUID, status: Int32) {
        guard generation == token else { return }
        cleanUp()
        eventSink.yield(.object(["method": .string("client/disconnected"), "params": .object(["status": .number(Double(status))])]))
    }
    public func stop() {
        let child = process
        generation = UUID()
        cleanUp()
        if child?.isRunning == true { child?.terminate() }
    }
    private func cleanUp() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? input?.close(); input = nil
        reader?.cancel(); reader = nil; buffer.removeAll()
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        let waiting = pending.values; pending.removeAll()
        for c in waiting { c.resume(throwing: ClientFailure(L10n.text("Соединение с Codex закрыто", "The connection to Codex is closed"))) }
        process = nil; outputPipe = nil; errorPipe = nil
    }
}
