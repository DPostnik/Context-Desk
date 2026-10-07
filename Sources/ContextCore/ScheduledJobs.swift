import Foundation
import TOMLDecoder

public struct ScheduledJob: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var status: String
    public var kind: String
    public var schedule: String
    public var prompt: String
    public var targetThread: String?
    public var issue: String?
    public var engine: JobEngine = .codex
    public var rawRule: String = ""
    public var model: String = ""
    public var effort: String = ""
    public var paths: [String] = []
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
        var model: String?
        var reasoning_effort: String?
        var cwds: [String]?
    }
    static func decode(_ bytes: Data, id: String) throws -> ScheduledJob {
        let d = try TOMLDecoder().decode(Definition.self, from: bytes)
        guard d.id == id else { throw ScheduleControl.invalid }
        let known = d.kind == "cron" || d.kind == "heartbeat"
        return ScheduledJob(id: id, name: d.name, status: d.status ?? "UNKNOWN",
                    kind: d.kind ?? "unknown", schedule: readableSchedule(d.rrule ?? ""),
                    prompt: d.prompt ?? "", targetThread: d.target_thread_id,
                    issue: known && (d.version == nil || d.version == 1) ? nil : L10n.text("Неизвестный формат; показаны доступные поля", "Unknown format; showing available fields"),
                    rawRule: d.rrule ?? "", model: d.model ?? "", effort: d.reasoning_effort ?? "", paths: d.cwds ?? [])
    }
    public static func read(directory: URL) -> [ScheduledJob] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("automation.toml")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do {
                let bytes = try Data(contentsOf: file)
                guard bytes.count < 2 * 1024 * 1024 else { throw ClientFailure(L10n.text("Слишком большой файл задания", "The job file is too large")) }
                return try decode(bytes, id: folder.lastPathComponent)
            } catch {
                return ScheduledJob(id: folder.lastPathComponent, name: folder.lastPathComponent, status: "UNKNOWN",
                                    kind: "unknown", schedule: L10n.text("Нет данных", "No data"), prompt: "", issue: L10n.text("Не удалось прочитать определение задания", "Could not read the job definition"))
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func readClaude(directory: URL) -> [ScheduledJob] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            guard let data = try? Data(contentsOf: file), data.count < 2 * 1024 * 1024,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            // Only the documented Markdown body is imported. YAML and unknown metadata are never executed.
            let lines = text.components(separatedBy: "\n")
            guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
                  let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { return nil }
            return ScheduledJob(id: "claude:" + folder.lastPathComponent, name: folder.lastPathComponent,
                status: "UNKNOWN", kind: "claude", schedule: L10n.text("Укажи расписание при импорте", "Set the schedule when importing"),
                prompt: lines.dropFirst(end + 1).joined(separator: "\n"),
                issue: L10n.text("В SKILL.md нет времени, проекта и модели. Проверь их в редакторе. Продолжение исходного чата не переносится.", "SKILL.md has no schedule, project or model. Review them in the editor. The source conversation is not transferred."), engine: .claude)
        }.sorted { $0.name < $1.name }
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
