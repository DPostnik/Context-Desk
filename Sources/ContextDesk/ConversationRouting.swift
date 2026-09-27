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
        try ConversationIdentity.nativeID(for: appID, in: state)
    }
    func chatIsAvailable(_ appID: String) -> Bool {
        (try? nativeThread(appID)) != nil
    }
}
