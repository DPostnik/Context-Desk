import Foundation
import ContextCore
import AgentContract

extension AccessMode {
    public var threadParameters: [String: JSONValue] {
        ["approvalPolicy": .string(self == .fullAccess ? "never" : "on-request"),
         "sandbox": .string(self == .fullAccess ? "danger-full-access" : "workspace-write")]
    }
    public func turnParameters(projectPath: String) -> [String: JSONValue] {
        ["approvalPolicy": threadParameters["approvalPolicy"]!,
         "sandboxPolicy": self == .fullAccess
            ? .object(["type": .string("dangerFullAccess")])
            : .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(projectPath)]), "networkAccess": .bool(false)])]
    }
}

extension ProviderPlugin {
    public func providerArguments(endpoint: URL) throws -> [String] {
        try CodexOptimizerConfiguration.arguments(id: id, endpoint: endpoint)
    }
}

enum CodexOptimizerConfiguration {
    static func arguments(id: String, endpoint: URL) throws -> [String] {
        guard id != "direct", id.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil else { throw ConversationIdentity.unavailable }
        guard endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let port = endpoint.port, (1...65535).contains(port),
              endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.user == nil, endpoint.password == nil else { throw ClientFailure(L10n.text("Плагин должен использовать локальный адрес", "The plugin must use a local address")) }
        // Plugins expose Responses proxies. They cannot supply arbitrary Codex settings.
        let prefix = "model_providers." + RequestRoute(rawValue: id).providerID
        let values = ["\(prefix).name=\"OpenAI\"", "\(prefix).base_url=\"http://127.0.0.1:\(port)/v1\"",
                      "\(prefix).wire_api=\"responses\"", "\(prefix).requires_openai_auth=true",
                      "\(prefix).supports_websockets=true", "\(prefix).request_max_retries=0", "\(prefix).stream_max_retries=0"]
        return values.flatMap { ["-c", $0] }
    }
}

extension RequestRoute {
    public var providerID: String { self == .direct ? "openai" : "contextdesk_" + rawValue }
}
