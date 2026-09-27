import Foundation
import Darwin

/// Pinned print-mode adapter. Existing Claude authentication and permission rules are used in place.
public actor ClaudeJobRunner {
    public static let version = "2.1.260"
    private var process: Process?
    private var stopped = false
    public init() {}
    public static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/claude" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClientFailure(L10n.text("Установи Claude Code CLI и выполни вход через claude auth login.", "Install Claude Code CLI and sign in with claude auth login."))
        }
        return URL(fileURLWithPath: path)
    }
    public static func arguments(model: String) -> [String] {
        ["--print", "--output-format", "json", "--permission-mode", "dontAsk", "--permission-prompts", "none", "--no-session-persistence"]
            + (model.isEmpty ? [] : ["--model", model])
    }
    public func stop() {
        stopped = true
        if let process, process.isRunning { process.terminate() }
    }
    private func capture(executable: URL, arguments: [String], cwd: URL, prompt: String, timeout: TimeInterval) async throws -> (Int32, Data) {
        guard !stopped else { throw CancellationError() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("contextdesk-job-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input"), output = folder.appendingPathComponent("output"), errors = folder.appendingPathComponent("errors")
        try Data(prompt.utf8).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: input), stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let child = Process(); child.executableURL = executable; child.arguments = arguments; child.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        // Running Context Desk from an agent must not mark this independent print session as nested.
        environment.removeValue(forKey: "CLAUDECODE")
        environment["PATH"] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        try child.run(); process = child
        let deadline = Date().addingTimeInterval(timeout)
        var limited = false
        while child.isRunning {
            let bytes = [output, errors].reduce(0) { total, url in
                total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
            }
            if stopped || Task.isCancelled || Date() > deadline || bytes > 8 * 1024 * 1024 {
                limited = !stopped && !Task.isCancelled; child.terminate()
                try? await Task.sleep(for: .milliseconds(300))
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        process = nil
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        guard !limited else { throw ClientFailure(L10n.text("Запуск остановлен по лимиту времени или размера ответа; результат не подтверждён.", "The run exceeded the time or output limit; its outcome is unconfirmed.")) }
        let finalBytes = try [output, errors].reduce(0) { total, url in
            total + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        }
        guard finalBytes <= 8 * 1024 * 1024 else {
            throw ClientFailure(L10n.text("Ответ Claude Code превысил допустимый размер; результат не подтверждён.", "Claude Code output exceeded the size limit; its outcome is unconfirmed."))
        }
        let data = try Data(contentsOf: output)
        if child.terminationStatus != 0 && data.isEmpty {
            let detail = String(decoding: try Data(contentsOf: errors).prefix(16_000), as: UTF8.self)
            throw ClientFailure(L10n.text("Claude Code завершился с ошибкой. ", "Claude Code failed. ") + detail)
        }
        return (child.terminationStatus, data)
    }
    public func run(prompt: String, model: String, cwd: URL, executable: URL? = nil) async throws -> (JobRunStatus, String) {
        let executable = try executable ?? Self.executable()
        let (_, versionData) = try await capture(executable: executable, arguments: ["--version"], cwd: cwd, prompt: "", timeout: 15)
        guard String(decoding: versionData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == Self.version + " (Claude Code)" else {
            throw ClientFailure(L10n.text("Для заданий требуется проверенная версия Claude Code \(Self.version).", "Scheduled tasks require the verified Claude Code version \(Self.version)."))
        }
        let (code, bytes) = try await capture(executable: executable, arguments: Self.arguments(model: model), cwd: cwd, prompt: prompt, timeout: 3600)
        let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard value["type"].string == "result", value["is_error"].bool != nil, let text = value["result"].string ?? value["errors"].array.first?.string else {
            throw ClientFailure(L10n.text("Claude Code не вернул распознаваемый результат.", "Claude Code returned no recognized result."))
        }
        if !value["permission_denials"].array.isEmpty { return (.blocked, text) }
        return (code == 0 && value["is_error"].bool != true ? .completed : .failed, text)
    }
}
