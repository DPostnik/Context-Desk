import Foundation

/// Moves the data folder from its pre-rename location (Context Desk → Switchboard) exactly once.
public enum LegacyDataMigration {
    public enum Outcome: Equatable, Sendable {
        /// Nothing to move: no old folder, or it is already the compatibility link.
        case none
        case moved
        /// Both folders hold data; nothing is merged or overwritten.
        case conflict
        case failed(String)
    }

    /// The old folder is renamed (same volume, no copy) and replaced by a symbolic link to the new one.
    /// Credentials and sessions move with the folder; nothing is duplicated.
    public static func run(legacy: URL, current: URL, fileManager: FileManager = .default) -> Outcome {
        // `attributesOfItem` does not follow a final symbolic link, so the compatibility link is not mistaken for data.
        guard let type = (try? fileManager.attributesOfItem(atPath: legacy.path))?[.type] as? FileAttributeType,
              type == .typeDirectory else { return .none }
        if (try? fileManager.attributesOfItem(atPath: current.path)) != nil { return .conflict }
        do {
            try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: current)
        } catch {
            return .failed(error.localizedDescription)
        }
        // The data is already in place; a missing link only affects paths recorded under the old name.
        try? fileManager.createSymbolicLink(at: legacy, withDestinationURL: current)
        return .moved
    }
}

/// Copies the app's preferences from the pre-rename bundle id once; the old domain is left as it was.
public enum LegacyPreferencesMigration {
    public static let legacyDomain = "local.daniil.contextdesk"

    @discardableResult
    public static func run(domain: String, legacyDomain: String = legacyDomain, defaults: UserDefaults = .standard) -> Bool {
        guard domain != legacyDomain, (defaults.persistentDomain(forName: domain) ?? [:]).isEmpty,
              let old = defaults.persistentDomain(forName: legacyDomain), !old.isEmpty else { return false }
        defaults.setPersistentDomain(old, forName: domain)
        return true
    }
}
