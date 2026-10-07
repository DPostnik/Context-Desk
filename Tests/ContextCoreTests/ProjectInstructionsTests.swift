import Foundation
import ContextCore
import Testing
@testable import ClaudeAdapter

@Test func claudeChatsReceiveProjectInstructionsDespiteIsolatedSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    #expect(ProjectInstructions.prompt(projectPath: root.path) == nil)

    // CLAUDE.md imports are expanded; files outside the project are not read.
    try "secret".write(to: outside, atomically: true, encoding: .utf8)
    try "Commit after build.".write(to: root.appendingPathComponent("rules.md"), atomically: true, encoding: .utf8)
    try "@rules.md\n@\(outside.path)\n@../\(outside.lastPathComponent)".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    let fallback = try #require(ProjectInstructions.prompt(projectPath: root.path, language: .english))
    #expect(fallback.hasPrefix("Project instructions from CLAUDE.md"))
    #expect(fallback.contains("Commit after build.") && !fallback.contains("secret"))

    try "Push after verification.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    let rules = try #require(ProjectInstructions.prompt(projectPath: root.path, language: .russian))
    #expect(rules.hasPrefix("Инструкции проекта из AGENTS.md") && rules.contains("Push after verification."))

    let args = ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: .standard, model: "", effort: nil, projectInstructions: rules)
    #expect(args[args.firstIndex(of: "--setting-sources")! + 1] == "")
    #expect(args.filter { $0 == "--append-system-prompt" }.count == 1)
    let prompt = args[args.firstIndex(of: "--append-system-prompt")! + 1]
    #expect(prompt.hasPrefix(AgentAutonomy.instructions()) && prompt.hasSuffix(rules))
}
