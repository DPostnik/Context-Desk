@_spi(NativeProtocol) import CodexAdapter
import Foundation
import Darwin
import AppKit
import SwiftUI
import Testing
@testable import ContextCore
@testable import ContextDesk

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func jobFixture() -> ManagedJob {
    var job = ManagedJob(); job.name = "Morning · Утро"; job.prompt = "Review today's work"; job.projectID = UUID()
    job.schedule = JobSchedule(rule: "FREQ=HOURLY;INTERVAL=1", timeZone: "Europe/Warsaw"); job.enabled = true
    return job
}
@Test func schedulerCalendarZonesDSTAndUnsupportedRules() throws {
    let daily = JobSchedule(rule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=30;BYSECOND=0", timeZone: "Europe/Warsaw")
    #expect(try daily.next(after: instant("2026-03-28T10:00:00Z")) == instant("2026-03-29T07:30:00Z"))
    #expect(try daily.next(after: instant("2026-10-24T10:00:00Z")) == instant("2026-10-25T08:30:00Z"))
    let weekday = JobSchedule(rule: "FREQ=WEEKLY;BYHOUR=9;BYMINUTE=0;BYDAY=MO,TU,WE,TH,FR", timeZone: "Europe/Warsaw")
    #expect(try weekday.next(after: instant("2026-09-25T08:00:00Z")) == instant("2026-09-28T07:00:00Z"))
    let many = JobSchedule(rule: "RRULE:FREQ=DAILY;BYHOUR=8,9,10;BYMINUTE=0,30", timeZone: "UTC")
    #expect(try many.next(after: instant("2026-09-27T08:30:00Z")) == instant("2026-09-27T09:00:00Z"))
    for rule in ["FREQ=MONTHLY", "FREQ=HOURLY;BYMINUTE=30", "FREQ=MINUTELY;INTERVAL=0", "FREQ=HOURLY;COUNT=2", "FREQ=DAILY;BYHOUR=24;BYMINUTE=0", "FREQ=WEEKLY;BYHOUR=9;BYMINUTE=0", "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;FREQ=DAILY"] {
        #expect(throws: (any Error).self) { try JobSchedule(rule: rule).next(after: Date()) }
    }
    #expect(throws: (any Error).self) { try JobSchedule(timeZone: "invalid").next(after: Date()) }
}
@Test func schedulerClaimsPersistBeforeDispatchAndCollapseMissedRuns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let now = instant("2026-09-27T08:00:00Z"), job = jobFixture()
    _ = try await store.save(job, now: now)
    #expect(try await store.claim(job.id, manual: false, now: now) == nil)
    let (_, run) = try #require(await store.claim(job.id, manual: false, now: now.addingTimeInterval(86400)))
    let disk = try JSONDecoder().decode(JobLedger.self, from: Data(contentsOf: file))
    #expect(disk.runs.first?.id == run.id)
    #expect(disk.jobs.first?.nextRun == now.addingTimeInterval(90000))
    #expect(try await store.claim(job.id, manual: true) == nil)
    _ = try await store.finish(run.id, status: .completed)
    #expect(try await store.claim(job.id, manual: false, now: now.addingTimeInterval(86401)) == nil)
    let second = try #require(await store.claim(job.id, manual: true))
    _ = try await store.attach(second.1.id, thread: "test-thread", turn: "turn")
    await store.release()
    let restored = try await JobStore(file: file).load()
    #expect(restored.runs.first?.status == .uncertain)
    #expect(restored.runs.first?.threadID == "test-thread")
    #expect(restored.jobs.first?.enabled == false)
}
@Test func schedulerOwnershipOneShotManualAndFailurePause() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: root.appendingPathComponent("jobs.json"))
    _ = try await store.load()
    let other = JobStore(file: file)
    await #expect(throws: (any Error).self) { try await other.load() }
    var job = jobFixture(); let now = Date()
    job.schedule.once = now.addingTimeInterval(60)
    _ = try await store.save(job, now: now)
    let claimed = try #require(await store.claim(job.id, manual: false, now: now.addingTimeInterval(70)))
    #expect(try await store.load().jobs.first?.enabled == false)
    _ = try await store.finish(claimed.1.id, status: .blocked, output: "denied")
    #expect(try await store.load().runs.first?.status == .blocked)
    var imported = jobFixture(); imported.source = "codex:external"
    await #expect(throws: (any Error).self) { try await store.save(imported) }
    imported.sourceDisabled = true
    _ = try await store.save(imported)
    let manual = try #require(await store.claim(imported.id, manual: true, now: now))
    #expect(try await store.load().jobs.first { $0.id == imported.id }?.nextRun != nil)
    _ = try await store.finish(manual.1.id, status: .failed)
    #expect(try await store.load().jobs.first { $0.id == imported.id }?.enabled == false)
    await store.release()
}
@Test func schedulerPersistenceFailureCannotClaim() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json"), store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let job = jobFixture(); _ = try await store.save(job)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await store.claim(job.id, manual: true) }
    #expect(try await store.load().runs.isEmpty)
    await store.release()
}
@Test func schedulerClaudeImportPreservesPromptWithoutInventingSchedule() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("sample")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = folder.appendingPathComponent("SKILL.md")
    let data = Data("---\nname: sample\ndescription: Example\n---\nHello $HOME `date`\nПривет\n".utf8)
    try data.write(to: file)
    let job = try #require(ScheduledJobs.readClaude(directory: root).first)
    #expect(job.prompt == "Hello $HOME `date`\nПривет\n")
    #expect(job.rawRule.isEmpty && job.model.isEmpty && job.paths.isEmpty)
    #expect(job.engine == .claude)
    #expect(try Data(contentsOf: file) == data)
}

@Test @MainActor func scheduledCodexRoutesRespectPermissionsAndPreserveSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!/usr/bin/python3
    import sys, json
    requests = []
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']
        result={}
        if method=='thread/start': result={'thread':{'id':'scheduled-thread'}}
        if method=='turn/start': result={'turn':{'id':'scheduled-turn'}}
        if method=='test/requests': result=requests
        else: requests.append(m)
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let connection = CodexConnection(); try await connection.start(executable: executable, home: root)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(connection: CodexClient(transport: connection), store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    let project = Project(path: root.path); model.state.projects = [project]; model.projectID = project.id
    model.chatID = "visible-chat"; model.draft = "Keep my draft"; model.connected = true; model.authenticated = true
    model.schedulerReady = true
    var job = jobFixture(); job.projectID = project.id; job.model = "selected-model"; job.effort = "low"
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.chatID == "visible-chat" && model.draft == "Keep my draft")
    let requests = try await connection.request("test/requests").array
    let start = try #require(requests.first { $0["method"].string == "thread/start" })
    let turn = try #require(requests.first { $0["method"].string == "turn/start" })
    #expect(start["params"]["modelProvider"].string == "openai")
    #expect(start["params"]["approvalPolicy"].string == "on-request")
    #expect(turn["params"]["sandboxPolicy"]["type"].string == "workspaceWrite")
    #expect(turn["params"]["model"].string == "selected-model")
    let conversation = try #require(model.state.chats.first { $0.nativeSession?.nativeID == "scheduled-thread" })
    #expect(model.jobLedger.runs.first?.threadID == conversation.id)
    #expect(conversation.id != "scheduled-thread")
    await model.launchJob(job.id)
    #expect(model.jobLedger.runs.count == 1)
    model.finishActiveTurn(threadID: conversation.id, turnID: "scheduled-turn", status: "completed", hasError: false)
    for _ in 0..<100 { if model.jobLedger.runs.first?.status == .completed { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.jobLedger.runs.first?.status == .completed)
    await model.stopScheduler(); await connection.stop()
}

@Test func claudeAdapterUsesPinnedProtocolAndDeniesNewPermissions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude.py")
    try Data(#"""
    #!/usr/bin/python3
    import sys,json
    if '--version' in sys.argv:
        print('2.1.260 (Claude Code)'); sys.exit(0)
    assert '--permission-mode' in sys.argv and sys.argv[sys.argv.index('--permission-mode')+1]=='dontAsk'
    assert '--dangerously-skip-permissions' not in sys.argv
    assert '--no-session-persistence' in sys.argv
    text=sys.stdin.read()
    print(json.dumps({'type':'result','is_error':False,'result':text,'permission_denials':[{'tool_name':'Bash'}]}))
    """#.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let (status, text) = try await ClaudeJobRunner().run(prompt: "Привет `date` $HOME", model: "test-model", cwd: root, executable: executable)
    #expect(status == .blocked)
    #expect(text == "Привет `date` $HOME")
}

@Test func schedulerSerializesConcurrentClaimsAndCapsRunningWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let job = jobFixture(); _ = try await store.save(job)
    let count = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<10 { group.addTask { try await store.claim(job.id, manual: true) == nil ? 0 : 1 } }
        var count = 0; for try await n in group { count += n }; return count
    }
    #expect(count == 1)
    for _ in 0..<2 { let other = jobFixture(); _ = try await store.save(other); #expect(try await store.claim(other.id, manual: true) != nil) }
    let fourth = jobFixture(); _ = try await store.save(fourth)
    #expect(try await store.claim(fourth.id, manual: true) == nil)
    await store.release()
}

@Test @MainActor func scheduledCodexUnconfirmedSendPausesWithoutRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("engine.py")
    try Data(#"""
    #!/usr/bin/python3
    import sys,json
    starts=0
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; result={}
        if method=='thread/start': result={'thread':{'id':'uncertain-thread'}}
        if method=='turn/start':
            starts+=1
            # A malformed acknowledgement leaves delivery unconfirmed.
            result={}
        if method=='test/count': result={'starts':starts}
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let connection = CodexConnection(); try await connection.start(executable: executable, home: root)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(connection: CodexClient(transport: connection), store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    let project = Project(path: root.path); model.state.projects = [project]; model.connected = true; model.authenticated = true; model.schedulerReady = true
    var job = jobFixture(); job.projectID = project.id
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.jobLedger.runs.first?.status == .uncertain)
    #expect(model.jobLedger.jobs.first?.enabled == false)
    await model.tickJobs(now: Date().addingTimeInterval(86400))
    #expect(try await connection.request("test/count")["starts"].int == 1)
    await model.stopScheduler(); await connection.stop()
}

// Opt-in rendering uses synthetic data and process-local language defaults, never the running app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CONTEXTDESK_SCHEDULE_RENDER_DIR"] != nil))
@MainActor func schedulerEditorRenderProbe() throws {
    let language = ProcessInfo.processInfo.environment["CONTEXTDESK_SCHEDULE_RENDER_LANGUAGE"] ?? "ru"
    UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: language], forName: UserDefaults.argumentDomain)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: JobStore(file: root.appendingPathComponent("jobs.json")))
    let project = Project(path: "/tmp/example-project"); model.state.projects = [project]
    var job = jobFixture(); job.projectID = project.id; job.schedule = JobSchedule(); job.source = "codex:example"; job.enabled = false
    let host = NSHostingView(rootView: JobEditor(model: model, job: job).environment(\.locale, L10n.locale).preferredColorScheme(.light).background(Color.white))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 640, height: 700)
    window.backgroundColor = .white
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTEXTDESK_SCHEDULE_RENDER_DIR"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent("schedule-editor-" + language + ".png"))
    #expect(L10n.language.rawValue == language)
    window.orderOut(nil)
}

@Test func claudeAdapterRejectsUnverifiedVersionBeforeSendingPrompt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude.py")
    try Data(#"""
    #!/usr/bin/python3
    import sys,pathlib
    if '--version' in sys.argv:
        print('0.0.0 (Claude Code)'); sys.exit(0)
    pathlib.Path('unexpected-send').write_text('sent')
    """#.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    await #expect(throws: (any Error).self) {
        try await ClaudeJobRunner().run(prompt: "Do not send", model: "", cwd: root, executable: executable)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-send").path))
}

@Test func schedulerReleaseUnlocksEvenWithDuplicatedDescriptor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("jobs.json")
    let store = JobStore(file: file)
    _ = try await store.load()
    // dup models the shared open file description retained briefly by a forked child.
    let suffix = "/" + root.lastPathComponent + "/jobs.json.lock"
    var duplicate: Int32 = -1
    for fd: Int32 in 0..<1024 {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBytes { fcntl(fd, F_GETPATH, $0.baseAddress!) }
        if result == 0 && String(cString: path).hasSuffix(suffix) {
            duplicate = dup(fd); break
        }
    }
    defer { if duplicate >= 0 { close(duplicate) } }
    #expect(duplicate >= 0)
    await store.release()
    let replacement = JobStore(file: file)
    _ = try await replacement.load()
    await replacement.release()
}
