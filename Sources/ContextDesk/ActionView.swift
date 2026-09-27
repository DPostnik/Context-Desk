import SwiftUI
import ContextCore
import CodexAdapter

struct ActionView: View {
    let action: PendingAction
    @ObservedObject var model: DeskModel
    @State private var answers: [String: String] = [:]
    @State private var validation: String?
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(action.title, systemImage: "exclamationmark.bubble.fill").font(.headline).foregroundStyle(.blue)
            switch action.interaction.kind {
            case .questions(let fields):
                questionFields(fields)
                answerButton(fields)
            case .form(let message, let fields):
                Text(message).textSelection(.enabled)
                questionFields(fields)
                answerButton(fields)
                declineButton
            case .link(let message, let url):
                Text(message).textSelection(.enabled)
                Link(L10n.text("Открыть страницу инструмента", "Open tool page"), destination: url).pointingHandCursor()
                Button(L10n.text("Действие выполнено", "Action completed")) { submit(.completed) }
                declineButton
            case .unsupported(let message):
                Text(message).textSelection(.enabled)
                unsupportedMessage
                declineButton
            case .approval(let canAllow):
                if let reason = action.interaction.reason { Text(reason).textSelection(.enabled) }
                DisclosureGroup(L10n.text("Детали запроса", "Request details")) {
                    ScrollView { Text(action.interaction.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 160)
                }.disclosureGroupStyle(PointerDisclosureStyle())
                if !canAllow { unsupportedMessage }
                HStack {
                    declineButton
                    if canAllow {
                        Button(L10n.text("Разрешить один раз", "Allow once")) { submit(.allowOnce) }
                            .buttonStyle(PointerButtonStyle(base: .borderedProminent))
                    }
                }
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
        }.textFieldStyle(.roundedBorder).controlSize(.large).padding(16).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).disabled(submitting)
    }
    private var unsupportedMessage: some View {
        Text(L10n.text("Этот запрос нельзя подтвердить в приложении. Его можно отклонить и продолжить разговор.", "This request cannot be approved in the app. You can decline it and continue the conversation.")).font(.caption)
    }
    private var declineButton: some View { Button(L10n.text("Отклонить", "Decline")) { submit(.deny) } }
    private func questionFields(_ fields: [CodexInteraction.Field]) -> some View {
        ForEach(fields) { field in
            Text(field.text).textSelection(.enabled)
            ForEach(field.options, id: \.self) { option in
                Button(option) { answers[field.id] = option }
            }
            if field.secret { SecureField(L10n.text("Твой ответ", "Your answer"), text: binding(field.id)) }
            else { TextField(L10n.text("Твой ответ", "Your answer"), text: binding(field.id)) }
        }
    }
    private func answerButton(_ fields: [CodexInteraction.Field]) -> some View {
        Button(L10n.text("Ответить", "Submit answer")) {
            guard fields.allSatisfy({ !$0.required || !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                validation = L10n.text("Заполни обязательные поля", "Fill in the required fields"); return
            }
            submit(.answers(answers))
        }.buttonStyle(PointerButtonStyle(base: .borderedProminent))
    }
    private func binding(_ id: String) -> Binding<String> { Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }) }
    private func submit(_ value: CodexInteractionResponse) {
        submitting = true
        Task { await model.answer(action, result: value); submitting = false }
    }
}
