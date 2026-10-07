import AppKit
import ContextCore

enum RestartFailure: LocalizedError {
    case unavailable
    var errorDescription: String? {
        L10n.text("Перезапуск доступен только из собранного приложения.", "Restart is available only from the built app bundle.")
    }
}

/// A same-login-session request channel. It accepts no commands, paths or approval overrides.
@MainActor enum RestartCommand {
    static let notification = Notification.Name("local.daniil.contextdesk.restart-when-idle.v1")

    static func run(arguments: [String]) -> Bool {
        guard arguments.dropFirst().first == "--request-restart" else { return false }
        guard arguments.count == 2, Bundle.main.bundleURL.pathExtension == "app",
              NSWorkspace.shared.runningApplications.contains(where: {
                  $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                  $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
              }) else {
            fputs(L10n.text("Работающий экземпляр этого приложения не найден.\n", "No running instance of this app bundle was found.\n"), stderr)
            exit(1)
        }
        DistributedNotificationCenter.default().postNotificationName(notification,
            object: Bundle.main.bundleURL.standardizedFileURL.path, userInfo: nil, deliverImmediately: true)
        print(L10n.text("Запрос отправлен. Приложение перезапустится после завершения задач. Доставка не подтверждена; не повторяйте запрос автоматически.",
                        "Request sent. The app will restart after tasks finish. Delivery is not acknowledged; do not automatically retry."))
        return true
    }
}

@MainActor final class AppRestartController: NSObject, ObservableObject {
    private weak var delegate: AppDelegate?
    private var timer: Timer?
    @Published private(set) var requested = false
    var terminating = false

    // Positional arguments keep bundle paths out of shell source. Never kill or reopen a live owner.
    nonisolated static let helperScript = """
    count=0
    while /bin/kill -0 "$1" 2>/dev/null; do
        count=$((count + 1))
        if [ "$count" -ge 120 ]; then exit 1; fi
        /bin/sleep 1
    done
    /usr/bin/open "$2"
    """

    func start(delegate: AppDelegate) {
        self.delegate = delegate
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
            name: RestartCommand.notification, object: Bundle.main.bundleURL.standardizedFileURL.path)
    }

    @objc private func receive(_ notification: Notification) { enqueueRestart() }

    func enqueueRestart() {
        guard !requested, !terminating else { return }
        requested = true
        // Leave the requesting tool time to return before examining the host's busy state.
        // terminate() must run from the run loop, not from a main-actor job: with .terminateLater it
        // spins a nested run loop until the delegate's Task replies, and that Task cannot start
        // while the serial main queue is still inside the job that called terminate().
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfIdle() }
        }
    }

    func cancel() {
        guard !terminating else { return }
        requested = false; timer?.invalidate(); timer = nil
    }

    private func restartIfIdle() {
        guard requested, !terminating, let model = delegate?.model,
              model.readyForRestart else { return }
        NSApplication.shared.terminate(nil)
    }

    func launchHelper() throws {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", FileManager.default.isExecutableFile(
            atPath: bundle.appendingPathComponent("Contents/MacOS/ContextDesk").path) else { throw RestartFailure.unavailable }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", Self.helperScript, "contextdesk-relaunch",
                            String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        timer?.invalidate(); timer = nil
    }
}

extension DeskModel {
    var readyForRestart: Bool {
        !isBootstrapping && !anyBusy && !connecting && !claudeConnecting && pending.isEmpty
    }
}
