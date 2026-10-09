import Foundation
import AgentContract
import ContextCore
import CodexAdapter
import ClaudeAdapter

/// Composition root only; orchestration and UI depend on the common contract.
enum AgentIntegrationFactory {
    static let claudeVersion = ClaudeJobRunner.version
    static func codex() -> any AgentIntegration { CodexIntegration() }
    static func claude() -> any AgentIntegration { ClaudeIntegration() }
    @MainActor static let scheduledReadiness: [JobEngine: @MainActor (DeskModel) -> Bool] = [
        .codex: { $0.scheduledAgentReady(.originalCodex) }, .claude: { $0.scheduledAgentReady(.appClaude) }
    ]
    @MainActor static let scheduled: [JobEngine: @MainActor (DeskModel, ManagedJob, JobRun, Project) -> any AgentScheduledExecutor] = [
        .codex: { ChatScheduledExecutor(model: $0, job: $1, run: $2, project: $3) },
        // Claude runs in the app's own Claude profile as a resumable chat, like an interactive Claude chat.
        .claude: { ChatScheduledExecutor(model: $0, agent: .appClaude, job: $1, run: $2, project: $3) }
    ]
    /// Legacy print runner (the installed CLI's `~/.claude` profile); not used for new runs. Claude print runs get the same per-run Context Desk browser as Codex chats when it is enabled and installed.
    static func claudeRunner(browserEnabled: Bool, job: ManagedJob, resources: URL? = Bundle.main.resourceURL,
                             root: URL = BrowserEnvironmentStore.directory, executable: URL? = nil) -> ClaudeJobRunner {
        guard browserEnabled, let resources, FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.json").path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("BrowserRuntime/server.py").path) else {
            return ClaudeJobRunner(executable: executable,
                                   browserBlocker: job.browserSessionImport == nil ? nil : ScheduledBrowserImport.unavailable.message)
        }
        return ClaudeJobRunner(executable: executable, browser: .init(resources: resources, root: root, policy: job.browserSessionImport))
    }
}
