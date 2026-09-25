import Foundation
import TOMLDecoder

public struct ScheduledJob: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var status: String
    public var kind: String
    public var schedule: String
    public var prompt: String
    public var targetThread: String?
    public var issue: String?
}

public enum ScheduledJobs {
    private struct Definition: Decodable {
        var version: Int?
        var id: String
        var name: String
        var status: String?
        var kind: String?
        var rrule: String?
        var prompt: String?
        var target_thread_id: String?
    }
    public static func read(directory: URL) -> [ScheduledJob] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("automation.toml")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                let bytes = try Data(contentsOf: file)
                guard bytes.count < 2 * 1024 * 1024 else { throw ClientFailure(L10n.text("Слишком большой файл задания", "The job file is too large")) }
                let d = try TOMLDecoder().decode(Definition.self, from: bytes)
                let known = d.kind == "cron" || d.kind == "heartbeat"
                return ScheduledJob(id: folder.lastPathComponent, name: d.name, status: d.status ?? "UNKNOWN",
                                    kind: d.kind ?? "unknown", schedule: readableSchedule(d.rrule ?? ""),
                                    prompt: d.prompt ?? "", targetThread: d.target_thread_id,
                                    issue: known && (d.version == nil || d.version == 1) ? nil : L10n.text("Неизвестный формат; показаны доступные поля", "Unknown format; showing available fields"))
            } catch {
                return ScheduledJob(id: folder.lastPathComponent, name: folder.lastPathComponent, status: "UNKNOWN",
                                    kind: "unknown", schedule: L10n.text("Нет данных", "No data"), prompt: "", issue: L10n.text("Не удалось прочитать определение задания", "Could not read the job definition"))
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func readableSchedule(_ rule: String) -> String {
        let normalized = rule.hasPrefix("RRULE:") ? String(rule.dropFirst(6)) : rule
        let fields = normalized.split(separator: ";").reduce(into: [String: String]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        let interval = fields["INTERVAL"] ?? "1"
        switch fields["FREQ"] {
        case "HOURLY" where Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL"]): return L10n.text("Каждые \(interval) ч.", "Every \(interval) hr")
        case "MINUTELY" where Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL"]): return L10n.text("Каждые \(interval) мин.", "Every \(interval) min")
        default: return rule.isEmpty ? L10n.text("Расписание недоступно", "Schedule unavailable") : rule
        }
    }
}
