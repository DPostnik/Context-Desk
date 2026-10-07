import Foundation
import Testing
@testable import ClaudeAdapter
@testable import ContextCore

private func usageJSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Test func claudeLimitsDecodePlanWindowsWithoutInventingQuotas() throws {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = try #require(ClaudeLimits.decode(try usageJSON(#"""
    {"subscription_type":"max","rate_limits_available":true,"rate_limits":{
      "five_hour":{"utilization":23.7,"resets_at":"2026-10-07T15:00:00.123Z"},
      "seven_day":{"utilization":140,"resets_at":"2026-10-12T09:00:00Z"},
      "seven_day_sonnet":null,"seven_day_opus":{"utilization":null,"resets_at":null},
      "model_scoped":[{"display_name":"Fable","utilization":-3,"resets_at":"bad"},{"display_name":" ","utilization":5,"resets_at":null}],
      "extra_usage":{"is_enabled":true,"monthly_limit":50,"used_credits":10,"utilization":20}}}
    """#), at: date))
    #expect(snapshot.fetchedAt == date && snapshot.ordinaryUsageAllowed == nil)
    #expect(snapshot.buckets.map(\.id) == ["all", "opus", "model:0:Fable"])
    let all = snapshot.buckets[0].windows
    #expect(all.map(\.id) == ["five_hour", "seven_day"] && all.map(\.durationMinutes) == [300, 10080])
    #expect(all.map(\.remainingPercent) == [77, 0])
    #expect(all[0].resetsAt == Date(timeIntervalSince1970: 1_791_385_200.123))
    #expect(all[1].resetsAt == Date(timeIntervalSince1970: 1_791_795_600))
    // Present with unknown use stays visible; out-of-range use is clamped; bad timestamps are unknown.
    #expect(snapshot.buckets[1].windows[0].remainingPercent == nil)
    #expect(snapshot.buckets[2].name == "Fable" && snapshot.buckets[2].windows[0].remainingPercent == 100)
    #expect(snapshot.buckets[2].windows[0].resetsAt == nil)
}

@Test func claudeLimitsAreUnavailableWithoutPlanLimits() throws {
    #expect(ClaudeLimits.decode(try usageJSON(#"{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}"#)) == nil)
    #expect(ClaudeLimits.decode(try usageJSON(#"{"rate_limits":{"five_hour":{"utilization":1}}}"#)) == nil)
    let empty = try #require(ClaudeLimits.decode(try usageJSON(#"{"rate_limits_available":true,"rate_limits":{}}"#)))
    #expect(empty.buckets.isEmpty)
}

@Test func claudeLimitsProbeSendsNoTurnAndPersistsNoSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binary = root.appendingPathComponent("claude.py"), home = root.appendingPathComponent("home")
    let script = #"""
    #!\#(fixturePython)
    import sys,os,json,pathlib
    home=pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])
    if '--version' in sys.argv: print('2.1.292 (Claude Code)'); sys.exit(0)
    if sys.argv[1:3] == ['auth','status']:
        print(json.dumps({'loggedIn':True,'apiProvider':'firstParty','authMethod':'oauth','email':'fixture'})); sys.exit(0)
    a=sys.argv
    assert '--no-session-persistence' in a and a[a.index('--tools')+1]=='' and '--disable-slash-commands' in a
    assert a[a.index('--setting-sources')+1]=='' and a[a.index('--mcp-config')+1]=='{"mcpServers":{}}'
    assert not any(k in a for k in ['--resume','--session-id','--model','--append-system-prompt'])
    assert not any(k in os.environ for k in ['ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN','ANTHROPIC_BASE_URL'])
    mode=(home/'mode').read_text() if (home/'mode').exists() else 'plan'
    for line in sys.stdin:
        value=json.loads(line)
        with (home/'received').open('a') as f: f.write(value['type']+':'+value.get('request',{}).get('subtype','')+'\n')
        if value['type']!='control_request': continue
        response={}
        if value['request']['subtype']=='get_usage':
            assert value['request']['skip_behaviors'] is True
            response={'rate_limits_available':mode=='plan','rate_limits':{'five_hour':{'utilization':40,'resets_at':None}} if mode=='plan' else None}
        print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':value['request_id'],'response':response}}),flush=True)
    """#
    try Data(script.utf8).write(to: binary)
    try installFixtureExecutable(at: binary)
    let adapter = ClaudeIntegration()
    _ = try await adapter.connect(.init(executable: binary, home: home)).value()
    #expect(try await adapter.descriptor().value().capabilities.contains(.accountLimits))

    let limits = try await adapter.limits().value()
    #expect(limits.buckets.map(\.id) == ["all"] && limits.buckets[0].windows.map(\.remainingPercent) == [60])
    let received = try String(contentsOf: home.appendingPathComponent("received"), encoding: .utf8)
    #expect(received == "control_request:initialize\ncontrol_request:get_usage\n")

    try Data("api-key".utf8).write(to: home.appendingPathComponent("mode"))
    guard case .rejected(.unsupported(.accountLimits)) = await adapter.limits() else { Issue.record("Expected no plan limits"); return }
    await adapter.disconnect()
    guard case .unavailable = await adapter.limits() else { Issue.record("Expected a disconnected adapter to refuse"); return }
}
