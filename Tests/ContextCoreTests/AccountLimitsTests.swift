import Foundation
import Testing
@testable import ContextCore

private func limitsJSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Test func accountLimitsPreferBucketsWithoutAddingQuotas() throws {
    let snapshot = AccountLimits(response: try limitsJSON(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitName":"Codex","primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":61,"windowDurationMins":10080}},"model-x":{"limitName":"Model X","primary":{"usedPercent":10}}},"ordinaryUsageAllowed":false}"#))
    #expect(snapshot.buckets.count == 2)
    #expect(snapshot.buckets[0].windows.map(\.remainingPercent) == [77, 39])
    #expect(snapshot.buckets[0].windows.map(\.title) == ["За 5 ч.", "За 7 д."])
    #expect(snapshot.buckets[0].windows[0].resetsAt == Date(timeIntervalSince1970: 1800000000))
    #expect(snapshot.buckets[1].name == "Model X")
    #expect(snapshot.buckets[1].windows[0].remainingPercent == 90)
    #expect(snapshot.ordinaryUsageAllowed == false)
}

@Test func missingLimitsStayUnknownAndLegacyRemainsSupported() throws {
    let date = Date(timeIntervalSince1970: 10)
    let empty = AccountLimits(response: .object([:]), date: date)
    #expect(empty.buckets.isEmpty)
    #expect(empty.ordinaryUsageAllowed == nil)
    #expect(empty.fetchedAt == date)
    let snapshot = AccountLimits(response: try limitsJSON(#"{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":90},"secondary":null}}"#))
    #expect(snapshot.buckets[0].windows[0].remainingPercent == 100)
    #expect(snapshot.buckets[0].windows[0].title == "За 1 ч. 30 мин.")
    #expect(snapshot.buckets[0].windows[0].resetsAt == nil)
    #expect(snapshot.buckets[0].windows.count == 1)
    let unknown = AccountLimits(response: try limitsJSON(#"{"rateLimits":{"primary":{}}}"#))
    #expect(unknown.buckets[0].windows[0].remainingPercent == nil)
    #expect(unknown.buckets[0].windows[0].durationMinutes == nil)
}

@Test func outOfRangeUsageCannotOverflowOrInventResetTime() throws {
    let snapshot = AccountLimits(response: try limitsJSON(#"{"rateLimits":{"primary":{"usedPercent":-9223372036854775808,"resetsAt":0},"secondary":{"usedPercent":125,"resetsAt":null,"windowDurationMins":0}}}"#))
    #expect(snapshot.buckets[0].windows.map(\.remainingPercent) == [100, 0])
    #expect(snapshot.buckets[0].windows.allSatisfy { $0.resetsAt == nil })
    #expect(snapshot.buckets[0].windows[1].durationMinutes == nil)
}
