import AppKit
import SwiftUI
import ContextCore

/// Controls are bound to the saved native session, never the currently focused window.
struct ChatBrowserControls: View {
    let session: String
    let busy: Bool
    @State private var running: Bool?
    @State private var operating = false
    @State private var error: String?
    @State private var importingCookies = false

    var body: some View {
        Menu {
            Text(running == true ? L10n.text("Браузер открыт", "Browser is open") :
                 running == false ? L10n.text("Браузер закрыт", "Browser is closed") :
                 L10n.text("Состояние не проверено", "Status not checked"))
            Button(L10n.text("Показать браузер", "Show browser")) { perform(show: true) }
            Button(L10n.text("Проверить состояние", "Check status")) { perform() }
            Button(L10n.text("Закрыть браузер", "Close browser")) { perform(close: true) }
                .disabled(busy)
            Divider()
            Button(L10n.text("Импортировать входы из Chrome…", "Import sign-ins from Chrome…")) { importingCookies = true }
                .disabled(busy)
            Text(L10n.text("Следующее обращение агента откроет новый сеанс с тем же профилем.",
                           "The next explicit browser open starts a new session with the same profile."))
        } label: {
            Label(L10n.text("Браузер", "Browser"), systemImage: "globe")
        }
        .disabled(operating)
        .id(session)
        .sheet(isPresented: $importingCookies) {
            ChromeCookieImportView(session: session) { perform() }
        }
        .alert(L10n.text("Браузер чата", "Chat browser"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L10n.text("Закрыть", "Dismiss")) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func perform(show: Bool = false, close: Bool = false) {
        guard !operating, !close || !busy else { return }
        operating = true
        let nativeID = session
        let language = L10n.language.rawValue
        let resources = Bundle.main.resourceURL
        Task {
            defer { operating = false }
            do {
                guard let root = try BrowserEnvironmentStore.existingEnvironment(session: nativeID),
                      let resources else {
                    running = false
                    if show { error = L10n.text("Браузер откроется при первом обращении агента.", "The browser opens on the agent’s first browser request.") }
                    return
                }
                let output = try await Task.detached {
                    let process = Process(), pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = ["-B", resources.appendingPathComponent("BrowserRuntime/chrome_host.py").path,
                                         "--root", root.path, "--language", language] + (close ? ["--close"] : [])
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return try JSONDecoder().decode(BrowserControlResult.self, from: data)
                }.value
                if let message = output.error { error = message; running = nil; return }
                running = output.running
                if show {
                    guard output.running == true, let pid = output.pid,
                          let app = NSRunningApplication(processIdentifier: pid),
                          app.bundleIdentifier == "com.google.chrome.for.testing" else {
                        error = L10n.text("Браузер этого чата сейчас закрыт.", "This chat’s browser is currently closed.")
                        return
                    }
                    app.activate(options: [])
                }
            } catch {
                self.error = L10n.text("Не удалось проверить браузер: ", "Could not check the browser: ") + error.localizedDescription
                running = nil
            }
        }
    }
}

private struct BrowserControlResult: Decodable, Sendable {
    let running: Bool?
    let pid: Int32?
    let error: String?
}
