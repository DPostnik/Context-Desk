import Foundation
import Testing
@testable import ContextCore

private func temporaryParent() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func legacyDataFolderMovesOnceAndLeavesALink() throws {
    let parent = try temporaryParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let legacy = parent.appendingPathComponent("Context Desk"), current = parent.appendingPathComponent("Switchboard")
    try FileManager.default.createDirectory(at: legacy.appendingPathComponent("claude"), withIntermediateDirectories: true)
    try Data("state".utf8).write(to: legacy.appendingPathComponent("metadata.sqlite"))

    #expect(LegacyDataMigration.run(legacy: legacy, current: current) == .moved)
    #expect(try String(contentsOf: current.appendingPathComponent("metadata.sqlite"), encoding: .utf8) == "state")
    #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("claude").path))
    // Paths recorded under the old name still resolve through the link.
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) == current.path)
    #expect(try String(contentsOf: legacy.appendingPathComponent("metadata.sqlite"), encoding: .utf8) == "state")

    // The next launch sees the link, not data, and moves nothing.
    #expect(LegacyDataMigration.run(legacy: legacy, current: current) == .none)
}

@Test func legacyDataMigrationNeverMergesTwoFolders() throws {
    let parent = try temporaryParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let legacy = parent.appendingPathComponent("Context Desk"), current = parent.appendingPathComponent("Switchboard")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: legacy.appendingPathComponent("metadata.sqlite"))

    #expect(LegacyDataMigration.run(legacy: legacy, current: current) == .conflict)
    #expect(try String(contentsOf: legacy.appendingPathComponent("metadata.sqlite"), encoding: .utf8) == "old")
    #expect(!FileManager.default.fileExists(atPath: current.appendingPathComponent("metadata.sqlite").path))
}

@Test func freshInstallHasNothingToMigrate() throws {
    let parent = try temporaryParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    #expect(LegacyDataMigration.run(legacy: parent.appendingPathComponent("Context Desk"),
                                    current: parent.appendingPathComponent("Switchboard")) == .none)
}

@Test func preferencesAreCopiedFromTheOldBundleIdOnce() throws {
    let legacy = "SwitchboardTests.legacy.\(UUID().uuidString)", current = "SwitchboardTests.current.\(UUID().uuidString)"
    let defaults = UserDefaults.standard
    defer {
        for domain in [legacy, current] {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(domain).plist"))
        }
    }
    #expect(!LegacyPreferencesMigration.run(domain: current, legacyDomain: legacy, defaults: defaults))

    defaults.setPersistentDomain(["language": "en", "zoom": 1.1], forName: legacy)
    #expect(LegacyPreferencesMigration.run(domain: current, legacyDomain: legacy, defaults: defaults))
    #expect(defaults.persistentDomain(forName: current)?["language"] as? String == "en")

    // Settings changed after the move are never overwritten by the old domain.
    defaults.setPersistentDomain(["language": "ru"], forName: current)
    #expect(!LegacyPreferencesMigration.run(domain: current, legacyDomain: legacy, defaults: defaults))
    #expect(defaults.persistentDomain(forName: current)?["language"] as? String == "ru")
}
