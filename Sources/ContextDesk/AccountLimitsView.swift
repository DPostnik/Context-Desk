import SwiftUI
import ContextCore

struct AccountLimitsView: View {
    @ObservedObject var model: DeskModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.text("Доступный usage", "Available usage"), systemImage: "chart.bar").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Закрыть", "Close")).keyboardShortcut(.cancelAction)
            }
            Text(L10n.text("Лимиты Codex общие для аккаунта во всех приложениях. Контекст отдельного чата показан рядом с полем сообщения.", "Codex limits are shared across all apps on your account. Each chat’s context usage is shown next to the message field."))
                .font(.callout).foregroundStyle(.secondary)
            if !model.authenticated {
                Text(L10n.text("Войди в ChatGPT в настройках приложения, чтобы увидеть лимиты.", "Sign in with ChatGPT in the app’s settings to see your limits."))
            } else {
                if !model.connected { Label(L10n.text("Нет подключения. Данные могут быть устаревшими.", "Disconnected. Data may be out of date."), systemImage: "wifi.slash") }
                if let issue = model.limitsError {
                    Label(issue, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
                }
                if let snapshot = model.accountLimits {
                    if snapshot.ordinaryUsageAllowed == false {
                        Text(L10n.text("Сервис сообщает, что обычное использование сейчас недоступно.", "The service reports that ordinary usage is currently unavailable.")).font(.callout)
                    }
                    if snapshot.buckets.isEmpty { Text(L10n.text("Сервис пока не передал данные о лимитах.", "The service has not provided limit data yet.")).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(snapshot.buckets) { bucket in
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(bucket.name).font(.headline)
                                    if bucket.windows.isEmpty { Text(L10n.text("Данные о периодах лимита не переданы.", "No limit window data provided.")).foregroundStyle(.secondary) }
                                    ForEach(bucket.windows) { window in windowRow(window) }
                                }.padding(16).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }.frame(maxHeight: 340)
                    Text(L10n.text("Проверено: \(localDate(snapshot.fetchedAt))", "Checked: \(localDate(snapshot.fetchedAt))"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.refreshingLimits {
                    ProgressView(L10n.text("Проверяю лимиты…", "Checking limits…")).padding(.vertical)
                } else if model.limitsError == nil {
                    Text(L10n.text("Данные о лимитах пока не получены.", "Limit data has not been received yet.")).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(L10n.text("Время: \(TimeZone.current.identifier)", "Time zone: \(TimeZone.current.identifier)")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.refreshingLimits && model.accountLimits != nil { ProgressView().controlSize(.small) }
                Button(L10n.text("Обновить", "Refresh")) { Task { await model.refreshLimits() } }
                    .disabled(model.refreshingLimits || !model.connected || !model.authenticated)
            }
        }.padding(24).frame(width: 480)
            .buttonStyle(PointerButtonStyle(base: .automatic))
            .task { await model.refreshLimits() }
    }

    private func windowRow(_ window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.title)
                Spacer()
                Text(window.remainingPercent.map { L10n.text("\($0)% осталось", "\($0)% remaining") } ?? L10n.text("Нет данных", "No data")).monospacedDigit()
            }
            if let remaining = window.remainingPercent {
                ProgressView(value: Double(remaining), total: 100).tint(remaining <= 10 ? .orange : .blue)
                    .accessibilityLabel(L10n.text("\(window.title): осталось \(remaining)%", "\(window.title): \(remaining)% remaining"))
            }
            if let reset = window.resetsAt {
                Text(L10n.text("Обновление: \(localDate(reset))", "Resets: \(localDate(reset))"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("Время обновления неизвестно", "Reset time unknown")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func localDate(_ date: Date) -> String {
        L10n.date(date)
    }
}
