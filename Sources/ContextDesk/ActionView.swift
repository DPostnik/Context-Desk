import SwiftUI
import ContextCore

struct ActionView: View {
    let action: PendingAction
    @ObservedObject var model: DeskModel
    @State private var answers: [String: String] = [:]
    @State private var validation: String?
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(action.title, systemImage: "exclamationmark.bubble.fill").font(.headline).foregroundStyle(.blue)
            if action.method == "item/tool/requestUserInput" {
                ForEach(action.params["questions"].array, id: \.self) { q in
                    let id = q["id"].string ?? ""
                    Text(q["question"].string ?? L10n.text("Вопрос", "Question")).textSelection(.enabled)
                    ForEach(q["options"].array, id: \.self) { option in
                        Button(option["label"].string ?? L10n.text("Выбрать", "Select")) { answers[id] = option["label"].string ?? "" }
                    }
                    if q["isSecret"].bool == true { SecureField(L10n.text("Твой ответ", "Your answer"), text: binding(id)) }
                    else { TextField(L10n.text("Твой ответ", "Your answer"), text: binding(id)) }
                }
                Button(L10n.text("Ответить", "Submit answer")) {
                    let questions = action.params["questions"].array
                    guard questions.allSatisfy({ !(answers[$0["id"].string ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        validation = L10n.text("Ответь на все вопросы", "Answer all questions"); return
                    }
                    let values = questions.reduce(into: [String: JSONValue]()) { result, q in
                        let id = q["id"].string ?? ""; result[id] = .object(["answers": .array([.string(answers[id] ?? "")])])
                    }
                    submit(.object(["answers": .object(values)]))
                }.buttonStyle(PointerButtonStyle(base: .borderedProminent))
            } else if action.method == "mcpServer/elicitation/request" {
                Text(action.params["message"].string ?? L10n.text("Инструменту нужен ответ", "The tool needs your input"))
                if action.params["mode"].string == "url", let urlText = action.params["url"].string, let url = URL(string: urlText), url.scheme == "https" {
                    Link(L10n.text("Открыть страницу инструмента", "Open tool page"), destination: url).pointingHandCursor()
                    Button(L10n.text("Действие выполнено", "Action completed")) { submit(.object(["action": .string("accept")])) }
                } else {
                    let fields = action.params["requestedSchema"]["properties"].object
                    if action.params["requestedSchema"]["type"].string == "object", fields.values.allSatisfy({ $0["type"].string == "string" }) {
                        ForEach(fields.keys.sorted(), id: \.self) { id in
                            TextField(fields[id]?["title"].string ?? id, text: binding(id))
                        }
                        Button(L10n.text("Ответить", "Submit answer")) {
                            let required = action.params["requestedSchema"]["required"].array.compactMap(\.string)
                            guard required.allSatisfy({ !(answers[$0] ?? "").isEmpty }) else { validation = L10n.text("Заполни обязательные поля", "Fill in the required fields"); return }
                            submit(.object(["action": .string("accept"), "content": .object(answers.mapValues { .string($0) })]))
                        }
                    } else { Text(L10n.text("Эта форма пока не поддерживается. Её можно отклонить и продолжить разговор.", "This form is not supported yet. You can decline it and continue the conversation.")).font(.caption) }
                }
                Button(L10n.text("Отклонить", "Decline")) { submit(.object(["action": .string("decline")])) }
            } else {
                if let reason = action.params["reason"].string { Text(reason).textSelection(.enabled) }
                DisclosureGroup(L10n.text("Детали запроса", "Request details")) {
                    ScrollView { Text(action.params.display).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 160)
                }
                HStack {
                    Button(L10n.text("Отклонить", "Decline")) {
                        submit(action.method.contains("permissions") ? .object(["permissions": .object([:]), "scope": .string("turn")]) : .object(["decision": .string("decline")]))
                    }
                    Button(L10n.text("Разрешить один раз", "Allow once")) {
                        submit(action.method.contains("permissions") ? .object(["permissions": action.params["permissions"], "scope": .string("turn")]) : .object(["decision": .string("accept")]))
                    }.buttonStyle(PointerButtonStyle(base: .borderedProminent))
                }
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
        }.textFieldStyle(.roundedBorder).controlSize(.large).padding(16).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).disabled(submitting)
    }
    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
    private func submit(_ value: JSONValue) {
        submitting = true
        Task { await model.answer(action, result: value); submitting = false }
    }
}
