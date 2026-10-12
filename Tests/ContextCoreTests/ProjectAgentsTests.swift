import Foundation
import ContextCore
import Testing
@testable import ClaudeAdapter

@Test func claudeChatsReceiveProjectAgentsDespiteIsolatedSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent(".claude/agents", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    #expect(ProjectAgents.argument(projectPath: root.path) == nil)

    try """
    ---
    name: scheduled-worker
    description: Read-only Worker для рутин
    model: claude-opus-5-5
    effort: low
    tools: Read, Grep, Glob, Bash
    permissionMode: bypassPermissions
    hooks:
      PreToolUse:
        - matcher: Bash
    mcpServers:
      - remote
    ---

    Ты read-only Worker.
    """.write(to: folder.appendingPathComponent("scheduled-worker.md"), atomically: true, encoding: .utf8)
    try """
    ---
    description: |
      Reviews code
      carefully
    disallowedTools:
      - Write
      - "Edit"
    maxTurns: 5
    ---
    You review code.
    """.write(to: folder.appendingPathComponent("reviewer.md"), atomically: true, encoding: .utf8)
    // No description, no body, a bad name, or a file outside the project: skipped.
    try "---\nname: empty\n---\nBody".write(to: folder.appendingPathComponent("empty.md"), atomically: true, encoding: .utf8)
    try "---\ndescription: x\n---\n".write(to: folder.appendingPathComponent("blank.md"), atomically: true, encoding: .utf8)
    try "---\nname: bad name\ndescription: x\n---\nBody".write(to: folder.appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)
    try "---\ndescription: secret\n---\nBody".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.md"), withDestinationURL: outside)

    let agents = try #require(ProjectAgents.definitions(projectPath: root.path))
    guard case .object(let all) = agents else { Issue.record("not an object"); return }
    #expect(Set(all.keys) == ["scheduled-worker", "reviewer"])
    let worker = try #require(all["scheduled-worker"])
    #expect(worker["description"].string == "Read-only Worker для рутин" && worker["prompt"].string == "Ты read-only Worker.")
    #expect(worker["model"].string == "claude-opus-5-5" && worker["effort"].string == "low")
    #expect(worker["tools"] == .array(["Read", "Grep", "Glob", "Bash"].map(JSONValue.string)))
    #expect(worker["hooks"] == .null && worker["mcpServers"] == .null && worker["permissionMode"] == .null)
    let reviewer = try #require(all["reviewer"])
    #expect(reviewer["description"].string == "Reviews code\ncarefully" && reviewer["prompt"].string == "You review code.")
    #expect(reviewer["disallowedTools"] == .array(["Write", "Edit"].map(JSONValue.string)) && reviewer["maxTurns"] == .number(5))

    // Only full access has the Agent tool, so only full access gets the definitions.
    let json = try #require(ProjectAgents.argument(projectPath: root.path))
    let full = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: .fullAccess, model: "", effort: nil, projectAgents: json)
    #expect(full[full.firstIndex(of: "--agents")! + 1] == json && full[full.firstIndex(of: "--setting-sources")! + 1] == "")
    let standard = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, access: .standard, model: "", effort: nil, projectAgents: json)
    #expect(!standard.contains("--agents"))
}
