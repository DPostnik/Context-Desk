import Foundation

public struct AgentTranscriptItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, assistant, tool, activity }
    public let id: String
    public let kind: Kind
    public let text: String
    public init(id: String, kind: Kind, text: String) { self.id = id; self.kind = kind; self.text = text }
}

/// Portable readable evidence, never an executable replacement for native engine state.
public struct AgentTranscriptSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public enum Completeness: String, Codable, Sendable { case complete, partial, unavailable }
    public let version: Int
    public let conversation: ConversationID
    public let source: AgentSessionReference
    public let revision: String
    public let capturedAt: Date
    public let completeness: Completeness
    public let items: [AgentTranscriptItem]
    public init(conversation: ConversationID, source: AgentSessionReference, revision: String,
                capturedAt: Date, completeness: Completeness, items: [AgentTranscriptItem]) {
        version = Self.schemaVersion; self.conversation = conversation; self.source = source
        self.revision = revision; self.capturedAt = capturedAt; self.completeness = completeness; self.items = items
    }
}

public struct AgentInteractionID: Hashable, Sendable {
    public let execution: AgentExecutionHandle
    public let id: UUID
    public init(execution: AgentExecutionHandle, id: UUID = UUID()) { self.execution = execution; self.id = id }
}

public struct AgentApproval: Sendable {
    public enum Decision: String, Hashable, Sendable { case deny, allowOnce, allowSession }
    public enum Action: Sendable {
        case command(arguments: [String], directory: String)
        case fileChange(paths: [String])
        case permissions(paths: [String], network: Bool)
    }
    public let id: AgentInteractionID
    public let action: Action
    public let offeredDecisions: Set<Decision>
    public init(id: AgentInteractionID, action: Action, offeredDecisions: Set<Decision>) {
        self.id = id; self.action = action; self.offeredDecisions = offeredDecisions
    }
    public func accepts(_ decision: Decision, for id: AgentInteractionID, currentContext: AgentContext) -> Bool {
        self.id == id && id.execution.context == currentContext && offeredDecisions.contains(decision)
    }
}

public struct AgentQuestion: Sendable {
    public struct Field: Sendable {
        public let id: String
        public let text: String
        public let options: [String]
        public let allowsFreeText: Bool
        public let isSecret: Bool
        public init(id: String, text: String, options: [String], allowsFreeText: Bool, isSecret: Bool = false) {
            self.id = id; self.text = text; self.options = options
            self.allowsFreeText = allowsFreeText; self.isSecret = isSecret
        }
    }
    public let id: AgentInteractionID
    public let fields: [Field]
    public init(id: AgentInteractionID, fields: [Field]) { self.id = id; self.fields = fields }
}

public enum AgentUserResponse: Sendable {
    case approval(AgentInteractionID, AgentApproval.Decision)
    case answers(AgentInteractionID, [String: [String]])
    case decline(AgentInteractionID)
}

public enum AgentExecutionOutcome: String, Codable, Sendable {
    case completed, failed, blocked, cancelled, uncertain
    public var requiresReview: Bool { self != .completed }
    /// Even confirmed failures require explicit user/scheduler policy; adapters never replay work.
    public var permitsAutomaticReplay: Bool { false }
}

/// Common conservative delivery semantics, independent of either native protocol.
/// Adapters persist/notify dispatch before sending bytes; losing an acknowledgement is uncertain.
public struct AgentDeliveryTracker: Sendable {
    public enum State: Equatable, Sendable {
        case notSent, dispatched, acknowledged, cancellationRequested
        case finished(AgentExecutionOutcome)
    }
    public private(set) var state: State = .notSent
    public init() {}
    @discardableResult public mutating func dispatch() -> Bool {
        guard state == .notSent else { return false }
        state = .dispatched; return true
    }
    public mutating func acknowledge() {
        if state == .dispatched { state = .acknowledged }
    }
    public mutating func requestCancellation() {
        switch state {
        case .notSent: state = .finished(.cancelled)
        case .dispatched, .acknowledged: state = .cancellationRequested
        case .cancellationRequested, .finished: break
        }
    }
    public mutating func confirm(_ outcome: AgentExecutionOutcome) {
        switch state {
        case .dispatched, .acknowledged, .cancellationRequested: state = .finished(outcome)
        case .notSent, .finished: break
        }
    }
    public mutating func connectionLost() {
        switch state {
        case .notSent: state = .finished(.failed)
        case .dispatched, .acknowledged, .cancellationRequested: state = .finished(.uncertain)
        case .finished: break
        }
    }
}
