import Foundation
import Testing
@testable import ClaudeAdapter
@testable import ContextCore
@testable import ContextDesk

private actor ClaudeEvents {
    var values: [AgentEvent] = []
    func append(_ event: AgentEvent) { values.append(event) }
    func completion() -> AgentExecutionOutcome? {
        for event in values { if case .completed(let result) = event.payload { return result.status } }
        return nil
    }
    func completionCount() -> Int {
        values.filter { if case .completed = $0.payload { return true }; return false }.count
    }
    func usage() -> [(turn: String?, total: TokenCounters?, snapshot: UsageSnapshot)] {
        values.compactMap { if case .usage(let turn, let total, let snapshot) = $0.payload { return (turn, total, snapshot) }; return nil }
    }
    func statuses() -> [String?] {
        values.compactMap { if case .status(_, let text) = $0.payload { return .some(text) }; return nil }
    }
    func interaction() -> AgentInteraction? {
        for event in values { if case .interaction(let request) = event.payload { return request } }
        return nil
    }
}
private func interactiveFixture(_ root: URL) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("claude.py")
    let script = #"""
    #!\#(fixturePython)
    import sys,os,json,pathlib,time
    home=pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])
    if '--version' in sys.argv:
        print('2.1.292 (Claude Code)'); sys.exit(0)
    if sys.argv[1:3] == ['auth','status']:
        if (home/'auth-delay').exists(): time.sleep(float((home/'auth-delay').read_text()))
        if (home/'invalid-auth').exists(): print('{}'); sys.exit(1)
        print(json.dumps({'loggedIn':True,'apiProvider':'firstParty','authMethod':'oauth','email':(home/'account').read_text() if (home/'account').exists() else 'fixture'})); sys.exit(0)
    if sys.argv[1:3] == ['auth','logout']: sys.exit(0)
    if '--json-schema' in sys.argv:
        a=sys.argv
        assert a[a.index('--tools')+1]=='' and '--no-session-persistence' in a and '--safe-mode' in a and '--disable-slash-commands' in a
        assert a[a.index('--setting-sources')+1]=='' and '--strict-mcp-config' in a and a[a.index('--mcp-config')+1]=='{"mcpServers":{}}'
        assert not any(k in a for k in ['--resume','--session-id','--append-system-prompt','--input-format'])
        assert not any(k in os.environ for k in ['ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_BASE_URL','BASH_ENV','NODE_OPTIONS'])
        text=sys.stdin.read()
        with (home/'generated').open('a') as f: f.write(json.dumps({'args':a,'cwd':os.getcwd(),'input':text})+'\n')
        mode=(home/'generation-mode').read_text() if (home/'generation-mode').exists() else 'success'
        if mode=='hang': time.sleep(30); sys.exit(1)
        props=json.loads(a[a.index('--json-schema')+1])['properties']
        if 'title' in props: value={'title':'Fixture title'}
        elif 'overview' in props:
            refs=[f['reference'] for f in json.loads(text.split('\n',1)[1])]
            value={'overview':'Fixture overview','activities':[{'goal':'Say hello','actions':['Greeted'],'outcome':'Done','unfinished':[],
                'reusableSteps':[],'variableInputs':[],'evidence':['missing/ref' if mode=='invalid' else refs[0]]}]}
        else: value={k:'Fixture '+k for k in props}
        usage={'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':70,'output_tokens':5}
        if mode=='error':
            print(json.dumps({'type':'result','subtype':'error_during_execution','is_error':True,'result':'boom','usage':usage,'permission_denials':[]})); sys.exit(1)
        print(json.dumps({'type':'result','subtype':'success','is_error':False,'result':json.dumps(value),'structured_output':value,'usage':usage,'permission_denials':[]})); sys.exit(0)
    browser='--mcp-config' in sys.argv and 'context_desk_browser' in sys.argv[sys.argv.index('--mcp-config')+1]
    assert ('--safe-mode' in sys.argv) != browser and '--setting-sources' in sys.argv and '--strict-mcp-config' in sys.argv
    assert '--append-system-prompt' in sys.argv
    assert len(sys.argv[sys.argv.index('--append-system-prompt')+1]) > 100
    assert sys.argv[sys.argv.index('--setting-sources')+1] == ''
    assert not any(k in os.environ for k in ['ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_BASE_URL','BASH_ENV','NODE_OPTIONS'])
    sid=sys.argv[sys.argv.index('--resume' if '--resume' in sys.argv else '--session-id')+1]
    def out(value): print(json.dumps(value),flush=True)
    def result(): out({'type':'result','session_id':sid,'is_error':False,
        'usage':{'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':70,'output_tokens':5},
        'modelUsage':{'claude-helper':{'contextWindow':5000,'inputTokens':1},'claude-test':{'contextWindow':1000,'inputTokens':10}}})
    out({'type':'system','subtype':'init','session_id':sid,'model':'claude-test'})
    for line in sys.stdin:
        value=json.loads(line)
        if value['type']=='control_request':
            out({'type':'control_response','response':{'subtype':'success','request_id':value['request_id'],'response':{}}})
            if value['request']['subtype']=='interrupt': result()
        elif value['type']=='user':
            record=json.loads((home/'contextdesk-sessions'/(sid+'.json')).read_text())
            assert record['active'] and record['sent']
            with (home/'submitted').open('a') as f: f.write(json.dumps({'prompt':value['message']['content'],'args':sys.argv,'env':{k:os.environ.get(k) for k in ['MCP_TIMEOUT','MCP_TOOL_TIMEOUT','CLAUDE_CODE_DISABLE_CLAUDE_MDS']}})+'\n')
            prompt=value['message']['content']
            if prompt=='broken': print('invalid-json',flush=True); continue
            if prompt=='unknown': out({'type':'control_request','request_id':'unknown','request':{'subtype':'unexpected_action'}}); continue
            if prompt=='wait': continue
            if prompt in ['approval','question','outside']:
                name='AskUserQuestion' if prompt=='question' else 'Write'
                args={'questions':[{'question':'Choose','options':[{'label':'Yes'},{'label':'No'}]}]} if prompt=='question' else {'file_path':'/outside-project/file' if prompt=='outside' else str(pathlib.Path.cwd()/'fixture.txt'),'content':'content'}
                out({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool','tool_name':name,'input':args}})
                continue
            usage={'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':70,'output_tokens':1}
            out({'type':'stream_event','session_id':sid,'event':{'type':'message_start','message':{'id':'answer-'+sid,'usage':usage}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_start','index':0,'content_block':{'type':'thinking','thinking':''}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_start','index':1,'content_block':{'type':'tool_use','id':'t1','name':'Grep','input':{}}}})
            out({'type':'stream_event','session_id':sid,'parent_tool_use_id':'task','event':{'type':'message_start','message':{'id':'sub-'+sid,'usage':{'input_tokens':9000,'output_tokens':1}}}})
            out({'type':'stream_event','session_id':sid,'parent_tool_use_id':'task','event':{'type':'content_block_start','index':0,'content_block':{'type':'tool_use','id':'t2','name':'Read','input':{}}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_start','index':2,'content_block':{'type':'text','text':''}}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'content_block_delta','delta':{'type':'text_delta','text':'hello'}}})
            out({'type':'assistant','session_id':sid,'message':{'id':'answer-'+sid,'usage':usage,'content':[{'type':'text','text':'hello'}]}})
            out({'type':'stream_event','session_id':sid,'event':{'type':'message_delta','usage':{'output_tokens':5}}})
            result()
        elif value['type']=='control_response':
            (home/'answer').write_text(json.dumps(value))
            result()
    """#
    try Data(script.utf8).write(to: executable)
    try installFixtureExecutable(at: executable)
    return executable
}
private func waitFor(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<1500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ClientFailure("Fixture timed out")
}
private func interactiveRequest(context: AgentContext, root: URL, session: AgentSessionReference? = nil, prompt: String = "hello", id: UUID = UUID()) -> AgentExecutionRequest {
    .init(id: id, conversation: ConversationID(), session: session, kind: .interactive, prompt: prompt,
          projectPath: root.path, permissions: .workspaceWrite(root: root.path, network: false, approval: .ask),
          model: .init(context: context, model: ""), route: .direct)
}

@Test func claudeChatsLaunchTheirOwnBrowserProfileAndRestartAfterReassignment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let resources = root.appendingPathComponent("Resources"), browserRoot = root.appendingPathComponent("browser")
    try FileManager.default.createDirectory(at: resources.appendingPathComponent("BrowserRuntime"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
    try Data("# fixture".utf8).write(to: resources.appendingPathComponent("BrowserRuntime/server.py"))
    let adapter = ClaudeIntegration(browserRoot: browserRoot), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    // The runtime is not installed yet: fail loudly instead of a silently browser-less chat.
    guard case .failed = await adapter.connect(.init(executable: binary, home: home, resources: resources, browserEnabled: true)) else {
        Issue.record("Missing browser runtime accepted"); return
    }
    try Data("{}".utf8).write(to: browserRoot.appendingPathComponent("runtime.json"))
    let descriptor = try await adapter.connect(.init(executable: binary, home: home, resources: resources, browserEnabled: true)).value()
    #expect(descriptor.capabilities.contains(.browserProfiles))
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    let store = BrowserProfileStore(root: browserRoot)
    let first = try store.ownedGrant(session: session)
    #expect(try store.current(session: session)?.connection == .appClaude)

    func turn(_ index: Int) async throws -> [String: Any] {
        _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
        try await waitFor { await events.completionCount() == index }
        let lines = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
        return try #require(JSONSerialization.jsonObject(with: Data(lines[index - 1].utf8)) as? [String: Any])
    }
    func lease(_ record: [String: Any]) throws -> String {
        let args = try #require(record["args"] as? [String])
        let config = args[try #require(args.firstIndex(of: "--mcp-config")) + 1]
        let server = try #require(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let browser = try #require((server["mcpServers"] as? [String: Any])?["context_desk_browser"] as? [String: Any])
        let argv = try #require(browser["args"] as? [String])
        #expect(argv.first == resources.appendingPathComponent("BrowserRuntime/server.py").path)
        return argv[try #require(argv.firstIndex(of: "--profile-lease")) + 1]
    }
    let one = try await turn(1)
    let args = try #require(one["args"] as? [String])
    #expect(!args.contains("--safe-mode") && args.contains("--disable-slash-commands"))
    #expect(args[args.firstIndex(of: "--allowedTools")! + 1] == "mcp__context_desk_browser")
    #expect(one["env"] as? [String: String] == ["MCP_TIMEOUT": "30000", "MCP_TOOL_TIMEOUT": "90000", "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"])
    #expect(try lease(one) == first.generation.uuidString.lowercased())

    // Reopening keeps the chat's profile.
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    #expect(try store.ownedGrant(session: session) == first)
    #expect(try lease(await turn(2)) == first.generation.uuidString.lowercased())

    // A reassigned profile only reaches the agent through a new launch.
    try store.select(nil, session: session, project: root.path) { _ in }
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    let second = try store.ownedGrant(session: session)
    #expect(second.environment != first.environment)
    #expect(try lease(await turn(3)) == second.generation.uuidString.lowercased())
}

@Test func claudeSendDuringAnotherAccountCheckIsDelivered() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    // A background title/summary re-check is still probing the login when the user sends.
    try Data("1.5".utf8).write(to: home.appendingPathComponent("auth-delay"))
    let check = Task { await adapter.account() }
    try await Task.sleep(for: .milliseconds(300))
    _ = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completion() != nil }
    #expect(await events.completion() == .completed)
    guard case .success(let account) = await check.value else { Issue.record("Account re-check failed"); return }
    #expect(account.authenticated)
}

@Test func claudeInteractivePersistsStreamsResumesAndRejectsReplay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    #expect(descriptor.context.connection == .appClaude)
    #expect(descriptor.capabilities.contains(.usage))
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    let request = interactiveRequest(context: descriptor.context, root: root, session: session)
    _ = try await adapter.submit(request).value()
    try await waitFor { await events.completion() != nil }
    #expect(await events.completion() == .completed)
    let history = try await adapter.history(session, context: descriptor.context).value()
    #expect(history.count == 1)
    #expect(history[0].items.map(\.kind) == ["user", "assistant"])
    #expect(history[0].items.last?.agentName == "Claude")
    #expect(!history[0].isComplete)
    #expect(await events.values.contains { if case .delta(_, _, "hello") = $0.payload { return true }; return false })
    // Thinking and tool starts are announced before any text; streamed text clears the label.
    #expect(await events.statuses() == [ClaudeIntegration.thinkingLabel, ClaudeIntegration.thinkingLabel,
        ClaudeIntegration.toolLabel("Grep", main: true), ClaudeIntegration.thinkingLabel,
        ClaudeIntegration.toolLabel("Read", main: false), nil])
    let first = await events.usage()
    #expect(first.first?.turn == nil && first.first?.total == .zero)
    // Subagent calls stay out of the main context; the window comes from the session model.
    #expect(first.allSatisfy { ($0.snapshot.last ?? 0) < 9000 })
    #expect(first.last?.snapshot == UsageSnapshot(last: 105, window: 1000, input: 100, cached: 70, output: 5, measuredAt: first.last!.snapshot.measuredAt))
    #expect(first.last?.snapshot.contextFraction == 0.105)
    guard case .rejected(.unknownRequest) = await adapter.submit(request) else { Issue.record("Replay accepted"); return }
    await adapter.disconnect()
    let next = try await adapter.connect(.init(executable: binary, home: home)).value()
    #expect(try await adapter.history(session, context: next.context).value().count == 1)
    _ = try await adapter.prepare(interactiveRequest(context: next.context, root: root, session: session)).value()
    _ = try await adapter.submit(interactiveRequest(context: next.context, root: root, session: session)).value()
    try await waitFor { await events.completionCount() == 2 }
    // Totals persist with the adapter session record and stay cumulative after reconnecting.
    let resumed = await events.usage().dropFirst(first.count)
    #expect(resumed.first?.turn == nil && resumed.first?.total == TokenCounters(input: 100, cached: 70, output: 5))
    #expect(resumed.first?.snapshot.window == 1000)
    #expect(resumed.last?.total == TokenCounters(input: 200, cached: 140, output: 10))
    #expect(resumed.last?.snapshot.last == 105)
    let sent = try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n")
    try #require(sent.count == 2)
    #expect(sent[1].contains("--resume"))
    await adapter.disconnect()
}

@Test(arguments: ["approval", "question", "outside"]) func claudeInteractivePermissionRoundTrip(_ prompt: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: prompt)).value()
    if prompt != "outside" {
        try await waitFor {
            let action = await events.interaction(), completion = await events.completion()
            return action != nil || completion != nil
        }
        let interaction = try #require(await events.interaction())
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("answer").path))
        let response: AgentInteractionResponse = prompt == "question" ? .answers(["Choose": "Yes"]) : .allowOnce
        _ = try await adapter.answer(interaction.id, session: session, context: descriptor.context, response: response).value()
        guard case .rejected(.unknownRequest) = await adapter.answer(interaction.id, session: session, context: descriptor.context, response: response) else { Issue.record("Approval reused"); return }
    }
    try await waitFor { await events.completion() != nil }
    let reply = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("answer")))["response"]["response"]
    #expect(reply["behavior"].string == (prompt == "outside" ? "deny" : "allow"))
    if prompt == "question" { #expect(reply["updatedInput"]["answers"]["Choose"].string == "Yes") }
    await adapter.disconnect()
}

@Test(arguments: ["broken", "unknown", "wait"]) func claudeInteractiveUncertainAndInterrupt(_ prompt: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration(), events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    let handle = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session, prompt: prompt)).value()
    if prompt == "wait" { _ = try await adapter.cancel(handle).value() }
    try await waitFor { await events.completion() != nil }
    #expect(await events.completion() == (prompt == "wait" ? .cancelled : .uncertain))
    #expect(try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n").count == 1)
    await adapter.disconnect()
}

@Test func claudeInteractiveAccountChangeInvalidatesPreparedTurnAndLoginIsIsolated() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home with space")
    let adapter = ClaudeIntegration()
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    guard case .openLocalSignIn(let script) = try await adapter.authenticate(.beginSignIn).value() else { Issue.record("No local sign-in"); return }
    let text = try String(contentsOf: script, encoding: .utf8)
    #expect(text.contains("auth login --claudeai"))
    #expect(text.contains("CLAUDE_CONFIG_DIR=" + home.path))
    #expect(text.contains("/usr/bin/env -i"))
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    try Data("other-account".utf8).write(to: home.appendingPathComponent("account"))
    guard case .rejected(.staleContext) = await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)) else { Issue.record("Account change accepted"); return }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("submitted").path))
    await adapter.disconnect()
}

@Test @MainActor func chatSelectionAndDisconnectAreScopedToAgent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DeskModel(store: AppStore(file: root.appendingPathComponent("store.sqlite")), pluginDirectory: root.appendingPathComponent("plugins"), summaryResources: nil)
    let project = Project(path: root.path)
    let codex = Chat(session: .init(connection: .originalCodex, nativeID: "same-native-id"), projectID: project.id, title: "Codex", model: "codex")
    let claude = Chat(session: .init(connection: .appClaude, nativeID: "same-native-id"), projectID: project.id, title: "Claude", model: "claude")
    model.state.projects = [project]; model.state.chats = [codex, claude]; model.projectID = project.id
    model.chatID = claude.id; model.claudeConnected = true; model.claudeAuthenticated = true; model.draft = "hello"
    #expect(model.currentAgent == .appClaude)
    #expect(model.canSend)
    #expect(model.supportsSummaries(claude.id))
    // Summaries run on the chat's own connection; Codex is disconnected here.
    #expect(model.canGenerateSummary(claude.id) && !model.canGenerateSummary(codex.id))
    #expect(model.generationRunner(for: claude.id) === model.claudeSummaryRunner)
    #expect(model.generationEnvironment(for: claude.id, workspace: "w").home == model.claudeHome)
    await model.receive(.init(session: claude.nativeSession, payload: .started(turn: "claude-turn")))
    await model.receive(.init(session: codex.nativeSession, payload: .started(turn: "codex-turn")))
    await model.receive(.init(session: nil, payload: .disconnected))
    #expect(model.isBusy(threadID: claude.id))
    #expect(!model.isBusy(threadID: codex.id))
    #expect(try model.clientForChat(claude.id) === model.claudeConnection)
    #expect(try model.clientForChat(codex.id) === model.connection)
}

@Test @MainActor func claudeHandoffAndArchiveUseAppMetadataWithoutDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    _ = try await adapter.connect(.init(executable: binary, home: home)).value()
    let store = AppStore(file: root.appendingPathComponent("store.sqlite"))
    let model = DeskModel(claudeIntegration: adapter, store: store, pluginDirectory: root.appendingPathComponent("plugins"),
                          summaryResources: claudeSkills, summaryHome: root.appendingPathComponent("codex"), claudeHome: home)
    let project = Project(path: root.path)
    model.state.projects = [project]; model.projectID = project.id
    model.claudeConnected = true; model.claudeAuthenticated = true
    var handoff = ContextHandoff(snapshot: .init(conversation: ConversationID("source"), source: .init(connection: .originalCodex, nativeID: "source-native"), revision: "revision", capturedAt: Date(), completeness: .partial, items: []))
    handoff.goal = "Continue review"
    #expect(await model.createHandoffChat(handoff, project: project, route: .direct, agent: .appClaude))
    let chat = try #require(model.selectedChat)
    #expect(chat.nativeSession?.connection == .appClaude)
    #expect(chat.handoffOrigin == handoff.origin)
    #expect(!model.draft.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("submitted").path))
    await model.renameChat(chat.id, title: "Claude review")
    await model.setChatArchived(chat.id, archived: true)
    #expect(model.isArchived(chat.id))
    #expect(model.archiveSummaries[chat.id] == nil)
    await model.queueMissingArchiveSummaries()
    await model.summaryTask?.value
    // A chat without turns has nothing to summarize: the record completes without a model call.
    #expect(model.archiveSummaries[chat.id]?.status == .ready)
    #expect(model.archiveSummaries[chat.id]?.partCount == 0)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("generated").path))
    await model.setChatArchived(chat.id, archived: false)
    #expect(!model.isArchived(chat.id))
    await adapter.disconnect()
}

@Test func claudeInvalidAuthStatusCannotReuseEarlierAuthentication() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    try Data().write(to: home.appendingPathComponent("invalid-auth"))
    guard case .failed = await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)) else { Issue.record("Malformed account status allowed dispatch"); return }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("submitted").path))
    await adapter.disconnect()
}

@Test func claudeProjectPathsResolveAliasesNewFilesAndDenyEscapingSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
    #expect(ClaudeIntegration.isWithinProject(alias.appendingPathComponent("new/f.txt").path, cwd: workspace.path))
    #expect(ClaudeIntegration.isWithinProject("nested/new.txt", cwd: workspace.path))
    let escape = workspace.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: root)
    #expect(!ClaudeIntegration.isWithinProject("escape/new.txt", cwd: workspace.path))
    #expect(!ClaudeIntegration.isWithinProject("../new.txt", cwd: workspace.path))
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
    #expect(!ClaudeIntegration.isWithinProject("dangling/new.txt", cwd: workspace.path))
}

@Test func claudeUsageMeterMergesRepeatedBlocksAndAbandonedTurns() {
    var meter = ClaudeUsageMeter(base: .init(input: 50, cached: 10, output: 3), window: 200_000, last: 53)
    let start: JSONValue = .object(["input_tokens": .number(4), "cache_creation_input_tokens": .number(6), "cache_read_input_tokens": .number(90), "output_tokens": .number(1)])
    var changed = meter.observe(message: "a", usage: start); #expect(changed)
    changed = meter.observe(message: "a", usage: start); #expect(!changed)
    changed = meter.observe(message: "a", usage: .object(["output_tokens": .number(7)])); #expect(changed)
    #expect(meter.last == 107)
    #expect(meter.total == TokenCounters(input: 150, cached: 100, output: 10))
    changed = meter.observe(message: "b", usage: .object(["unexpected": .bool(true)])); #expect(!changed)
    changed = meter.observe(message: "b", usage: .object(["input_tokens": .number(1), "cache_read_input_tokens": .number(110), "output_tokens": .number(2)])); #expect(changed)
    #expect(meter.last == 113)
    // A smaller turn summary cannot shrink what the stream already reported.
    var reported = meter
    reported.complete(result: .object(["usage": .object(["input_tokens": .number(1), "output_tokens": .number(1)])]))
    #expect(reported.base == TokenCounters(input: 261, cached: 210, output: 12))
    #expect(reported.window == 200_000)
    meter.abandon()
    #expect(meter.base == TokenCounters(input: 261, cached: 210, output: 12))
    #expect(meter.snapshot().contextFraction == 113.0 / 200_000)
    #expect(ClaudeUsageMeter.window(.object(["x": .object(["contextWindow": .number(1_000_000), "inputTokens": .number(500)]),
        "y": .object(["contextWindow": .number(200_000), "inputTokens": .number(5)])]), model: "unknown") == 1_000_000)
}

@MainActor @Test func usageFooterShowsSizeBeforeWindowIsKnown() {
    #expect(UsageDetail.footer(nil, language: .english) == "Context: no data")
    #expect(UsageDetail.footer(UsageSnapshot(last: 12_345), language: .english) == "Context: 12,345 tokens")
    #expect(UsageDetail.footer(UsageSnapshot(last: 500, window: 1000), language: .english) == "Context ≈50%")
    #expect(UsageDetail.footer(UsageSnapshot(last: 12_345), language: .russian) == "Контекст (токены): 12\u{a0}345")
    #expect(UsageDetail.footer(UsageSnapshot(last: 500, window: 1000), language: .russian) == "Контекст ≈50%")
    #expect(UsageDetail.footer(nil, language: .russian) == "Контекст: нет данных")
}

private let claudeSkills = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Skills")
private actor StartCounter {
    var value = 0
    func increment() { value += 1 }
}
private func generationRequest(_ recipe: AgentGenerationRequest.Recipe, context: AgentContext, session: AgentSessionReference,
                               input: String, id: UUID = UUID()) -> AgentGenerationRequest {
    .init(id: id, source: session, recipe: recipe, historicalInput: input, model: .init(context: context, model: "claude-test"), route: .direct, language: "en")
}
private func generatedCalls(_ home: URL) -> [JSONValue] {
    guard let text = try? String(contentsOf: home.appendingPathComponent("generated"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
}
/// Connects the fixture and completes one "hello" turn, returning the source chunk to summarize.
private func completedClaudeSession(_ adapter: ClaudeIntegration, binary: URL, home: URL, root: URL) async throws -> (AgentDescriptor, AgentSessionReference, SummarySource.Chunk) {
    let events = ClaudeEvents()
    let reader = Task { for await event in adapter.events { await events.append(event) } }
    defer { reader.cancel() }
    let descriptor = try await adapter.connect(.init(executable: binary, home: home)).value()
    let session = try await adapter.prepare(interactiveRequest(context: descriptor.context, root: root)).value()
    _ = try await adapter.submit(interactiveRequest(context: descriptor.context, root: root, session: session)).value()
    try await waitFor { await events.completion() != nil }
    let source = try await adapter.summarySource(session, context: descriptor.context).value()
    let chunks = try SummarySource(digest: source.digest, fragments: source.fragments.map { .init(reference: $0.reference, kind: $0.kind, text: $0.text) },
                                   turnDates: source.turnDates, omittedDetails: source.omittedDetails).chunks
    return (descriptor, session, try #require(chunks.first))
}

@Test func claudeIsolatedGenerationSummarizesTitlesAndHandsOffWithoutTouchingSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (descriptor, session, chunk) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    #expect(descriptor.capabilities.contains(.isolatedGeneration))
    #expect(chunk.fragments.map(\.kind) == ["userMessage", "agentMessage"])
    #expect(chunk.fragments.first?.text == "hello")
    let workspace = root.appendingPathComponent("workspace")
    let environment = AgentGenerationEnvironment(executable: nil, home: home, workspace: workspace,
                                                 recipeDirectory: claudeSkills.appendingPathComponent("archive-summary"))
    let starts = StartCounter()
    let request = generationRequest(.archiveSummaryV1, context: descriptor.context, session: session, input: chunk.json)
    guard case .summary(let summary, let usage, _) = try await adapter.generate(request, environment: environment, willStart: { await starts.increment() }).value() else {
        Issue.record("No summary"); return
    }
    #expect(summary.overview == "Fixture overview")
    #expect(summary.activities.first?.evidence == [chunk.fragments[0].reference])
    #expect(usage == AgentUsage(input: 100, cachedInput: 70, output: 5))
    #expect(await starts.value == 1)
    guard case .rejected(.unknownRequest) = await adapter.generate(request, environment: environment, willStart: {}) else { Issue.record("Replay accepted"); return }
    guard case .title(let title) = try await adapter.generate(generationRequest(.chatTitleV1, context: descriptor.context, session: session, input: "hello"),
                                                              environment: environment, willStart: {}).value() else { Issue.record("No title"); return }
    #expect(title == "Fixture title")
    guard case .handoff(let handoff) = try await adapter.generate(generationRequest(.contextHandoffV1, context: descriptor.context, session: session, input: "{}"),
                                                                  environment: environment, willStart: {}).value() else { Issue.record("No handoff"); return }
    #expect(try HandoffSummary.validate(handoff).goal == "Fixture goal")
    let calls = generatedCalls(home)
    #expect(calls.count == 3)
    #expect(calls.allSatisfy { ($0["cwd"].string ?? "").hasSuffix("/workspace") })
    #expect(calls[0]["input"].string?.hasPrefix("The following JSON is historical evidence") == true)
    // Generation never resumes or extends the source conversation.
    #expect(try String(contentsOf: home.appendingPathComponent("submitted"), encoding: .utf8).split(separator: "\n").count == 1)
    #expect(try await adapter.history(session, context: descriptor.context).value().count == 1)
    await adapter.disconnect()
}

@Test(arguments: ["error", "invalid", "hang"]) func claudeIsolatedGenerationFailuresAreReportedWithoutRetry(_ mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (descriptor, session, chunk) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    try Data(mode.utf8).write(to: home.appendingPathComponent("generation-mode"))
    let request = generationRequest(.archiveSummaryV1, context: descriptor.context, session: session, input: chunk.json)
    let environment = AgentGenerationEnvironment(executable: nil, home: home, workspace: root.appendingPathComponent("workspace"),
                                                 recipeDirectory: claudeSkills.appendingPathComponent("archive-summary"))
    let task = Task { await adapter.generate(request, environment: environment, willStart: {}) }
    if mode == "hang" {
        try await waitFor { !generatedCalls(home).isEmpty }
        await adapter.cancelGeneration(request.id)
    }
    guard case .failed(let failure) = await task.value else { Issue.record("Failure was not reported"); return }
    // A stopped call may already have run; a returned error or rejected result is a known outcome.
    #expect(failure.delivery == (mode == "hang" ? .uncertain : .confirmed))
    #expect(generatedCalls(home).count == 1)
    await adapter.disconnect()
}

@Test func claudeIsolatedGenerationRejectsForeignProfilesAndConnections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (descriptor, session, chunk) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    let request = generationRequest(.archiveSummaryV1, context: descriptor.context, session: session, input: chunk.json)
    let foreign = AgentGenerationEnvironment(executable: nil, home: root.appendingPathComponent("other"), workspace: root.appendingPathComponent("workspace"),
                                             recipeDirectory: claudeSkills.appendingPathComponent("archive-summary"))
    guard case .rejected(.wrongConnection) = await adapter.generate(request, environment: foreign, willStart: {}) else { Issue.record("Foreign profile accepted"); return }
    let codex = generationRequest(.chatTitleV1, context: descriptor.context, session: .init(connection: .originalCodex, nativeID: session.nativeID), input: "hello")
    let local = AgentGenerationEnvironment(executable: nil, home: home, workspace: root.appendingPathComponent("workspace"))
    guard case .rejected(.wrongConnection) = await adapter.generate(codex, environment: local, willStart: {}) else { Issue.record("Codex source accepted"); return }
    guard case .rejected(.wrongConnection) = await adapter.summarySource(.init(connection: .originalCodex, nativeID: session.nativeID), context: descriptor.context) else {
        Issue.record("Codex source read"); return
    }
    #expect(generatedCalls(home).isEmpty)
    await adapter.disconnect()
}

@Test @MainActor func claudeArchivedChatIsSummarizedOnItsOwnConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try interactiveFixture(root), home = root.appendingPathComponent("home")
    let adapter = ClaudeIntegration()
    let (_, session, _) = try await completedClaudeSession(adapter, binary: binary, home: home, root: root)
    let store = AppStore(file: root.appendingPathComponent("store.sqlite"))
    let model = DeskModel(claudeIntegration: adapter, store: store, pluginDirectory: root.appendingPathComponent("plugins"),
                          summaryResources: claudeSkills, summaryHome: root.appendingPathComponent("codex"), claudeHome: home)
    let project = Project(path: root.path)
    let chat = Chat(session: session, projectID: project.id, title: "Claude", model: "")
    model.state.projects = [project]; model.state.chats = [chat]
    model.state.model = "codex-model"; model.state.claudeModel = "claude-test"
    // Codex stays disconnected: Claude chats must not depend on it.
    model.claudeConnected = true; model.claudeAuthenticated = true
    #expect(model.canGenerateSummary(chat.id))
    await model.setChatArchived(chat.id, archived: true)
    await model.queueMissingArchiveSummaries()
    await model.summaryTask?.value
    let record = try #require(model.archiveSummaries[chat.id])
    #expect(record.status == .ready)
    #expect(record.model == "claude-test")
    #expect(record.parts.first?.content.overview == "Fixture overview")
    #expect(try await store.loadArchiveSummaries()[chat.id]?.status == .ready)
    let calls = generatedCalls(home)
    #expect(calls.count == 1)
    #expect(calls.first?["args"].array.contains(.string("claude-test")) == true)
    await model.shutdown()
}
