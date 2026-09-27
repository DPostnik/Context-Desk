import AgentContract
import ContextCore
import CodexAdapter
import ClaudeAdapter

/// Composition root only; orchestration and UI depend on the common contract.
enum AgentIntegrationFactory {
    static let claudeVersion = ClaudeJobRunner.version
    static func codex() -> any AgentIntegration { CodexIntegration() }
    @MainActor static let scheduledReadiness: [JobEngine: @MainActor (DeskModel) -> Bool] = [
        .codex: { $0.connected && $0.authenticated }, .claude: { _ in true }
    ]
    @MainActor static let scheduled: [JobEngine: @MainActor (DeskModel, ManagedJob, JobRun, Project) -> any AgentScheduledExecutor] = [
        .codex: { CodexScheduledExecutor(model: $0, job: $1, run: $2, project: $3) },
        .claude: { _, _, _, _ in ClaudeJobRunner() }
    ]
}
