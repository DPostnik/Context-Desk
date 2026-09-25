import Foundation

public struct AccountLimits: Sendable {
    public let buckets: [LimitBucket]
    public let ordinaryUsageAllowed: Bool?
    public let fetchedAt: Date

    public init(response: JSONValue, date: Date = Date()) {
        let mapped = response["rateLimitsByLimitId"].object
        if mapped.isEmpty {
            let legacy = response["rateLimits"]
            buckets = legacy.object.isEmpty ? [] : [LimitBucket(id: legacy["limitId"].string ?? "codex", value: legacy)]
        } else {
            buckets = mapped.keys.sorted().compactMap { id in
                guard let value = mapped[id], !value.object.isEmpty else { return nil }
                return LimitBucket(id: id, value: value)
            }
        }
        ordinaryUsageAllowed = response["ordinaryUsageAllowed"].bool
        fetchedAt = date
    }
}

public struct LimitBucket: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let windows: [LimitWindow]

    init(id: String, value: JSONValue) {
        self.id = id
        name = value["limitName"].string ?? (id == "codex" ? "Codex" : id)
        windows = ["primary", "secondary"].compactMap { key in
            guard case .object = value[key] else { return nil }
            return LimitWindow(id: key, value: value[key])
        }
    }
}

public struct LimitWindow: Identifiable, Sendable {
    public let id: String
    public let remainingPercent: Int?
    public let durationMinutes: Int?
    public let resetsAt: Date?

    init(id: String, value: JSONValue) {
        self.id = id
        remainingPercent = value["usedPercent"].int.map { 100 - min(100, max(0, $0)) }
        durationMinutes = value["windowDurationMins"].int.flatMap { $0 > 0 ? $0 : nil }
        resetsAt = value["resetsAt"].int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil }
    }

    public var title: String {
        guard let minutes = durationMinutes else { return id == "primary" ? L10n.text("Основной лимит", "Primary limit") : L10n.text("Дополнительный лимит", "Additional limit") }
        if minutes % 1440 == 0 { return L10n.text("За \(minutes / 1440) д.", "\(minutes / 1440)-day window") }
        if minutes % 60 == 0 { return L10n.text("За \(minutes / 60) ч.", "\(minutes / 60)-hour window") }
        if minutes < 60 { return L10n.text("За \(minutes) мин.", "\(minutes)-minute window") }
        return L10n.text("За \(minutes / 60) ч. \(minutes % 60) мин.", "\(minutes / 60) hr \(minutes % 60) min window")
    }
}
