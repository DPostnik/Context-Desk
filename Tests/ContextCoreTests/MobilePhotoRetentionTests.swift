import Foundation
import Testing
import ContextCore

@Test func temporaryPhotosExpireOnlyAfterAnIdleGracePeriod() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1]).write(to: folder.appendingPathComponent(UUID().uuidString + ".jpg"))
    try MobilePhotoRetention.register(folder: folder, chat: "a")
    let now = Date(timeIntervalSince1970: 10000)
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: ["a"], now: now) == 0)
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: ["a"], now: now.addingTimeInterval(7200)) == 0)
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: [], now: now.addingTimeInterval(7200)) == 0)
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: [], now: now.addingTimeInterval(10799)) == 0)
    // An unrelated running chat does not keep this image forever.
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: ["b"], now: now.addingTimeInterval(10800)) == 1)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: [], now: now.addingTimeInterval(10801)) == 0)
}

@Test func photoCleanupProtectsLegacyActiveFilesAndUnknownOrLinkedContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1]).write(to: external)
    let legacy = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data([1]).write(to: legacy.appendingPathComponent(UUID().uuidString + ".jpg"))
    let unknown = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
    try Data([1]).write(to: unknown.appendingPathComponent("keep.txt"))
    let linked = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(UUID().uuidString + ".jpg"), withDestinationURL: external)
    let now = Date()
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: ["a"], now: now) == 0)
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: [], now: now) == 0)
    // Persisted expiry survives process restarts; an active run resets its grace period.
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: ["a"], now: now.addingTimeInterval(3600)) == 0)
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: [], now: now.addingTimeInterval(3601)) == 0)
    #expect(try MobilePhotoRetention.sweep(root: root, activeChats: [], now: now.addingTimeInterval(7201)) == 1)
    #expect(FileManager.default.fileExists(atPath: external.path))
    #expect(FileManager.default.fileExists(atPath: unknown.appendingPathComponent("keep.txt").path))
    #expect(FileManager.default.fileExists(atPath: linked.path))
}
