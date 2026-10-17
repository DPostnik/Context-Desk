import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ContextDesk
import FringeProtocol

private func action(_ kind: AgentInteraction.Kind, details: String = "ls") -> PendingAction {
    PendingAction(interaction: AgentInteraction(id: UUID(), session: AgentSessionReference(connection: .originalCodex, nativeID: "n"),
                                                turn: nil, kind: kind, reason: "Run a command", details: details), threadID: "chat")
}

@Test func fringeRequestsKeepOnlyWhatThePanelNeeds() {
    let approval = action(.approval(canAllow: true), details: String(repeating: "x", count: 5_000))
    let request = FringeLinkMapping.request(approval)
    #expect(request.id == approval.id)
    #expect(request.chatID == "chat")
    #expect(request.kind == .approval)
    #expect(request.canAllow)
    #expect(request.reason == "Run a command")
    #expect(request.details.count == FringeLinkMapping.detailsLimit)
    #expect(FringeLinkMapping.request(action(.questions([]))).kind == .question)
    #expect(FringeLinkMapping.request(action(.unsupported(message: "?"))).kind == .other)
}

@Test func fringeAnswersOnlyApprovalsTheAgentAllows() {
    let allowed = action(.approval(canAllow: true))
    let denyOnly = action(.approval(canAllow: false))
    let question = action(.questions([]))
    #expect(FringeLinkMapping.response(for: .allowOnce, to: allowed).map { "\($0)" } == "allowOnce")
    #expect(FringeLinkMapping.response(for: .deny, to: denyOnly).map { "\($0)" } == "deny")
    #expect(FringeLinkMapping.response(for: .allowOnce, to: denyOnly) == nil)
    #expect(FringeLinkMapping.response(for: .deny, to: question) == nil)
}

@Test func fringeChatsMapEveryPhase() {
    let now = Date()
    let chats = [NotchChat.Phase.waiting, .working, .finished].map {
        FringeLinkMapping.chat(NotchChat(id: "c", title: "T", project: "P", phase: $0, activity: "a", since: now, updated: now)).phase
    }
    #expect(chats == [.waiting, .working, .finished])
}
