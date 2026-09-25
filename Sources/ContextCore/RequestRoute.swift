import Foundation

public enum RequestRoute: String, Codable, CaseIterable, Sendable {
    case direct, headroom
    public var title: String { self == .headroom ? L10n.text("Через Headroom", "Via Headroom") : L10n.text("Напрямую", "Direct") }
    public var providerID: String { self == .headroom ? "contextdesk_headroom" : "openai" }

}
