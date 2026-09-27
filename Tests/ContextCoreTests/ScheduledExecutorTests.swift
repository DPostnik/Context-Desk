import Foundation
import Testing
import ClaudeAdapter
@_spi(NativeProtocol) import CodexAdapter
@testable import ContextCore
@testable import ContextDesk

private func claudeFixture(_ root: URL, body: String) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("claude.py")
    try Data(("""
    #!/usr/bin/python3
    import sys,json,pathlib,time
    if '--version' in sys.argv:
        print('2.1.260 (Claude Code)'); sys.exit(0)
    pathlib.Path('sent').write_text(sys.stdin.read())

    """ + body).utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
}
private func makeRequest(_ runner: any AgentScheduledExecutor, root: URL) async throws -> AgentExecutionRequest {
    let descriptor = try await runner.descriptor().value()
    return AgentExecutionRequest(conversation: ConversationID(), kind: .scheduled, prompt: "test", projectPath: root.path,
        permissions: .externalPolicyDenyPrompts, model: .init(context: descriptor.context, model: ""), route: .externalConfiguration)
}

@Test func claudeScheduledContractRejectsReplayAndPersistsBeforeDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "assert pathlib.Path('claimed').exists()\nprint(json.dumps({'type':'result','is_error':False,'result':'done'}))")
    let runner = ClaudeJobRunner(executable: executable)
    let request = try await makeRequest(runner, root: root)
    let result = try await runner.execute(request) { try Data().write(to: root.appendingPathComponent("claimed")) }.value()
    guard case .finished(.completed, let output) = result else { Issue.record("Expected completion"); return }
    #expect(output == "done")
    guard case .rejected(.unknownRequest) = await runner.execute(request, willStart: {}) else { Issue.record("Replay accepted"); return }
}

@Test func claudeScheduledContractDistinguishesPreflightAndUncertainDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "print('malformed result')")
    let runner = ClaudeJobRunner(executable: executable)
    let request = try await makeRequest(runner, root: root)
    guard case .success(.finished(.cancelled, _)) = await runner.execute(request, willStart: { throw CancellationError() }) else {
        Issue.record("Expected pre-dispatch cancellation"); return
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    let other = ClaudeJobRunner(executable: executable)
    let otherRequest = try await makeRequest(other, root: root)
    guard case .failed(let failure) = await other.execute(otherRequest, willStart: {}) else { Issue.record("Malformed output accepted"); return }
    #expect(failure.delivery == .uncertain)
    let failedWrite = ClaudeJobRunner(executable: executable)
    let failedWriteRequest = try await makeRequest(failedWrite, root: root)
    guard case .failed(let persistence) = await failedWrite.execute(failedWriteRequest, willStart: { throw CocoaError(.fileWriteNoPermission) }) else {
        Issue.record("Expected persistence failure"); return
    }
    #expect(persistence.delivery == .notSent)
}

@Test func claudeScheduledRestrictionsRequireExplicitConsentAndFullAccess() async throws {
    let runner = ClaudeJobRunner()
    let descriptor = try await runner.descriptor().value()
    var project = Project(path: "/fixture")
    var job = ManagedJob(); job.engine = .claude
    for full in [false, true] {
        project.accessMode = full ? .fullAccess : .standard
        for consent in [nil, false, true] as [Bool?] {
            job.acceptsExternalPolicy = consent
            let request = job.executionRequest(runID: UUID(), project: project, descriptor: descriptor)
            #expect(descriptor.validate(request) == (full && consent == true ? nil : .unsupportedPermissions))
        }
    }
    job.route = RequestRoute(rawValue: "unavailable-plugin")
    #expect(descriptor.validate(job.executionRequest(runID: UUID(), project: project, descriptor: descriptor)) == .routeUnavailable)
    let legacy = try JSONDecoder().decode(ManagedJob.self, from: JSONEncoder().encode(ManagedJob()))
    #expect(legacy.acceptsExternalPolicy == nil)
}

@Test func claudeScheduledCancellationAfterSendIsUncertain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "time.sleep(20)")
    let runner = ClaudeJobRunner(executable: executable)
    let request = try await makeRequest(runner, root: root)
    let task = Task { await runner.execute(request, willStart: {}) }
    for _ in 0..<1500 {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    await runner.stop()
    guard case .success(.finished(.uncertain, _)) = await task.value else { Issue.record("Dispatched cancellation must remain uncertain"); return }
}

@Test @MainActor func scheduledClaudeUnsupportedProjectIsBlockedWithoutDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try claudeFixture(root, body: "raise Exception('must not dispatch')")
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    model.jobExecutorFactories[.claude] = { _, _, _, _ in ClaudeJobRunner(executable: executable) }
    let project = Project(path: root.path); model.state.projects = [project]; model.schedulerReady = true
    var job = ManagedJob(); job.name = "test"; job.prompt = "test"; job.engine = .claude; job.projectID = project.id; job.enabled = true
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.jobLedger.runs.first?.status == .blocked)
    #expect(model.jobLedger.jobs.first?.enabled == false)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    await model.stopScheduler()
}

@Test(arguments: [JobEngine.codex, .claude])
@MainActor func scheduledExecutorsShareCompletionAndUncertainRecovery(engine: JobEngine) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let native = root.appendingPathComponent("codex.py")
    try Data(#"""
    #!/usr/bin/python3
    import sys,json,pathlib
    for line in sys.stdin:
        m=json.loads(line)
        if 'id' not in m: continue
        method=m['method']; result={'userAgent':'codex/0.158.0-alpha.2.1 fixture'}
        if method=='thread/start': result={'thread':{'id':'session-'+str(len(list(pathlib.Path('.').glob('sent-*'))))}}
        if method=='turn/start':
            ledger=json.loads(pathlib.Path('jobs.json').read_text())
            assert ledger['runs'][0]['status']=='running'
            pathlib.Path('sent-'+str(len(list(pathlib.Path('.').glob('sent-*'))))).write_text('sent')
            result={} if pathlib.Path('malformed').exists() else {'turn':{'id':'turn'}}
        print(json.dumps({'id':m['id'],'result':result}),flush=True)
    """#.utf8).write(to: native)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: native.path)
    // Codex fixture runs in app home; the protocol process uses that directory explicitly below.
    let claude = try claudeFixture(root, body: """
    assert json.loads(pathlib.Path('jobs.json').read_text())['runs'][0]['status']=='running'
    if pathlib.Path('wait').exists(): time.sleep(20)
    print('malformed' if pathlib.Path('malformed').exists() else json.dumps({'type':'result','is_error':False,'result':'saved output'}))
    """)
    // The native fixture must use the temporary root regardless of transport cwd.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    var script = try String(contentsOf: native, encoding: .utf8)
    script = script.replacingOccurrences(of: "import sys,json,pathlib", with: "import sys,json,pathlib,os\nos.chdir(" + String(decoding: try encoder.encode(root.path), as: UTF8.self) + ")")
    try Data(script.utf8).write(to: native)
    let transport = CodexConnection(); try await transport.start(executable: native, home: root)
    let store = JobStore(file: root.appendingPathComponent("jobs.json"))
    let model = DeskModel(connection: CodexIntegration(client: CodexClient(transport: transport)), store: AppStore(file: root.appendingPathComponent("state.sqlite")), jobStore: store)
    model.jobExecutorFactories[.claude] = { _, _, _, _ in ClaudeJobRunner(executable: claude) }
    var project = Project(path: root.path); project.accessMode = .fullAccess
    model.state.projects = [project]; model.schedulerReady = true; model.connected = true; model.authenticated = true
    model.chatID = "visible"; model.draft = "keep draft"
    var job = ManagedJob(); job.name = "test"; job.prompt = "test"; job.engine = engine; job.projectID = project.id
    job.acceptsExternalPolicy = true; job.enabled = true
    #expect(await model.saveJob(job))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    if engine == .codex {
        let run = try #require(model.jobLedger.runs.first)
        #expect(run.status == .running)
        #expect(model.jobExecutors[run.id] != nil)
        model.finishActiveTurn(threadID: run.threadID, turnID: "turn", status: .completed, hasError: false)
        for _ in 0..<100 {
            if model.jobLedger.runs.first?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    } else {
        #expect(model.jobLedger.runs.first?.output == "saved output")
        #expect(model.state.chats.isEmpty)
    }
    #expect(model.jobLedger.runs.first?.status == .completed)
    #expect(model.chatID == "visible" && model.draft == "keep draft")
    try Data().write(to: root.appendingPathComponent("malformed"))
    await model.launchJob(job.id)
    for task in Array(model.jobTasks.values) { await task.value }
    #expect(model.jobLedger.runs.first?.status == .uncertain)
    #expect(model.jobLedger.jobs.first?.enabled == false)
    await model.tickJobs(now: Date().addingTimeInterval(864000))
    #expect(model.jobLedger.runs.count == 2)
    try FileManager.default.removeItem(at: root.appendingPathComponent("malformed"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("sent"))
    try Data().write(to: root.appendingPathComponent("wait"))
    await model.launchJob(job.id)
    if engine == .codex {
        for task in Array(model.jobTasks.values) { await task.value }
    } else {
        for _ in 0..<1500 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sent").path))
    }
    let active = try #require(model.jobLedger.runs.first)
    #expect(active.status == .running)
    await model.stopJob(active)
    if engine == .codex {
        model.finishActiveTurn(threadID: active.threadID, turnID: "turn", status: .cancelled, hasError: false)
        for _ in 0..<100 {
            if model.jobLedger.runs.first?.status == .interrupted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    } else {
        for task in Array(model.jobTasks.values) { await task.value }
    }
    #expect(model.jobLedger.runs.first?.status == (engine == .codex ? .interrupted : .uncertain))
    #expect(model.jobExecutors.isEmpty)
    await model.stopScheduler(); await transport.stop()
}
