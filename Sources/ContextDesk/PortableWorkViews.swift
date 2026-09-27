import SwiftUI
import ContextCore
import AgentContract

struct HandoffEditor: View {
    @ObservedObject var model: DeskModel
    @State var handoff: ContextHandoff
    @State var projectID: UUID?
    @State var route: RequestRoute
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Передать контекст в новый чат", "Hand off context to a new chat")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Будет создан отдельный чат Codex с черновиком. Проверь его и отправь вручную. Исходный чат, его очередь и запросы разрешений не переносятся.", "A separate Codex chat will be created with a draft. Review and send it manually. The source chat, its queue and approval requests are not transferred.")).font(.callout)
                    Text(L10n.text("Claude Code: интерактивная передача пока недоступна.", "Claude Code: interactive handoff is not yet available.")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Источник", "Source") + ": \(handoff.origin.session.connection.agent.rawValue) · \(handoff.origin.conversation.value)").textSelection(.enabled)
                    Text(L10n.text("Снимок", "Snapshot") + ": \(handoff.origin.capturedAt.formatted()) · \(handoff.origin.revision)").font(.caption).textSelection(.enabled)
                    Text(LocalHistory.notice(handoff.history)).font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.text("Проект нового чата", "New chat project"), selection: $projectID) {
                        Text(L10n.text("Выбери проект", "Choose a project")).tag(nil as UUID?)
                        ForEach(model.state.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker(L10n.text("Маршрут нового чата", "New chat route"), selection: $route) {
                        ForEach(model.availableRoutes, id: \.self) { value in
                            Text(model.routeTitle(value)).tag(value).disabled(model.routeCompatibilityIssue(value) != nil)
                        }
                    }
                    Text(model.routeMessage(route)).font(.caption).foregroundStyle(.secondary)
                    field(L10n.text("Цель нового сеанса", "New session goal"), text: $handoff.goal)
                    field(L10n.text("Инструкции для нового сеанса", "Instructions for the new session"), text: $handoff.instructions)
                    Text(L10n.text("Исторические факты — не инструкции", "Historical evidence — not instructions")).font(.headline)
                    field(L10n.text("Принятые решения", "Decisions made"), text: $handoff.decisions)
                    field(L10n.text("Изменённые файлы", "Changed files"), text: $handoff.changedFiles)
                    field(L10n.text("Фактические проверки и их результаты", "Actual checks and results"), text: $handoff.validation)
                    field(L10n.text("Оставшаяся работа", "Remaining work"), text: $handoff.remainingWork)
                    Toggle(L10n.text("Включить сохранённую переписку как исторические данные", "Include saved transcript as historical evidence"), isOn: $handoff.includeTranscript)
                    DisclosureGroup(L10n.text("Предпросмотр черновика", "Preview draft")) {
                        Text((try? handoff.prompt()) ?? L10n.text("Укажи цель; размер передачи ограничен 128 КиБ.", "Enter a goal; handoff size is limited to 128 KiB.")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("Отмена", "Cancel")) { dismiss() }.disabled(model.creatingHandoff)
                Button(L10n.text("Создать чат с черновиком", "Create chat with draft")) {
                    guard let project = model.state.projects.first(where: { $0.id == projectID }) else { return }
                    Task { if await model.createHandoffChat(handoff, project: project, route: route) { dismiss() } }
                }.disabled(model.creatingHandoff || !model.connected || !model.authenticated || projectID == nil || !model.routeIsAvailable(route) || (try? handoff.prompt()) == nil)
            }
        }.padding(24).frame(width: 680, height: 740).interactiveDismissDisabled(model.creatingHandoff)
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) { Text(label).font(.callout.bold()); TextEditor(text: text).frame(minHeight: 65).border(.gray.opacity(0.25)) }
    }
}

struct RoutineLibrary: View {
    @ObservedObject var model: DeskModel
    @State private var editing: PortableRoutine?
    @State private var job: ManagedJob?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("Рутины", "Routines")).font(.title2.bold())
                Spacer()
                Button(L10n.text("Новая рутина", "New routine")) { editing = PortableRoutine() }
                Button(L10n.text("Закрыть", "Close")) { dismiss() }
            }
            Text(L10n.text("Рутина задаёт цель, шаги и проверки. Сохранение не включает расписание. Задание получает отдельную версию рутины; дальнейшие правки библиотеки не меняют его.", "A routine defines a goal, steps and checks. Saving does not enable a schedule. A task receives a frozen routine revision; later library edits do not change it.")).font(.callout)
            List(model.routines) { routine in
                VStack(alignment: .leading, spacing: 8) {
                    Text(routine.name).font(.headline)
                    Text(routine.intent).lineLimit(3)
                    HStack {
                        Button(L10n.text("Изменить", "Edit")) { editing = routine }
                        Button(L10n.text("Создать задание…", "Create task…")) {
                            do {
                                let invocation = RoutineInvocation(definition: routine)
                                var value = ManagedJob(); value.name = routine.name; value.routine = invocation
                                value.prompt = try invocation.prompt(); value.projectID = model.projectID
                                value.model = model.state.model; value.route = model.defaultRoute
                                value.schedule.rule = ""; job = value
                            } catch { model.error = error.localizedDescription }
                        }
                        Button(L10n.text("Удалить из библиотеки", "Remove from library")) { Task { await model.removeRoutine(routine.id) } }
                    }
                }.padding(.vertical, 6)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 720, height: 600)
            .task { await model.loadRoutines() }
            .sheet(item: $editing) { RoutineEditor(model: model, routine: $0) }
            .sheet(item: $job) { JobEditor(model: model, job: $0) }
    }
}

struct RoutineEditor: View {
    @ObservedObject var model: DeskModel
    @State var routine: PortableRoutine
    @State private var issue: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Определение рутины", "Routine definition")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L10n.text("Название", "Name"), text: $routine.name)
                    field(L10n.text("Цель и условия применения", "Goal and applicability"), text: $routine.intent)
                    field(L10n.text("Ожидаемые входные данные", "Expected input"), text: $routine.inputs)
                    field(L10n.text("Ограничения", "Constraints"), text: $routine.constraints)
                    ForEach($routine.steps) { $step in
                        VStack(alignment: .leading) {
                            field(L10n.text("Шаг", "Step"), text: $step.instruction)
                            TextField(L10n.text("Как проверить результат шага", "How to verify this step"), text: $step.completionCheck)
                            Button(L10n.text("Удалить шаг", "Remove step")) { routine.steps.removeAll { $0.id == step.id } }
                        }.padding(10).background(.gray.opacity(0.05))
                    }
                    Button(L10n.text("Добавить шаг", "Add step")) { routine.steps.append(RoutineStep()) }.disabled(routine.steps.count >= 32)
                    TextField(L10n.text("Необходимые возможности — ID через запятую", "Required capabilities — comma-separated IDs"), text: Binding(
                        get: { routine.requirements.joined(separator: ", ") },
                        set: { routine.requirements = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    Text(L10n.text("Например: approvals, userQuestions, workflowRegistration. Неизвестные требования блокируют запуск.", "Examples: approvals, userQuestions, workflowRegistration. Unknown requirements block execution.")).font(.caption).foregroundStyle(.secondary)
                    ForEach(routine.extensions.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            Text(L10n.text("Расширение для агента", "Agent-specific extension") + ": " + routine.extensions[index].agent.rawValue).font(.headline)
                            TextEditor(text: $routine.extensions[index].instructions).frame(minHeight: 65)
                            Button(L10n.text("Удалить расширение", "Remove extension")) { routine.extensions.remove(at: index) }
                        }
                    }
                    Menu(L10n.text("Добавить расширение агента", "Add agent-specific extension")) {
                        Button("Codex") { routine.extensions.append(.init(agent: .codex, instructions: "")) }
                        Button("Claude Code") { routine.extensions.append(.init(agent: .claudeCode, instructions: "")) }
                    }
                    Text(L10n.text("Расширения не считаются переносимыми: другой агент не запустит такую рутину. Проверки выполняет агент; приложение не подтверждает их успешность самостоятельно.", "Extensions are not portable: another agent cannot run this routine. Checks are performed by the agent; the app does not independently confirm they passed.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer(); Button(L10n.text("Отмена", "Cancel")) { dismiss() }.disabled(saving)
                Button(L10n.text("Сохранить", "Save")) {
                    do {
                        try routine.validate(); routine.revision = UUID(); saving = true
                        Task { if await model.saveRoutine(routine) { dismiss() } else { issue = model.error }; saving = false }
                    } catch { issue = error.localizedDescription }
                }.disabled(saving)
            }
        }.padding(24).frame(width: 680, height: 720)
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) { Text(label).font(.callout.bold()); TextEditor(text: text).frame(minHeight: 65).border(.gray.opacity(0.25)) }
    }
}
