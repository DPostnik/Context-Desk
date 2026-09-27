import SwiftUI
import ContextCore

struct JobsView: View {
    @ObservedObject var model: DeskModel
    @State private var selection: String?
    @State private var editing: ManagedJob?
    @State private var deleting: ManagedJob?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("Задания по расписанию", "Scheduled tasks")).font(.headline)
                Spacer()
                Button(L10n.text("Обновить", "Refresh")) { Task { await model.refreshJobs() } }
                Button(L10n.text("Создать", "New task"), systemImage: "plus") {
                    var job = ManagedJob(); job.projectID = model.projectID; job.model = model.state.model; job.route = model.defaultRoute; editing = job
                }.disabled(!model.schedulerReady)
            }.padding()
            Text(model.schedulerReady
                 ? L10n.text("Запуски работают, пока Context Desk открыт и Mac не спит. После простоя выполняется одно пропущенное задание. До трёх запусков одновременно.", "Tasks run while Context Desk is open and your Mac is awake. After downtime, each due task runs once. Up to three runs at a time.")
                 : L10n.text("Планировщик недоступен. Проверь сообщение об ошибке и перезапусти приложение.", "The scheduler is unavailable. Check the error and restart the app."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom)
            Divider()
            HSplitView {
                List(selection: $selection) {
                    Section("Context Desk") {
                        ForEach(model.jobLedger.jobs) { job in
                            VStack(alignment: .leading) {
                                Text(job.name)
                                Text(job.engine.title + " · " + (job.enabled ? L10n.text("Включено", "Enabled") : L10n.text("Пауза", "Paused"))).font(.caption).foregroundStyle(.secondary)
                            }.tag(job.id.uuidString)
                        }
                    }
                    Section(L10n.text("Доступны для импорта", "Available to import")) {
                        ForEach(model.jobs) { job in
                            VStack(alignment: .leading) { Text(job.name); Text(job.engine.title).font(.caption).foregroundStyle(.secondary) }.tag("source:" + job.id)
                        }
                    }
                }.frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
                if let job = model.jobLedger.jobs.first(where: { $0.id.uuidString == selection }) {
                    managedDetail(job)
                } else if let source = model.jobs.first(where: { "source:" + $0.id == selection }) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(L10n.text("Импорт создаёт отдельное задание. Исходное расписание останется без изменений.", "Import creates a separate task. The original schedule stays unchanged.")).font(.caption)
                            Spacer()
                            Button(L10n.text("Импортировать…", "Import…")) { editing = model.importedJob(source) }.disabled(!model.schedulerReady || source.prompt.isEmpty)
                        }.padding()
                        JobDetail(job: source)
                    }
                } else {
                    EmptyState(icon: "calendar", title: L10n.text("Расписание", "Schedule"), text: L10n.text("Создай задание или выбери существующее для импорта.", "Create a task or select an existing one to import."))
                }
            }
        }
        .sheet(item: $editing) { job in JobEditor(model: model, job: job) }
        .confirmationDialog(L10n.text("Удалить задание и историю его запусков?", "Delete this task and its run history?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("Удалить", "Delete"), role: .destructive) { if let job = deleting { Task { await model.deleteJob(job.id) } }; deleting = nil }
        }
    }
    private func jobDate(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: date)
    }
    private func managedDetail(_ job: ManagedJob) -> some View {
        let active = model.jobLedger.runs.first { $0.jobID == job.id && $0.status.active }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(job.name).font(.title2.bold())
                HStack {
                    Button(L10n.text("Запустить сейчас", "Run now")) { Task { await model.launchJob(job.id) } }.disabled(active != nil || !model.schedulerReady || model.jobLedger.runs.filter { $0.status.active }.count >= 3)
                    Button(job.enabled ? L10n.text("Пауза", "Pause") : L10n.text("Включить", "Enable")) { Task { await model.toggleJob(job) } }.disabled(active != nil || !model.schedulerReady || (job.schedule.rule.isEmpty && job.schedule.once == nil))
                    Button(L10n.text("Изменить", "Edit")) { editing = job }.disabled(active != nil || !model.schedulerReady)
                    Button(role: .destructive) { deleting = job } label: { Image(systemName: "trash") }.disabled(active != nil || !model.schedulerReady)
                }
                LabeledContent(L10n.text("Исполнитель", "Agent"), value: job.engine.title)
                LabeledContent(L10n.text("Проект", "Project"), value: model.state.projects.first { $0.id == job.projectID }?.path ?? L10n.text("Недоступен", "Unavailable"))
                LabeledContent(L10n.text("Часовой пояс", "Time zone"), value: job.schedule.timeZone)
                if let next = job.nextRun, job.enabled { LabeledContent(L10n.text("Следующий запуск", "Next run")) { Text(jobDate(next, zone: job.schedule.timeZone)).textSelection(.enabled) } }
                Text(job.schedule.once != nil ? L10n.text("Однократно", "Once") : job.schedule.rule.isEmpty ? L10n.text("Только вручную", "Manual only") : ScheduledJobs.readableSchedule(job.schedule.rule)).font(.callout).textSelection(.enabled)
                if job.engine == .codex {
                    Text(L10n.text("Каждый запуск создаёт новый чат с текущими разрешениями проекта.", "Each run creates a new chat using the project's current permissions.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Claude Code использует существующий вход и правила разрешений CLI. Новые запросы разрешений отклоняются; результат сохраняется здесь. Требуется версия \(ClaudeJobRunner.version).", "Claude Code uses existing CLI sign-in and permission rules. New permission requests are denied; results are saved here. Version \(ClaudeJobRunner.version) is required.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(job.prompt).textSelection(.enabled)
                Divider()
                Text(L10n.text("История запусков", "Run history")).font(.headline)
                ForEach(model.jobLedger.runs.filter { $0.jobID == job.id }) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(run.started.formatted()).font(.callout)
                            Text(run.status.title).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if run.status.active { Button(L10n.text("Остановить", "Stop")) { Task { await model.stopJob(run) } } }
                            if let id = run.threadID, let chat = model.state.chats.first(where: { $0.id == id }) {
                                Button(L10n.text("Открыть чат", "Open chat")) { Task { await model.openChat(chat) } }
                            }
                        }
                        if !run.output.isEmpty { Text(run.output).textSelection(.enabled) }
                        if run.status == .uncertain { Text(L10n.text("Проверь результат перед новым запуском. Автоматического повтора не было; расписание приостановлено.", "Check the outcome before running again. No automatic retry was made; the schedule is paused.")).font(.caption).foregroundStyle(.orange) }
                    }.padding().background(.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct JobEditor: View {
    @ObservedObject var model: DeskModel
    @State var job: ManagedJob
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var validation: String?
    @State private var mode: String
    init(model: DeskModel, job: ManagedJob) {
        self.model = model; self._job = State(initialValue: job)
        self._mode = State(initialValue: job.schedule.once != nil ? "once" : job.schedule.rule.isEmpty ? "manual" : "rule")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Задание", "Task")).font(.title2.bold())
            ScrollView {
            Form {
                TextField(L10n.text("Название", "Name"), text: $job.name)
                Picker(L10n.text("Исполнитель", "Agent"), selection: $job.engine) { ForEach(JobEngine.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .onChange(of: job.engine) { _, _ in job.model = ""; job.effort = ""; job.route = .direct }
                Picker(L10n.text("Проект", "Project"), selection: $job.projectID) {
                    Text(L10n.text("Выбери проект", "Choose a project")).tag(nil as UUID?)
                    ForEach(model.state.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField(L10n.text("Модель", "Model"), text: $job.model, prompt: Text(L10n.text("По умолчанию", "Default")))
                if job.engine == .codex {
                    Picker(L10n.text("Маршрут", "Route"), selection: $job.route) { ForEach(model.availableRoutes, id: \.self) { Text(model.routeTitle($0)).tag($0) } }
                    TextField(L10n.text("Рассуждение", "Reasoning effort"), text: $job.effort, prompt: Text(L10n.text("По умолчанию", "Default")))
                }
                Picker(L10n.text("Расписание", "Schedule"), selection: $mode) {
                    Text(L10n.text("Повторять", "Repeat")).tag("rule")
                    Text(L10n.text("Однократно", "Once")).tag("once")
                    Text(L10n.text("Вручную", "Manual")).tag("manual")
                }.onChange(of: mode) { _, value in
                    if value == "once" { job.schedule.once = Date().addingTimeInterval(3600) }
                    else { job.schedule.once = nil }
                    if value == "manual" { job.schedule.rule = ""; job.enabled = false }
                    if value == "rule" && job.schedule.rule.isEmpty { job.schedule.rule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0" }
                }
                if mode == "once" {
                    DatePicker(L10n.text("Дата и время", "Date and time"), selection: Binding(get: { job.schedule.once ?? Date() }, set: { job.schedule.once = $0 })).environment(\.timeZone, TimeZone(identifier: job.schedule.timeZone) ?? .current)
                } else if mode == "rule" {
                    HStack {
                        Button(L10n.text("Каждый час", "Hourly")) { job.schedule.rule = "FREQ=HOURLY;INTERVAL=1" }
                        Button(L10n.text("Ежедневно", "Daily")) { job.schedule.rule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0" }
                        Button(L10n.text("Будни", "Weekdays")) { job.schedule.rule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0" }
                    }
                    if simpleDailyTime {
                        DatePicker(L10n.text("Время запуска", "Run at"), selection: scheduleTime, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, TimeZone(identifier: job.schedule.timeZone) ?? .current)
                    }
                    if intervalFrequency != nil {
                        Stepper(value: scheduleInterval, in: 1...1440) {
                            Text(intervalFrequency == "HOURLY"
                                 ? L10n.text("Каждые \(scheduleInterval.wrappedValue) ч.", "Every \(scheduleInterval.wrappedValue) hr")
                                 : L10n.text("Каждые \(scheduleInterval.wrappedValue) мин.", "Every \(scheduleInterval.wrappedValue) min"))
                        }
                    }
                    DisclosureGroup(L10n.text("Точное правило расписания", "Exact schedule rule")) {
                        TextField("RRULE", text: $job.schedule.rule)
                        Text(L10n.text("Минуты: FREQ=MINUTELY;INTERVAL=15. Дни недели: MO,TU,WE,TH,FR,SA,SU. Можно указать несколько часов через запятую.", "Minutes: FREQ=MINUTELY;INTERVAL=15. Weekdays: MO,TU,WE,TH,FR,SA,SU. Multiple hours can be separated by commas.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField(L10n.text("Часовой пояс", "Time zone"), text: $job.schedule.timeZone)
                if job.source != nil {
                    Text(L10n.text("Импорт переносит только инструкции. История исходного чата, рабочие деревья и разрешения не переносятся. Проверь проект, модель, время и часовой пояс. Перед включением отключи исходное расписание.", "Import transfers instructions only. Source chat history, worktrees and permissions are not transferred. Review the project, model, time and time zone. Disable the original schedule before enabling this one.")).font(.caption)
                    Toggle(L10n.text("Исходное расписание отключено", "I disabled the original schedule"), isOn: $job.sourceDisabled)
                }
                Toggle(L10n.text("Включить расписание", "Enable schedule"), isOn: $job.enabled).disabled(mode == "manual")
            }
            Text(L10n.text("Инструкции", "Instructions")).font(.headline)
            TextEditor(text: $job.prompt).font(.body).frame(minHeight: 120).border(.gray.opacity(0.3))
            if let validation { Text(validation).foregroundStyle(.red).font(.caption) }
            }
            HStack {
                Spacer()
                Button(L10n.text("Отмена", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Сохранить", "Save")) {
                    do {
                        try job.validate()
                        if job.enabled, let once = job.schedule.once, once <= Date() { throw JobSchedule.invalid }
                        saving = true
                        Task { if await model.saveJob(job) { dismiss() } else { validation = model.error }; saving = false }
                    } catch { validation = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 640, height: 700)

    }
    private var ruleFields: [String: String] {
        let rule = job.schedule.rule.replacingOccurrences(of: "RRULE:", with: "")
        return rule.split(separator: ";").reduce(into: [:]) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
    }
    private var simpleDailyTime: Bool {
        ["DAILY", "WEEKLY"].contains(ruleFields["FREQ"] ?? "") && Int(ruleFields["BYHOUR"] ?? "") != nil && Int(ruleFields["BYMINUTE"] ?? "") != nil
    }
    private var intervalFrequency: String? {
        let fields = ruleFields
        return Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL"]) && ["HOURLY", "MINUTELY"].contains(fields["FREQ"] ?? "") ? fields["FREQ"] : nil
    }
    private var scheduleInterval: Binding<Int> {
        Binding(get: { Int(ruleFields["INTERVAL"] ?? "1") ?? 1 }, set: { job.schedule.rule = "FREQ=" + (intervalFrequency ?? "HOURLY") + ";INTERVAL=\($0)" })
    }
    private var scheduleTime: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: job.schedule.timeZone) ?? .current
            return calendar.date(bySettingHour: Int(ruleFields["BYHOUR"] ?? "9") ?? 9, minute: Int(ruleFields["BYMINUTE"] ?? "0") ?? 0, second: 0, of: Date()) ?? Date()
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: job.schedule.timeZone) ?? .current
            var fields = ruleFields; fields["BYHOUR"] = String(calendar.component(.hour, from: date)); fields["BYMINUTE"] = String(calendar.component(.minute, from: date))
            job.schedule.rule = fields.keys.sorted().map { $0 + "=" + fields[$0]! }.joined(separator: ";")
        })
    }

}
