import Foundation
import ContextCore

extension DeskModel {
    /// Temporary boundary until stage 3 extracts the native Codex adapter.
    func nativeThread(_ appID: String) throws -> String {
        try ConversationIdentity.nativeID(for: appID, in: state)
    }
    func chatIsAvailable(_ appID: String) -> Bool {
        (try? nativeThread(appID)) != nil
    }
}
