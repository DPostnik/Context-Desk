import ContextCore
import ContextTranscript
import SwiftUI
import AppKit
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: DeskModel?
    let keepAwake = KeepAwake()
    let restart = AppRestartController()
    private var shutdownDeadline: DispatchWorkItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.setActivationPolicy(.regular)
        restart.start(delegate: self)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if restart.terminating { return .terminateLater }
        if model?.anyBusy == true {
            let alert = NSAlert(); alert.messageText = L10n.text("Задача ещё выполняется", "A task is still running")
            alert.informativeText = L10n.text("Выход остановит подключение к Codex и задания Claude Code. Скрыть окно можно без остановки.", "Quitting will close the Codex connection and stop Claude Code tasks. You can hide the window without stopping them.")
            alert.addButton(withTitle: L10n.text("Выйти", "Quit"))
            alert.addButton(withTitle: L10n.text("Остаться", "Stay")).keyEquivalent = "\u{1b}"
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        restart.terminating = true
        AppLog.lifecycle.notice("Quit started (restart requested: \(self.restart.requested, privacy: .public))")
        armShutdownDeadline()
        Task {
            if restart.requested {
                do {
                    guard let model else { throw RestartFailure.unavailable }
                    try await model.store.save(model.state)
                    // Saving suspends; work may have arrived in the meantime.
                    guard model.readyForRestart else {
                        restart.terminating = false
                        disarmShutdownDeadline("work arrived while saving")
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    restart.saveContinuation()
                    try restart.launchHelper()
                } catch {
                    restart.terminating = false
                    restart.cancel()
                    try? FileManager.default.removeItem(at: RestartContinuation.file)
                    disarmShutdownDeadline("restart preparation failed")
                    model?.error = L10n.text("Не удалось подготовить перезапуск: ", "Could not prepare restart: ") + error.localizedDescription
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await model?.shutdown(); sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    // Quit runs in terminateLater state where the app ignores input and Cmd+Q, so a stalled
    // shutdown step would otherwise need Force Quit. The deadline runs off the main thread.
    private func armShutdownDeadline() {
        shutdownDeadline?.cancel()
        let item = DispatchWorkItem(block: Self.exitAfterStalledShutdown)
        shutdownDeadline = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15, execute: item)
    }
    // Nonisolated so the off-main deadline never asserts main-actor isolation.
    nonisolated private static func exitAfterStalledShutdown() {
        AppLog.lifecycle.fault("Shutdown did not finish within 15 s; exiting without the remaining steps")
        _exit(0)
    }
    private func disarmShutdownDeadline(_ reason: String) {
        shutdownDeadline?.cancel(); shutdownDeadline = nil
        AppLog.lifecycle.notice("Quit cancelled: \(reason, privacy: .public)")
    }
    func applicationWillTerminate(_ notification: Notification) { keepAwake.stop() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let threadID = response.notification.request.content.userInfo["threadID"] as? String ?? ""
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        await model?.focusAction(threadID: threadID)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

struct ContextDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DeskModel()
    init() {
        // Establish the app-scoped language before SwiftUI constructs native menus.
        L10n.language.save()
        // Keep native controls and TextKit consistent with the white workspace.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        Window("Context Desk", id: "main") {
            Group {
                if model.isBootstrapping {
                    StartupLoadingView()
                } else {
                    DeskView(model: model)
                }
            }
                .buttonStyle(PointerButtonStyle(base: .automatic))
                .preferredColorScheme(.light)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 900, minHeight: 620)
                .task { delegate.model = model; await model.boot() }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(before: .appTermination) {
                RestartMenu(restart: delegate.restart)
                Divider()
            }
            CommandGroup(replacing: .help) {
                SettingsLink { Text("Язык / Language…") }
            }
            CommandGroup(after: .newItem) {
                Button(L10n.text("Открыть проект…", "Open Project…")) { model.openProject() }.keyboardShortcut("o")
                    .disabled(model.isBootstrapping)
                Button(L10n.text("Новый чат", "New chat")) { model.newChat() }.keyboardShortcut("n")
                    .disabled(model.isBootstrapping || model.selectedProject == nil)
            }
        }
        Settings {
            Group {
                if model.isBootstrapping { StartupLoadingView() }
                else { SettingsView(model: model, keepAwake: delegate.keepAwake) }
            }.buttonStyle(PointerButtonStyle(base: .automatic))
                .preferredColorScheme(.light)
                .environment(\.locale, L10n.locale).frame(width: 720).padding(20)
        }
    }
}

private struct RestartMenu: View {
    @ObservedObject var restart: AppRestartController
    var body: some View {
        Button(restart.requested
               ? L10n.text("Перезапуск ожидает завершения задач…", "Restart waiting for tasks…")
               : L10n.text("Перезапустить после завершения задач", "Restart after tasks finish")) { restart.enqueueRestart() }
            .disabled(restart.requested)
        if !restart.continuationChatIDs.isEmpty {
            Section(L10n.text("Продолжат после перезапуска", "Will continue after restart")) {
                ForEach(restart.continuationChatIDs, id: \.self) { id in
                    Text(restart.continuationTitles[id] ?? id)
                }
            }
        }
        Button(L10n.text("Отменить ожидающий перезапуск", "Cancel pending restart")) { restart.cancel() }
            .disabled(!restart.requested)
    }
}

private struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(L10n.text("Загружаем Context Desk…", "Loading Context Desk…")).font(.headline)
            Text(L10n.text("Подключаемся и проверяем аккаунт", "Connecting and checking your account")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeskPalette.canvas)
        .accessibilityElement(children: .combine)
    }
}
