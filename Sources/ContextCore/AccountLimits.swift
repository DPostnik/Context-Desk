import Foundation

public struct AccountLimits: Sendable {
    public let buckets: [LimitBucket]
    public let ordinaryUsageAllowed: Bool?
    public let fetchedAt: Date

    public init(buckets: [LimitBucket], ordinaryUsageAllowed: Bool?, fetchedAt: Date) {
        self.buckets = buckets; self.ordinaryUsageAllowed = ordinaryUsageAllowed; self.fetchedAt = fetchedAt
    }
}

public struct LimitBucket: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let windows: [LimitWindow]

    public init(id: String, name: String, windows: [LimitWindow]) {
        self.id = id; self.name = name; self.windows = windows
    }
}

public struct LimitWindow: Identifiable, Sendable {
    public let id: String
    public let remainingPercent: Int?
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(id: String, remainingPercent: Int?, durationMinutes: Int?, resetsAt: Date?) {
        self.id = id; self.remainingPercent = remainingPercent
        self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }

    public var title: String {
        guard let minutes = durationMinutes else { return id == "primary" ? L10n.text("Основной лимит", "Primary limit") : L10n.text("Дополнительный лимит", "Additional limit") }
        if minutes % 1440 == 0 { return L10n.text("За \(minutes / 1440) д.", "\(minutes / 1440)-day window") }
        if minutes % 60 == 0 { return L10n.text("За \(minutes / 60) ч.", "\(minutes / 60)-hour window") }
        if minutes < 60 { return L10n.text("За \(minutes) мин.", "\(minutes)-minute window") }
        return L10n.text("За \(minutes / 60) ч. \(minutes % 60) мин.", "\(minutes / 60) hr \(minutes % 60) min window")
    }
}
