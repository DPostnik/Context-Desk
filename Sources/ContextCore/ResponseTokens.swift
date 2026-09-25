import Foundation

/// Cumulative counters from tokenUsage.total, never the last context-window snapshot.
public struct TokenCounters: Codable, Sendable, Equatable {
    public var input: Int
    public var cached: Int
    public var output: Int
    public static let zero = Self(input: 0, cached: 0, output: 0)

    public init(input: Int, cached: Int, output: Int) {
        self.input = input; self.cached = cached; self.output = output
    }
    public init?(_ raw: JSONValue) {
        guard let input = raw["inputTokens"].int, let cached = raw["cachedInputTokens"].int,
              let output = raw["outputTokens"].int, input >= 0, cached >= 0, cached <= input,
              output >= 0, !input.addingReportingOverflow(output).overflow else { return nil }
        self.init(input: input, cached: cached, output: output)
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

    public func detail(language: AppLanguage = L10n.language) -> String {
        func number(_ value: Int) -> String { value.formatted(.number.locale(language.locale)) }
        let input = number(counts.input), cached = number(counts.cached), output = number(counts.output)
        let scope = isPartial
            ? L10n.text("Токены · учтена только часть запроса", "Tokens · only part of the request was recorded", language: language)
            : L10n.text("Токены за весь запрос", "Tokens for the whole request", language: language)
        return scope + "\n" + L10n.text("Входящие: \(input) · из них кеш: \(cached)\nИсходящие: \(output)",
            "Input: \(input) · cached subset: \(cached)\nOutput: \(output)", language: language)
    }
}

/// Difference from the known turn-start baseline. Duplicate notifications add nothing.
/// Missing baselines or counter resets are explicitly reported as partial observations.
public struct ResponseTokenTracker: Sendable {
    private var baseline: TokenCounters?
    private var partial: Bool
    public private(set) var result: ResponseTokens?

    public init(baseline: TokenCounters?) {
        self.baseline = baseline; self.partial = baseline == nil
    }
    public mutating func observe(_ total: TokenCounters) {
        guard let baseline else { self.baseline = total; return }
        guard let difference = total.subtracting(baseline) else {
            self.baseline = total; partial = true; result = nil
            return
        }
        // With no turn-start baseline, an unchanged counter provides no usage evidence.
        guard !partial || difference != .zero else { return }
        result = ResponseTokens(counts: difference, isPartial: partial)
    }
}
