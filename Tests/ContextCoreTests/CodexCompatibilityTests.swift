@_spi(NativeProtocol) @testable import CodexAdapter
import ContextCore
import AgentContract
import Foundation
import Testing

@Test func codexVersionGateUsesOnlyTheEngineProductToken() {
    for agent in ["context_desk/0.159.0 (Mac OS; arm64)", "codex/0.158.0-alpha.2.1 fixture"] {
        #expect(CodexProtocolCompatibility.accepts(userAgent: agent))
    }
    for agent in ["", "0.159.0", "/0.159.0", "codex/0.159.1 fixture", "codex/0.159.0-dev fixture",
                  "codex/999.0 client/0.159.0 fixture"] {
        #expect(!CodexProtocolCompatibility.accepts(userAgent: agent))
    }
}

/// Explicit opt-in: uses a temporary unauthenticated home and never sends a model turn.
@Test func installedCodexCompatibilityWithoutInference() async throws {
    guard ProcessInfo.processInfo.environment["CONTEXTDESK_CODEX_COMPATIBILITY_LIVE"] == "1" else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = CodexConnection()
    let app = AgentClient(integration: CodexIntegration(client: CodexClient(transport: wire)))
    do {
        _ = try await app.start(.init(executable: Locations.codexExecutable(), home: root.appendingPathComponent("codex")))
        #expect(try await app.account().authenticated == false)
        try await app.registerWorkflows(at: root)
        await app.stop()

        // Exercise the real summary setup through the last pre-inference isolation checks.
        try await wire.start(executable: Locations.codexExecutable(), home: root.appendingPathComponent("codex"),
                             extraArguments: ArchiveSummaryRunner.isolationArguments)
        let config = try await wire.request("config/read", params: .object(["includeLayers": .bool(false)]))
        #expect(config["config"] != .null)
        let thread = try await wire.request("thread/start", params: .object([
            "ephemeral": .bool(true), "environments": .array([]), "runtimeWorkspaceRoots": .array([]),
            "selectedCapabilityRoots": .array([]), "dynamicTools": .array([]),
            "cwd": .string(root.path), "sandbox": .string("read-only"),
            "approvalPolicy": .string("untrusted"), "approvalsReviewer": .string("user"),
            "model": .string("gpt-6-astra"), "modelProvider": .string("openai"),
            "allowProviderModelFallback": .bool(false)
        ]))
        #expect(thread["thread"]["ephemeral"].bool == true)
        #expect(thread["thread"]["environments"] == .array([]))
        #expect(thread["sandbox"]["type"].string == "readOnly")
        #expect(thread["approvalPolicy"].string == "untrusted")
        #expect(thread["modelProvider"].string == "openai")
        #expect(thread["model"].string == "gpt-6-astra")
        let id = try #require(thread["thread"]["id"].string)
        let inventory = try await wire.request("mcpServerStatus/list", params: .object([
            "threadId": .string(id), "detail": .string("toolsAndAuthOnly")
        ]))
        #expect(inventory["data"] == .array([]))
        await wire.stop()
    } catch {
        await app.stop(); await wire.stop()
        throw error
    }
}
