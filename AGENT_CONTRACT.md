# Agent integration contract v1

Implemented 2026-09-27 as stage 1 of [VISION.md](VISION.md). `Sources/AgentContract`
contains a Foundation-only Swift target, typed operations and events, preflight
validation and conservative delivery tracking. It has no engine transport imports,
native method names, arbitrary JSON or permission-answer payloads.

This is a contract foundation, not an extracted adapter. Existing execution paths
are unchanged and do not yet conform to `AgentIntegration`. Stages 2–6 remain
planned. In particular, no new interactive Claude support, portable persisted
history, optimizer compatibility or general plugin installation is delivered.

## Evidence and current capability matrix

This matrix describes the checked-in implementation, not all features offered by
either provider. Availability is connection-specific. An adapter must advertise
only verified capabilities at runtime; this table must not become an unconditional
capability switch.

| Operation | Current Codex path | Current Claude Code jobs |
| --- | --- | --- |
| Identity | App-dedicated home; app manages sign-in/out | Existing CLI authentication/configuration in place; no app-owned home |
| Interactive start/continue | Supported | Unsupported |
| One-shot scheduled execution | Creates app chat; app scheduler owns claim and ledger | Print JSON result; no persisted native session |
| Stream text/tool activity | Supported | Unsupported in current runner |
| Approval UI and user questions | Known requests supported; unknown requests rejected | New prompts denied; permission denials block job |
| Interrupt | Turn interruption; transport loss can remain uncertain | Process termination; does not prove rollback or all side effects stopped |
| Native history/archive | Read/archive/unarchive supported | Unsupported with no session persistence |
| Portable local transcript | Not yet implemented | Not yet implemented |
| Isolated title/summary | Separate ephemeral runner, bounded recipes, tools disabled, schema checked, pinned version | Unsupported; never delegate to Codex |
| Models/effort discovery | Supported | Unsupported; configured model string only |
| Token usage/account limits | Available where exposed by engine | Not normalized by current runner; unsupported, not zero |
| Browser/workflow registration | Existing Codex configuration | Unsupported by current runner |
| Optimization route | Explicit direct or available Responses plugin; engine-specific configuration | External CLI configuration; neither verified direct nor verified optimizer route |
| Project permission intent | Standard workspace write/no network/ask; explicitly selected unrestricted/never | Existing runner does not receive `Project.accessMode`; cannot claim either policy |

Evidence: `Sources/ContextDesk/DeskModel.swift`, `JobScheduling.swift`,
`Sources/ContextCore/Models.swift`, `ClaudeJobRunner.swift`,
`ArchiveSummaryRunner.swift`, `BrowserConfiguration.swift`, `ProviderPlugin.swift`
and `RequestRoute.swift`. Claude runner pins `2.1.260`; isolated Codex generation
pins `0.158.0-alpha.2.1`. The ordinary Codex connection currently has no equivalent
runtime version gate. Extraction must establish its compatibility check rather
than claim that isolated-generation validation covers interactive execution.
No provider documentation or live-provider tests were needed for this source audit.

## Identity and ownership

`ConversationID` is app-owned and distinct from `AgentSessionReference`. A native
reference is scoped to both agent and connection. Unknown agent IDs round-trip as
unavailable identities, never as a default engine. Stage 2 must atomically migrate
all dependent records before using these types in persistence. Merely defining
these types does not migrate existing data or resume queues.

`AgentContext` adds an account revision. Rotate it after account changes; reject
old model selections, submissions and approval answers. Adapters retain the opaque
mapping from app interaction IDs to native request IDs and invalidate it on
resolution, reconnect and account changes. `AgentApproval.accepts` checks identity
and offered choices; adapters must additionally enforce one-time consumption and
reject stale/unknown requests. Native request/answer encoding stays inside adapters.

App orchestration owns project selection, queues, scheduler policy, durable claims,
run history and display. Each adapter instance owns one connection. `submit` starts
a session when no native session exists; a scheduled Claude result may have no
session reference. `success(handle)` acknowledges submission, not task completion.
Events carry the handle to avoid associating parallel work with the selected chat.
Unsupported operations return typed rejections; unavailable engines retain readable
records without dispatch or fallback.

## Permission and route validation

`AgentDescriptor.validate` checks exact contract version, current account context,
session connection, operation capability, available route and permission intent.
Workspace permission roots must match the requested project. The initial permission
support intentionally accepts only the combinations the current implementation
actually encodes; unverified combinations fail closed.

Claude's `externalPolicyDenyPrompts` is a distinct explicit policy. It MUST NOT be
inferred from either project access mode. Stage 4 must reject unsupported project
restrictions before dispatch, or add a separately verified policy and explicit UI
choice. Defining the contract does not fix the existing scheduler's restriction gap.
`externalConfiguration` exposes CLI-controlled routing without promising a direct
connection. Missing routes cannot be replaced by direct, another optimizer or agent.

The contract normalizes command/file/permission approval and text/choice questions.
An adapter rejects any native request or structured elicitation form that cannot be
represented faithfully; it must not drop restrictions or flatten unknown schemas
into an approval. Tool servers and workflow directories are app-owned descriptions;
registration returns unsupported when an engine cannot safely configure them.

## Delivery, cancellation and recovery

1. Validate while nothing has been sent. Rejection has no engine side effects.
2. Scheduler persists its durable claim before dispatch; adapter marks dispatch
   before any execution bytes can leave. Request IDs correlate work, not retries.
3. Acknowledgement associates the request with its engine handle. It does not mean
   completion and cannot clear an uncertain result.
4. Cancellation before dispatch is confirmed locally. After dispatch it is only a
   request until the engine confirms a terminal state. Killing a connection or
   losing an acknowledgement produces `uncertain`, including during cancellation.
5. A terminal state is immutable in the tracker. Late success after uncertainty
   needs explicit reconciliation; it never restarts a paused schedule or queue.
6. No adapter automatically replays any outcome. The app preserves existing
   uncertain-run pauses and requires explicit review/recovery. Reconnecting may
   read history; it must not resubmit work or answer pending approvals.

`AgentDeliveryTracker` tests these shared rules without changing current scheduler
behavior. Stage 4 must run the same lifecycle fixtures against both real adapters.

## Isolated generation and history

Generation uses closed, versioned title/summary recipes, explicit model and route,
a source connection, and a 128 KiB UTF-8 upper bound. Each recipe may impose a
smaller bound. Adapters must independently verify tools-disabled ephemeral execution,
validate structured output, and reject unknown tool requests. Capability support and
preflight alone do not establish isolation. Cross-agent background generation is
rejected. Provider-specific JSON schemas remain private to adapters; structured
summary output preserves the existing overview/activity structure, including goals,
actions, outcomes, unfinished work, reusable steps, variable inputs and evidence.

Transcript snapshot schema v1 records app conversation ID, original native reference,
revision, capture time and completeness. Text/tool output stays literal historical
data. An unavailable or partial snapshot must never be displayed as complete; an
empty item list is not proof of completeness. Readers must reject unsupported schema
versions. Stage 2 defines storage/migration; stage 5 implements backfill/readable
history. No hidden engine state or cross-engine continuation is implied.

## Verification and remaining boundaries

Contract fixtures cover colliding session IDs, unknown-agent round trips, account
changes, missing routes, permission downgrades, cross-request approvals, cancellation,
ambiguous delivery and snapshot completeness. They do not execute providers or
migrate private app data. Existing regression tests still exercise current paths.
`python3 scripts/check-agent-boundary.py` ensures this target remains independent;
SwiftPM and the direct compiler fallback both include it.

Stage 3 must extend the dependency check to prohibit native Codex imports and RPC
calls in application/UI targets once extraction is complete. Enforcing that ban now
would fail on intentionally unmigrated production code. New app-owned UI copy must
be paired Russian/English when these types are connected to presentation; this
stage adds no product copy.

Validation on 2026-09-27: the signed app build passed with SwiftPM/macOS 26.5 SDK;
116 tests passed through SwiftPM and the direct compiler fallback (optional scheduler
UI rendering probe skipped). Bundle signature/source digest and contract dependency
checks passed. A duplicate-descriptor regression also fixed explicit scheduler lock
release; direct-runner compatibility and a pre-layout UI test assertion were corrected
during verification. Provider behavior is audited from source and existing fixtures,
not newly verified against live accounts. No app-owned copy changed.
