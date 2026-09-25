import Foundation

/// Persist the provider identifier, including identifiers whose plugin is absent.
public struct RequestRoute: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let direct = Self(rawValue: "direct")
    public var providerID: String { self == .direct ? "openai" : "contextdesk_" + rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
