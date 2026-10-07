import Testing
import ContextCore
import ClaudeAdapter

@Test func autonomyGuidanceIsLocalizedAndSeparateFromPermissionFlags() {
    let ru = AgentAutonomy.instructions(language: .russian)
    let en = AgentAutonomy.instructions(language: .english)
    #expect(ru.contains("Автономность в Context Desk"))
    #expect(en.contains("Autonomy in Context Desk"))
    #expect(ru.contains("Не считай молчание согласием"))
    #expect(en.contains("Silence is not consent"))
    let arguments = ClaudeJobRunner.arguments(model: "model", effort: nil)
    #expect(arguments.contains("dontAsk"))
    #expect(!arguments.contains("bypassPermissions"))
    #expect(arguments.filter { $0 == "--append-system-prompt" }.count == 1)
    #expect(arguments.contains(AgentAutonomy.instructions()))
}
