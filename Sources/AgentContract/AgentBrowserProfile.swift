import Foundation

/// Explicit native UI choice for a new interactive session. This opaque ID does
/// not grant access; the host must verify project scope and exclusive ownership.
public struct AgentBrowserProfile: Equatable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}
