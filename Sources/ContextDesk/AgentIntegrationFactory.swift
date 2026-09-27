import AgentContract
import CodexAdapter

/// Composition root only; orchestration and UI depend on the common contract.
enum AgentIntegrationFactory {
    static func codex() -> any AgentIntegration { CodexIntegration() }
}
