import Foundation
import ContextCore
import AgentContract

extension DeskModel {
    func sessionForChat(_ appID: String) throws -> AgentSessionReference {
        _ = try nativeThread(appID)
        guard let session = state.chats.first(where: { $0.id == appID })?.nativeSession else {
            throw ConversationIdentity.unavailable
        }
        return session
    }
    /// Application identity ownership remains independent of the native event decoder.
    func nativeThread(_ appID: String) throws -> String {
        guard let session = state.chats.first(where: { $0.id == appID })?.nativeSession,
              [.originalCodex, .appClaude].contains(session.connection) else { throw ConversationIdentity.unavailable }
        return try ConversationIdentity.nativeID(for: appID, in: state, connection: session.connection)
    }
    func chatIsAvailable(_ appID: String) -> Bool {
        (try? nativeThread(appID)) != nil
    }
    func clientForChat(_ id: String) throws -> AgentClient {
        let session = try sessionForChat(id)
        return session.connection == .appClaude ? claudeConnection : connection
    }
    func chatConnected(_ id: String) -> Bool {
        state.chats.first(where: { $0.id == id })?.nativeSession?.connection == .appClaude ? claudeConnected : connected
    }
    func chatAuthenticated(_ id: String) -> Bool {
        state.chats.first(where: { $0.id == id })?.nativeSession?.connection == .appClaude ? claudeAuthenticated : authenticated
    }
    var currentAgent: AgentConnectionID { selectedChat?.nativeSession?.connection ?? state.defaultConnection ?? .originalCodex }
    var currentAgentName: String { currentAgent == .appClaude ? "Claude" : "Codex" }
    var currentAgentConnected: Bool { currentAgent == .appClaude ? claudeConnected : connected }
    var currentAgentAuthenticated: Bool { currentAgent == .appClaude ? claudeAuthenticated : authenticated }
    var currentModel: String {
        // Claude has an app default, so a blank value never reaches the CLI as "its own choice".
        if currentAgent == .appClaude { return ClaudeModel.resolved(selectedChat?.model ?? state.claudeModel) }
        return selectedChat?.model ?? state.model
    }
    func selectCurrentModel(_ value: String) {
        if currentAgent == .appClaude {
            if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].model = value }
            else { state.claudeModel = value }
            saveAgentChoice()
        } else { selectModel(value) }
    }
    /// Claude keeps its own effort so the Codex default never leaks into a Claude session.
    /// An unset or blank value resolves to the app default level.
    var claudeEffort: String { ClaudeEffort.resolved(selectedChat?.effort ?? state.claudeEffort) }
    func selectClaudeEffort(_ value: String) {
        guard currentAgent == .appClaude, ClaudeEffort.isDispatchable(value) else { return }
        if let index = state.chats.firstIndex(where: { $0.id == chatID }) { state.chats[index].effort = value }
        else { state.claudeEffort = value }
        saveAgentChoice()
    }
}
