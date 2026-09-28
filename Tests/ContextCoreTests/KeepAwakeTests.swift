import Foundation
import Testing
import IOKit.pwr_mgt
@testable import ContextDesk

@Test @MainActor func keepAwakeOwnsRealSystemAssertionAndRestoresPreference() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("keep-awake.json")
    let controller = KeepAwake(file: file)
    defer { controller.stop() }
    #expect(!controller.enabled)
    #expect(controller.assertionID == nil)
    controller.setEnabled(true)
    #expect(controller.error == nil)
    #expect(controller.enabled)
    let id = try #require(controller.assertionID)
    let properties = try #require(IOPMAssertionCopyProperties(id)?.takeRetainedValue() as NSDictionary?)
    #expect(properties[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep)
    #expect(properties[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn))
    controller.setEnabled(true)
    #expect(controller.assertionID == id)
    controller.stop()
    #expect(controller.assertionID == nil)
    #expect(IOPMAssertionCopyProperties(id) == nil)
    #expect(controller.enabled) // Quitting preserves the next-launch preference.

    let restored = KeepAwake(file: file)
    defer { restored.stop() }
    #expect(restored.enabled)
    #expect(restored.assertionID != nil)
    restored.setEnabled(false)
    #expect(restored.error == nil)
    #expect(restored.assertionID == nil)
    let disabled = KeepAwake(file: file)
    #expect(!disabled.enabled)
    #expect(disabled.assertionID == nil)
}

@Test @MainActor func keepAwakeRejectsCorruptPreferencesAndRollsBackUnsavedActivation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("keep-awake.json")
    try Data("invalid".utf8).write(to: file)
    let corrupt = KeepAwake(file: file)
    #expect(!corrupt.enabled)
    #expect(corrupt.error != nil)
    #expect(corrupt.assertionID == nil)
    corrupt.setEnabled(true)
    #expect(corrupt.error == nil)
    corrupt.setEnabled(false)
    #expect(corrupt.error == nil)

    // A file cannot be the parent directory of a preference file.
    let unwritable = KeepAwake(file: file.appendingPathComponent("child.json"))
    defer { unwritable.stop() }
    unwritable.setEnabled(true)
    #expect(unwritable.error != nil)
    #expect(!unwritable.enabled)
    #expect(unwritable.assertionID == nil)
}

@Test @MainActor func keepAwakeReleasesAssertionWhenOwnerIsDestroyed() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var controller: KeepAwake? = KeepAwake(file: folder.appendingPathComponent("keep-awake.json"))
    controller?.setEnabled(true)
    let id = try #require(controller?.assertionID)
    controller = nil
    #expect(IOPMAssertionCopyProperties(id) == nil)
}
