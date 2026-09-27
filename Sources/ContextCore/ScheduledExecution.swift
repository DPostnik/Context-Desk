import Foundation
import AgentContract

extension ManagedJob {
    public func executionRequest(runID: UUID, project: Project, descriptor: AgentDescriptor) -> AgentExecutionRequest {
        let permissions: AgentPermissionIntent
        if descriptor.identityMode == .externalCLI, acceptsExternalPolicy == true, project.accessMode == .fullAccess {
            permissions = .externalPolicyDenyPrompts
        } else if project.accessMode == .fullAccess {
            permissions = .unrestricted(approval: .never)
        } else {
            permissions = .workspaceWrite(root: project.path, network: false, approval: .ask)
        }
        // Legacy direct means no app optimizer. External CLI routing is explicitly disclosed.
        let route: AgentRoute = descriptor.identityMode == .externalCLI && self.route == .direct
            ? .externalConfiguration : self.route.agentRoute
        return AgentExecutionRequest(id: runID, conversation: ConversationID(), kind: .scheduled,
            prompt: prompt, projectPath: project.path, permissions: permissions,
            model: .init(context: descriptor.context, model: model, effort: effort), route: route)
    }
}

extension JobRunStatus {
    public init(_ outcome: AgentExecutionOutcome) {
        switch outcome {
        case .completed: self = .completed
        case .failed: self = .failed
        case .blocked: self = .blocked
        case .cancelled: self = .interrupted
        case .uncertain: self = .uncertain
        }
    }
}
