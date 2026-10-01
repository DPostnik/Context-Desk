@testable import CodexAdapter
import Foundation
import Testing
import TOMLDecoder
@testable import ContextCore

@Test func browserLaunchArgumentsPreservePathsAndProjectPolicy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser \"test\" \\ \(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Resources")
    let scripts = resources.appendingPathComponent("BrowserRuntime")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try Data().write(to: scripts.appendingPathComponent("server.py"))
    try Data().write(to: root.appendingPathComponent("runtime.json"))
    for language in AppLanguage.allCases {
        let args = try BrowserConfiguration.arguments(enabled: true, resources: resources, root: root, language: language)
        #expect(stride(from: 0, to: args.count, by: 2).allSatisfy { args[$0] == "-c" })
        let toml = stride(from: 1, to: args.count, by: 2).map { args[$0] }.joined(separator: "\n")
        struct Server: Decodable { let command: String; let args: [String]; let enabled: Bool }
        struct Config: Decodable { let mcp_servers: [String: Server] }
        let decoded = try TOMLDecoder().decode(Config.self, from: toml)
        let server = try #require(decoded.mcp_servers["context_desk_browser"])
        #expect(server.command == "/usr/bin/python3")
        #expect(server.args == [scripts.appendingPathComponent("server.py").path, "--root", root.path, "--language", language.rawValue])
        #expect(server.enabled)
        #expect(!toml.contains("approval") && !toml.contains("sandbox") && !toml.contains("trust"))
    }
    #expect(try BrowserConfiguration.arguments(enabled: false, resources: nil, root: root).isEmpty)
}

@Test func browserPreferenceMigratesAndPersistsWithoutChangingProjectAccess() async throws {
    var state = try JSONDecoder().decode(SavedState.self, from: Data(#"{"projects":[],"chats":[],"model":""}"#.utf8))
    #expect(state.browserEnabled == nil)
    state.browserEnabled = true
    var project = Project(path: "/tmp/browser-project")
    project.accessMode = .standard
    state.projects = [project]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(file: root.appendingPathComponent("state.sqlite"))
    try await store.save(state)
    let restored = try await store.load()
    #expect(restored.browserEnabled == true)
    #expect(restored.projects.first?.accessMode == .standard)
}

@Test func browserMissingResourcesExplainRecoveryInBothLanguages() {
    for language in AppLanguage.allCases {
        do {
            _ = try BrowserConfiguration.arguments(enabled: true, resources: nil, language: language)
            Issue.record("Expected missing resource failure")
        } catch {
            #expect(error.localizedDescription.contains(language == .russian ? "Компонент браузера" : "browser component"))
        }
    }
}

@Test func browserNativeSessionsNeverShareBindingsAndCorruptionFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try BrowserEnvironmentStore.environment(session: "thread-a", root: root)
    let b = try BrowserEnvironmentStore.environment(session: "thread-b", root: root)
    #expect(a != b)
    #expect(try BrowserEnvironmentStore.environment(session: "thread-a", root: root) == a)
    let file = BrowserEnvironmentStore.bindingPath(session: "thread-a", root: root)
    try Data("broken".utf8).write(to: file)
    #expect(throws: (any Error).self) { try BrowserEnvironmentStore.environment(session: "thread-a", root: root) }
}
