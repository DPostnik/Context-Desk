import Foundation

public struct ResponseTiming: Codable, Sendable, Equatable {
    public var startedAt: Date?
    public var completedAt: Date
    public var durationSeconds: Double?
    public var tokens: ResponseTokens?
    public init(startedAt: Date?, completedAt: Date, durationSeconds: Double? = nil, tokens: ResponseTokens? = nil) {
        self.startedAt = startedAt; self.completedAt = completedAt
        self.durationSeconds = durationSeconds; self.tokens = tokens
    }

    public static func apply(_ timing: Self?, to items: inout [TranscriptItem]) {
        guard let timing, let index = items.lastIndex(where: { $0.kind == "assistant" }) else { return }
        items[index].timing = timing
    }
}

public struct TranscriptItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var text: String
    public var phase: String?
    public var turnID: String?
    public var showsAuthor = true
    public var showsCopyControl = true
    public var timing: ResponseTiming?
    public init(id: String, kind: String, text: String, phase: String? = nil, timing: ResponseTiming? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.phase = phase; self.timing = timing
    }
    public static func merge(_ item: Self, into items: inout [Self]) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            updated.timing = item.timing ?? items[index].timing
            updated.turnID = item.turnID ?? items[index].turnID
            items[index] = updated
        } else if item.kind == "user", let index = items.firstIndex(where: {
            $0.kind == "user" && $0.id.hasPrefix("local-user:") && $0.text == item.text
        }) {
            items[index] = item
        } else { items.append(item) }
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var last: Int?
    public var window: Int?
    public var input: Int?
    public var cached: Int?
    public var output: Int?
    public var measuredAt: Date
    public init(last: Int? = nil, window: Int? = nil, input: Int? = nil, cached: Int? = nil,
                output: Int? = nil, measuredAt: Date = Date()) {
        self.last = last; self.window = window; self.input = input
        self.cached = cached; self.output = output; self.measuredAt = measuredAt
    }
    public var contextFraction: Double? {
        guard let last, let window, last >= 0, window > 0 else { return nil }
        return min(1, Double(last) / Double(window))
    }
    public var uncached: Int? {
        guard let input, let cached, input >= cached else { return nil }; return input - cached
    }
}

public struct TokenCounters: Codable, Sendable, Equatable {
    public var input: Int
    public var cached: Int
    public var output: Int
    public static let zero = Self(input: 0, cached: 0, output: 0)

    public init(input: Int, cached: Int, output: Int) {
        self.input = input; self.cached = cached; self.output = output
    }
    public func subtracting(_ previous: Self) -> Self? {
        guard input >= previous.input, cached >= previous.cached, output >= previous.output,
              cached - previous.cached <= input - previous.input else { return nil }
        return Self(input: input - previous.input, cached: cached - previous.cached, output: output - previous.output)
    }
}

public struct ResponseTokens: Codable, Sendable, Equatable {
    public var counts: TokenCounters
    public var isPartial: Bool
    public init(counts: TokenCounters, isPartial: Bool) { self.counts = counts; self.isPartial = isPartial }

}

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

}
