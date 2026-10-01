import Foundation

/// Exact engine builds checked against the adapter contract; never accept a version range.
enum CodexProtocolCompatibility {
    static let currentVersion = "0.159.2"
    static let supportedVersions = ["0.158.0-alpha.2.1", "0.159.0", currentVersion]

    static func accepts(userAgent: String) -> Bool {
        // initialize identifies the client first, then the engine version. Ignore later
        // platform/client metadata so it cannot accidentally satisfy the version gate.
        guard let product = userAgent.split(separator: " ").first,
              let separator = product.firstIndex(of: "/"), separator != product.startIndex else { return false }
        return supportedVersions.contains(String(product[product.index(after: separator)...]))
    }
}
