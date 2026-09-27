import Foundation

/// A scheduler-facing execution contract. Chat bookkeeping remains application-owned.
/// Deferred completions arrive through the interactive integration's existing events.
public enum AgentScheduledResult: Sendable {
    case deferred
    case finished(AgentExecutionOutcome, output: String)
}

public protocol AgentScheduledExecutor: Sendable {
    func descriptor() async -> AgentResult<AgentDescriptor>
    func execute(_ request: AgentExecutionRequest,
                 willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentScheduledResult>
    func stop() async
}
