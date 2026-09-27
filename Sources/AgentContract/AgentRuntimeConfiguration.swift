import Foundation

/// Validated optimizer endpoints, not native engine launch flags.
public struct AgentOptimizerEndpoint: Sendable {
    public let id: String
    public let endpoint: URL
    public init(id: String, endpoint: URL) { self.id = id; self.endpoint = endpoint }
}

public struct AgentConnectionConfiguration: Sendable {
    public let executable: URL?
    public let home: URL
    public let resources: URL?
    public let browserEnabled: Bool
    public let optimizers: [AgentOptimizerEndpoint]
    public init(executable: URL? = nil, home: URL, resources: URL? = nil, browserEnabled: Bool = false,
                optimizers: [AgentOptimizerEndpoint] = []) {
        self.executable = executable; self.home = home; self.resources = resources
        self.browserEnabled = browserEnabled; self.optimizers = optimizers
    }
}

public struct AgentSummaryFragment: Codable, Sendable {
    public let reference: String
    public let kind: String
    public let text: String
    public init(reference: String, kind: String, text: String) { self.reference = reference; self.kind = kind; self.text = text }
}

public struct AgentSummarySource: Sendable {
    public let digest: String
    public let fragments: [AgentSummaryFragment]
    public let turnDates: [String: Double]
    public let omittedDetails: Bool
    public init(digest: String, fragments: [AgentSummaryFragment], turnDates: [String: Double], omittedDetails: Bool) {
        self.digest = digest; self.fragments = fragments; self.turnDates = turnDates; self.omittedDetails = omittedDetails
    }
}

public struct AgentGenerationEnvironment: Sendable {
    public let executable: URL?
    public let home: URL
    public let workspace: URL
    public let recipeDirectory: URL?
    public init(executable: URL?, home: URL, workspace: URL, recipeDirectory: URL? = nil) {
        self.executable = executable; self.home = home; self.workspace = workspace; self.recipeDirectory = recipeDirectory
    }
}
