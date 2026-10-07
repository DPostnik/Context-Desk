import Foundation
import ContextCore
import AgentContract

/// Plan rate limits read through the CLI's `get_usage` control request (2.1.292, experimental shape).
///
/// The probe is a short-lived stream-json process in the app-owned profile: it sends only
/// `initialize` and `get_usage`, never a user turn, persists no session and loads no tools,
/// settings, MCP servers or slash commands. The CLI reads the claude.ai usage endpoint with the
/// profile's own credentials; nothing is copied out of the profile.
enum ClaudeLimits {
    static let arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                            "--no-session-persistence", "--tools", "", "--safe-mode", "--setting-sources", "",
                            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--disable-slash-commands",
                            "--no-chrome", "--permission-mode", "dontAsk"]
    /// `skip_behaviors` avoids scanning seven days of local transcripts; only plan limits are needed.
    static let request: JSONValue = .object(["subtype": .string("get_usage"), "skip_behaviors": .bool(true)])

    private static let week = 7 * 24 * 60

    /// `nil` when the account has no plan limits (signed out, API key or missing profile scope).
    static func decode(_ response: JSONValue, at date: Date = Date()) -> AccountLimits? {
        let limits = response["rate_limits"]
        guard response["rate_limits_available"].bool == true, case .object = limits else { return nil }
        var buckets: [LimitBucket] = []
        func bucket(_ id: String, _ name: String, _ windows: [(String, Int)]) {
            let decoded = windows.compactMap { key, minutes in window(key, limits[key], minutes: minutes) }
            if !decoded.isEmpty { buckets.append(.init(id: id, name: name, windows: decoded)) }
        }
        bucket("all", L10n.text("Все модели", "All models"), [("five_hour", 300), ("seven_day", week)])
        bucket("sonnet", "Sonnet", [("seven_day_sonnet", week)])
        bucket("opus", "Opus", [("seven_day_opus", week)])
        for (index, entry) in limits["model_scoped"].array.enumerated() {
            guard let name = entry["display_name"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let value = window("model_scoped", entry, minutes: week) else { continue }
            buckets.append(.init(id: "model:\(index):" + name, name: String(name.prefix(128)), windows: [value]))
        }
        bucket("oauth_apps", L10n.text("Сторонние приложения", "Third-party apps"), [("seven_day_oauth_apps", week)])
        return AccountLimits(buckets: buckets, ordinaryUsageAllowed: nil, fetchedAt: date)
    }

    /// An absent or null window does not apply to the plan; a present one with unknown use stays visible.
    private static func window(_ id: String, _ value: JSONValue, minutes: Int) -> LimitWindow? {
        guard case .object = value else { return nil }
        var used: Int?
        if case .number(let percent) = value["utilization"], percent.isFinite { used = Int(min(100, max(0, percent)).rounded(.down)) }
        return LimitWindow(id: id, remainingPercent: used.map { 100 - $0 }, durationMinutes: minutes,
                           resetsAt: value["resets_at"].string.flatMap(date))
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
