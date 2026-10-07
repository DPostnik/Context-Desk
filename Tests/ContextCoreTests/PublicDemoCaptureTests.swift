import AppKit
import ContextCore
import AgentContract
import SwiftUI
import Testing
@testable import ContextDesk

// Media capture, not a live-agent acceptance test. Run alone via scripts/capture-demo.sh.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CONTEXTDESK_PUBLIC_CAPTURE"] != nil))
@MainActor func publicDemoRenderProbe() throws {
    UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: "en"], forName: UserDefaults.argumentDomain)
    _ = NSApplication.shared
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")),
                          pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil,
                          summaryHome: root.appendingPathComponent("codex"),
                          jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    // Do not call boot/connect: no credentials, personal history or scheduler are read.
    var project = Project(path: "/tmp/context-desk-demo/code-fix")
    project.name = "Code exercise"
    var browserProject = Project(path: "/tmp/context-desk-demo/workshop-watch")
    browserProject.name = "Workshop Watch"
    model.state.projects = [project, browserProject]
    model.projectID = project.id
    let chat = Chat(id: "demo-code", projectID: project.id, title: "Fix whitespace in slugify", model: "Demo fixture")
    model.state.chats = [chat]
    model.chatID = chat.id
    model.connected = true; model.authenticated = true
    model.accountLabel = "Synthetic demo · no account"
    model.items = [
        TranscriptItem(id: "prompt", kind: "user", text: "Fix slugify: trim and lowercase the title, collapse whitespace to one hyphen, and run the five acceptance tests. Use only this folder."),
        TranscriptItem(id: "tools", kind: "activity", text: "python3 -m unittest -v\nBaseline: 5 tests, 2 failures.\nAfter the reference fix: 5 tests, OK."),
        TranscriptItem(id: "result", kind: "assistant", text: "The reference fix splits on any whitespace and rejoins words with a single hyphen.\n\n```python\ndef slugify(title: str) -> str:\n    return \"-\".join(title.lower().split())\n```\n\nFive tests pass. Tests are unchanged.\n\n**Synthetic UI fixture — not a live agent response.**")
    ]
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTEXTDESK_PUBLIC_CAPTURE"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func capture(_ filename: String) throws {
        // Render the production content panels directly. NavigationSplitView's
        // composited sidebar is not captured reliably by AppKit cacheDisplay.
        let panel = model.showingJobs ? AnyView(JobsView(model: model)) : AnyView(ChatView(model: model))
        let host = NSHostingView(rootView: panel.environment(\.locale, L10n.locale).preferredColorScheme(.light).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Context Desk · Synthetic demo"
        window.contentView = host; window.backgroundColor = .white
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent(filename))
    }
    try capture("code-workspace.png")
    var job = ManagedJob()
    job.name = "Workshop Watch (demo)"; job.projectID = browserProject.id
    job.model = "Demo fixture"; job.effort = "medium"
    job.prompt = "Read both pages of the local Workshop Watch catalog. Report new open Frontend workshops, preserve seen IDs, and stop on incomplete coverage. Synthetic fixture only; no submissions."
    job.schedule = JobSchedule(rule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", timeZone: "Europe/Warsaw")
    model.jobLedger.jobs = [job]
    model.showingJobs = true
    // Display the available controls, but never start or persist a scheduler.
    model.schedulerReady = true
    try capture("scheduled-task.png")
    #expect(L10n.language == .english)
}
