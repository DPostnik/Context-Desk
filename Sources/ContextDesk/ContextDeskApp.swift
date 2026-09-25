import ContextCore
import ContextTranscript
import SwiftUI
import AppKit
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: DeskModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.setActivationPolicy(.regular)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.anyBusy == true {
            let alert = NSAlert(); alert.messageText = L10n.text("Задача ещё выполняется", "A task is still running")
            alert.informativeText = L10n.text("Выход остановит подключение к Codex. Скрыть окно можно без остановки.", "Quitting will close the Codex connection. You can hide the window without stopping it.")
            alert.addButton(withTitle: L10n.text("Остаться", "Stay")); alert.addButton(withTitle: L10n.text("Выйти", "Quit"))
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        Task { await model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
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

@main struct ContextDeskApp: App {
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
                else { SettingsView(model: model) }
            }.buttonStyle(PointerButtonStyle(base: .automatic))
                .preferredColorScheme(.light)
                .environment(\.locale, L10n.locale).frame(width: 520).padding(24)
        }
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
