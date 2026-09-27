import Foundation
import ContextCore

/// The app retains chat creation, durable links and event-based completion.
@MainActor final class CodexScheduledExecutor: AgentScheduledExecutor {
    private unowned let model: DeskModel
    private let job: ManagedJob
    private let run: JobRun
    private let project: Project
    private var consumed = false
    private var stopped = false
    init(model: DeskModel, job: ManagedJob, run: JobRun, project: Project) {
        self.model = model; self.job = job; self.run = run; self.project = project
    }
    func descriptor() async -> AgentResult<AgentDescriptor> {
        guard model.connected, model.authenticated, model.routeIsAvailable(job.route) else { return .unavailable }
        return await model.connection.integration.descriptor()
    }
    func execute(_ request: AgentExecutionRequest,
                 willStart: @escaping @Sendable () async throws -> Void) async -> AgentResult<AgentScheduledResult> {
        guard !consumed else { return .rejected(.unknownRequest) }
        guard request.id == run.id, request.kind == .scheduled, request.session == nil,
              request.prompt == job.prompt, request.projectPath == project.path,
              request.model.model == job.model, request.model.effort == job.effort,
              request.route == job.route.agentRoute else { return .rejected(.invalidInput) }
        consumed = true
        do {
            let descriptor = try await descriptor().value()
            guard request.permissions == job.executionRequest(runID: run.id, project: project, descriptor: descriptor).permissions else {
                return .rejected(.unsupportedPermissions)
            }
            if let rejection = descriptor.validate(request) { return .rejected(rejection) }
            guard !stopped, !Task.isCancelled else { return .success(.finished(.cancelled, output: "")) }
            try await willStart()
            guard !stopped, !Task.isCancelled else { return .success(.finished(.cancelled, output: "")) }
            let current = try await self.descriptor().value()
            if let rejection = current.validate(request) { return .rejected(rejection) }
            await model.deliverScheduled(job, run: run, project: project)
            return .success(.deferred)
        } catch let error as AgentOperationFailure { return error.result() }
        catch { return .failed(.init(delivery: .notSent, diagnostic: error.localizedDescription)) }
    }
    func stop() async {
        stopped = true
        guard let current = model.jobLedger.runs.first(where: { $0.id == run.id }),
              let thread = current.threadID, let turn = current.turnID else { return }
        do { try await model.connection.interrupt(model.sessionForChat(thread), turn: turn) }
        catch { model.error = error.localizedDescription }
    }
}
