import Foundation

/// App-owned MCP launch settings. Never edits either Codex home or project policy.
public enum BrowserConfiguration {
    public static var directory: URL { Locations.root.appendingPathComponent("browser", isDirectory: true) }

    public static func isInstalled(at root: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.json").path)
    }

    public static func arguments(enabled: Bool, resources: URL?, root: URL = directory,
                                 language: AppLanguage = L10n.language) throws -> [String] {
        let prefix = "mcp_servers.context_desk_browser"
        // No persistent MCP entry is written. Omitting our launch arguments is
        // sufficient when disabled; a transport-less disabled table is invalid.
        guard enabled else { return [] }
        guard let resources else {
            throw ClientFailure(L10n.text("Компонент браузера отсутствует в сборке приложения.", "The browser component is missing from this app build.", language: language))
        }
        let script = resources.appendingPathComponent("BrowserRuntime/server.py")
        guard FileManager.default.fileExists(atPath: script.path), isInstalled(at: root) else {
            throw ClientFailure(L10n.text("Сначала установи компонент Chrome DevTools по инструкции в настройках браузера.", "Install the Chrome DevTools component using the browser settings instructions first.", language: language))
        }
        let args = [script.path, "--root", root.path, "--language", language.rawValue]
        // JSON string/array literals are valid TOML here. They are passed as argv,
        // never shell source. No approval, sandbox or project-trust overrides.
        func encode<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        return [
            "\(prefix).command=\"/usr/bin/python3\"",
            "\(prefix).args=\(try encode(args))",
            "\(prefix).enabled=true",
            "\(prefix).startup_timeout_sec=30",
            "\(prefix).tool_timeout_sec=90"
        ].flatMap { ["-c", $0] }
    }
}
