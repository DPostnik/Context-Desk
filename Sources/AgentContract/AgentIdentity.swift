import Foundation

/// Opaque identifiers survive missing integrations. Never interpret an unknown ID as Codex.
public struct AgentID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let codex = Self(rawValue: "codex")
    public static let claudeCode = Self(rawValue: "claude-code")
}

public struct AgentConnectionID: Codable, Hashable, Sendable {
    public let agent: AgentID
    public let id: UUID
    public init(agent: AgentID, id: UUID) { self.agent = agent; self.id = id }
}

/// Rotated on account changes; stale requests, approvals and model catalogs must be rejected.
public struct AgentContext: Codable, Hashable, Sendable {
    public let connection: AgentConnectionID
    public let accountRevision: UUID
    public init(connection: AgentConnectionID, accountRevision: UUID) {
        self.connection = connection; self.accountRevision = accountRevision
    }
}

public struct ConversationID: Codable, Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}

public struct AgentSessionReference: Codable, Hashable, Sendable {
    public let connection: AgentConnectionID
    public let nativeID: String
    public init(connection: AgentConnectionID, nativeID: String) {
        self.connection = connection; self.nativeID = nativeID
    }
}

/// Routing is independent of identity. External CLI configuration is not a verified direct route.
public enum AgentRoute: Codable, Hashable, Sendable {
    case direct
    case optimizer(id: String)
    case externalConfiguration
}

public struct AgentModelSelection: Codable, Hashable, Sendable {
    public let context: AgentContext
    public let model: String
    public let effort: String?
    public init(context: AgentContext, model: String, effort: String? = nil) {
        self.context = context; self.model = model; self.effort = effort
    }
}

public enum AgentIdentityMode: String, Codable, Sendable {
    case appOwnedHome, externalCLI
}

public enum AgentCapability: String, Codable, CaseIterable, Sendable {
    case interactiveSessions, scheduledExecution, isolatedGeneration
    case history, archive, streaming, approvals, userQuestions, interruption
    case authenticationManagement, modelDiscovery, usage, accountLimits
    case toolRegistration, workflowRegistration
}

/// These are restrictions, not provider-specific sandbox names.
public enum AgentPermissionIntent: Codable, Hashable, Sendable {
    case workspaceWrite(root: String, network: Bool, approval: ApprovalPolicy)
    case unrestricted(approval: ApprovalPolicy)
    /// Explicitly accepts the external CLI's policy, with new prompts denied.
    /// Never derive this case from a project's standard/full-access setting.
    case externalPolicyDenyPrompts

    public enum ApprovalPolicy: String, Codable, Sendable { case ask, never }
}

public enum AgentPermissionSupport: String, Codable, Sendable {
    case codexProjectPolicy, externalPolicyOnly

    public func accepts(_ intent: AgentPermissionIntent) -> Bool {
        switch (self, intent) {
        case (.codexProjectPolicy, .workspaceWrite(_, false, .ask)),
             (.codexProjectPolicy, .unrestricted(.never)),
             (.externalPolicyOnly, .externalPolicyDenyPrompts): true
        default: false
        }
    }
}

public struct AgentDescriptor: Sendable {
    public static let contractVersion = 1
    public let version: Int
    public let context: AgentContext
    public let identityMode: AgentIdentityMode
    public let capabilities: Set<AgentCapability>
    public let permissions: AgentPermissionSupport
    /// Only routes verified and available on this connection. Never add fallback routes.
    public let routes: Set<AgentRoute>

    public init(version: Int = Self.contractVersion, context: AgentContext,
                identityMode: AgentIdentityMode, capabilities: Set<AgentCapability>,
                permissions: AgentPermissionSupport, routes: Set<AgentRoute>) {
        self.version = version; self.context = context; self.identityMode = identityMode
        self.capabilities = capabilities; self.permissions = permissions; self.routes = routes
    }

    public func validate(_ request: AgentExecutionRequest) -> AgentRejection? {
        guard version == Self.contractVersion else { return .incompatibleContract }
        guard request.model.context == context else { return .staleContext }
        if let session = request.session, session.connection != context.connection { return .wrongConnection }
        guard capabilities.contains(request.kind.capability) else { return .unsupported(request.kind.capability) }
        guard routes.contains(request.route) else { return .routeUnavailable }
        guard permissions.accepts(request.permissions) else { return .unsupportedPermissions }
        if case .workspaceWrite(let root, _, _) = request.permissions,
           root != request.projectPath { return .unsupportedPermissions }
        guard request.projectPath.hasPrefix("/"), !request.model.model.isEmpty else { return .invalidInput }
        // Print-mode execution cannot continue a native session.
        if request.session != nil && !capabilities.contains(.interactiveSessions) { return .unsupported(.interactiveSessions) }
        return nil
    }

    public func validate(_ request: AgentGenerationRequest) -> AgentRejection? {
        guard version == Self.contractVersion else { return .incompatibleContract }
        guard request.model.context == context else { return .staleContext }
        guard request.source.connection == context.connection else { return .wrongConnection }
        guard capabilities.contains(.isolatedGeneration) else { return .unsupported(.isolatedGeneration) }
        guard routes.contains(request.route) else { return .routeUnavailable }
        guard !request.model.model.isEmpty,
              request.historicalInput.utf8.count <= AgentGenerationRequest.maximumInputBytes else { return .invalidInput }
        return nil
    }
}

public enum AgentRejection: Equatable, Sendable {
    case incompatibleContract, staleContext, wrongConnection, routeUnavailable, unsupportedPermissions
    case unsupported(AgentCapability)
    case unknownRequest, invalidResponse, invalidInput
}
