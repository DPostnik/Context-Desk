import Foundation

public struct AgentAccountInfo: Sendable {
    public let authenticated: Bool
    public let plan: String?
    public init(authenticated: Bool, plan: String?) { self.authenticated = authenticated; self.plan = plan }
}

public struct AgentModelInfo: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let defaultEffort: String
    public let efforts: [String]

    public init(id: String, displayName: String, isDefault: Bool = false, defaultEffort: String = "", efforts: [String] = []) {
        self.id = id; self.displayName = displayName; self.isDefault = isDefault
        self.defaultEffort = defaultEffort; self.efforts = efforts
    }

}

public struct AgentHistoryTurn: Codable, Sendable {
    public let id: String?
    public let items: [TranscriptItem]
    public let isComplete: Bool
    private let startedAt: Date?
    private let completedAt: Date?
    private let duration: Double?

    public init(id: String?, items: [TranscriptItem], startedAt: Date?, completedAt: Date?, duration: Double?, isComplete: Bool = false) {
        self.id = id; self.items = items; self.startedAt = startedAt; self.completedAt = completedAt; self.duration = duration
        self.isComplete = isComplete
    }
    public func timing(fallback: ResponseTiming?) -> ResponseTiming? {
        guard let completedAt = completedAt ?? fallback?.completedAt else { return nil }
        return ResponseTiming(startedAt: startedAt ?? fallback?.startedAt, completedAt: completedAt,
                              durationSeconds: duration ?? fallback?.durationSeconds, tokens: fallback?.tokens)
    }
}
