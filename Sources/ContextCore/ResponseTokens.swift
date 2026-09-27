import Foundation
@_exported import AgentContract

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

extension ResponseTokens {
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
