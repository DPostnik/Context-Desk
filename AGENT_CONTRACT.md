# Agent integration contract v1

Implemented 2026-09-27 as stage 1 of [VISION.md](VISION.md). `Sources/AgentContract`
contains a Foundation-only Swift target, typed operations and events, preflight
validation and conservative delivery tracking. It has no engine transport imports,
native method names, arbitrary JSON or permission-answer payloads.

Execution paths use explicit app/native identity mapping (stage 2). Stage 3 is
in progress: the transport, typed commands/events and approval boundary now live in `CodexAdapter`,
but production does not yet conform to `AgentIntegration`. Stages 4–6 remain planned. In particular, no new interactive Claude support, portable persisted
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
`Sources/CodexAdapter/ArchiveSummaryRunner.swift`, `BrowserConfiguration.swift`, `Sources/ContextCore/ProviderPlugin.swift`
and `RequestRoute.swift`. Claude runner pins `2.1.260`; isolated Codex generation
pins `0.158.0-alpha.2.1`. The ordinary Codex connection currently has no equivalent
runtime version gate. Extraction must establish its compatibility check rather
than claim that isolated-generation validation covers interactive execution.
No provider documentation or live-provider tests were needed for this source audit.

## Identity and ownership

`ConversationID` is an opaque app-owned string, distinct from `AgentSessionReference`;
new values use UUID strings. A native reference is scoped to both agent and
connection. Unknown agent IDs round-trip as unavailable identities, never as a
default engine. Stage 2 now migrates persisted associations without renaming legacy
keys or resuming queues; details are below.

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
versions. Stage 2 implements schema storage/migration; stage 5 implements
engine-backed collection, backfill and readable history. No hidden engine state or cross-engine continuation is implied.

## Verification and remaining boundaries

Contract fixtures cover colliding session IDs, unknown-agent round trips, account
changes, missing routes, permission downgrades, cross-request approvals, cancellation,
ambiguous delivery and snapshot completeness. They do not execute providers or
migrate private app data. Existing regression tests still exercise current paths.
`python3 scripts/check-agent-boundary.py` ensures this target remains independent;
SwiftPM and the direct compiler fallback both include it.

The stage-3 command increment extends the dependency check to prohibit native
transport access and raw RPC dispatch in application/UI targets. The event increment additionally prohibits `JSONValue` and native method literals
in app/UI sources. Shared-core native decoder helpers and full runtime contract
adoption remain separate work. New app-owned UI copy must
be paired Russian/English when these types are connected to presentation; this
stage adds no product copy.

Validation on 2026-09-27: the signed app build passed with SwiftPM/macOS 26.5 SDK;
116 tests passed through SwiftPM and the direct compiler fallback (optional scheduler
UI rendering probe skipped). Bundle signature/source digest and contract dependency
checks passed. A duplicate-descriptor regression also fixed explicit scheduler lock
release; direct-runner compatibility and a pre-layout UI test assertion were corrected
during verification. Provider behavior is audited from source and existing fixtures,
not newly verified against live accounts. No app-owned copy changed.


## Identity migration (stage 2)

Implemented 2026-09-27. `Chat.id` is now the app key; `nativeSession` stores the
agent/connection/native-ID triple. Existing key values remain unchanged, including
non-UUID legacy fixture IDs. New chats receive an independent UUID string, persist
the mapping before submitting a turn, and never use an app ID as a native RPC ID.
`ConversationID`'s serialized string value remains compatible with UUID strings
from the stage-1 schema.

The original app-owned Codex home has the stable, store-local
`AgentConnectionID.originalCodex` identity. Legacy `model`/`defaultRoute` fields are
explicitly scoped by `SavedState.defaultConnection`; an unavailable default cannot
silently create a chat through the original connection. Other connection catalogs
and account lifecycle management remain part of adapter/interactive extraction.

The migration uses a SQLite `BEGIN IMMEDIATE` transaction, re-reads after taking
the write lock, validates unique app IDs and unique scoped native references, writes
explicit session associations and schema version 2, and parks unfinished summary
work. Commit failure rolls everything back. Unknown identity versions, missing
version-2 associations, malformed summary references and attempts to rebind an
existing app ID fail closed. Startup stops before connection/scheduler dispatch on
storage-load failure. Unknown integrations are retained, not converted to Codex.

All dependent keys are adopted together through **identity preservation**:

- Queues keep their app key, content, model, effort and project; startup remains paused.
- Usage, per-turn timings, archive summaries and unread completion IDs keep their keys.
- Drafts and running-turn/approval state use app IDs in memory.
- Scheduled-run JSON keeps its historical `threadID` field as an app reference;
  `JobRun.conversationID` exposes the typed interpretation. The file needs no rewrite,
  so there is no cross-file remapping window. Existing crash recovery keeps unfinished
  runs uncertain and schedules paused. Migration does not enable any schedule.

Outgoing read/resume/send/interrupt/rename/archive/delete requests resolve the
native session only for the original available connection. Incoming thread-scoped
Codex events resolve back to app keys before transcript, usage, completion, approval
or queue handling. Unknown thread-scoped requests are rejected and unknown events
are ignored. Identical native IDs on another connection cannot receive those events.
Background titles, summary execution and queue controls also check connection
availability. Route plugins belonging only to unavailable connections are not started.
These checks are a temporary orchestration boundary until stage 3 moves native
protocol handling into the adapter target.

`transcript:<app-ID>` stores normalized snapshot schema v1, preserving the source
reference, revision, capture time and completeness. Save/read validates version and
source association; chat deletion removes its snapshot with metadata. This API does
not yet capture or backfill engine transcripts and is not a claim of offline history
availability. Existing metadata, summary content and job outputs remain readable;
opening engine-owned history still requires its original available integration.

Migration tests use synthetic SQLite/job files, inject a commit failure, verify
byte-preserving rollback and cross-file links, retain uncertain runs, exercise
colliding native IDs/unavailable connections, reject rebinding/future versions,
and check normalized event/usage routing. Existing send/queue/scheduler fixtures
verify native wire IDs differ from newly created app IDs. No private app data is
used for migration validation.

Stage-2 verification: final signed app build passed with SwiftPM/macOS 26.5 SDK on
2026-09-27, followed by all 123 tests (optional scheduler renderer skipped), contract
boundary, signature/source-digest and diff checks. New unavailable/storage errors
were reviewed in Russian and English. No live-provider turn, private-state migration
or installed-app click-through was performed.


## Codex extraction: command boundary (stage 3, first increment)

`CodexAdapter` depends on `AgentContract` and `ContextCore`; shared core and
transcript targets do not depend on it. Both SwiftPM and the direct compiler recipe
include the new target. `CodexConnection` and its JSONL buffer move out of shared
core. Native transport access is exported only through `NativeProtocol` SPI for
the diagnostic probe and protocol fixtures. Normal application imports use
`CodexClient`, which has no arbitrary request method.

The client owns account/login/logout and model discovery RPCs, limit fetching,
workflow registration, session creation/resume/send/interrupt, naming,
archive/restore/delete, history reading and summary-source retrieval. Session
operations accept `AgentSessionReference` and reject an empty reference or a
foreign agent/connection before dispatch. History verifies the returned native
session ID and requires a turns array before exposing typed history turns. The
application retains persistence-before-send, queue state, scheduler policy and
ledger updates. Model selectors consume typed catalog entries; entries without a
model identifier are not offered. History timings retain stored token details.

The existing isolated runner moves unchanged, retaining its independent version,
configuration and tools-disabled checks. Browser launch settings and native
permission/provider encodings move into the same target. App-owned home selection,
route availability checks, plugin process lifecycle and workflow recipe ownership
remain with existing orchestration. No credentials or installed engine state move.

This increment deliberately does **not** advertise full stage-3 acceptance:
the initial event/approval JSON bridge has now been removed by the increment below.
Several native parsers remain in shared core, and interactive version gating, account
revision lifecycle, capability reporting and `AgentIntegration` conformance still
need implementation. The command DTOs are transitional, not a second portable
integration contract. No interactive Claude path or offline history is enabled.

Stage-3 command-increment verification (2026-09-27): signed SwiftPM/macOS 26.5
app build passed, followed by 126 tests through both SwiftPM and a fresh direct
compiler build (optional scheduler renderer skipped). The added fixtures verify
wire permissions/native routing, rejection of foreign references before dispatch,
model decoding, sign-in URL validation and mismatched/incomplete history rejection.
Signature, current source digest, dependency boundary and diff checks passed.
Existing Russian/English copy was preserved and reviewed; localization fixtures
passed. These are local synthetic-provider checks, not live-provider or installed-UI
acceptance of the complete integration.


## Codex extraction: typed events and interactions (stage 3, second increment)

`CodexClient.events` now streams `CodexEvent`, with connection-scoped session
references and typed message/delta, usage, turn timing/completion, account,
diagnostic and interaction payloads. App orchestration maps sessions back to app
conversation IDs, persists usage/timing, updates notifications and owns queue and
scheduler policy. Application/UI code neither inspects native method names nor
constructs native JSON. Literal request details are display-only evidence.

Native request IDs stay in the adapter. The UI receives a fresh UUID handle and
can submit only a typed response. The adapter checks identity, allowed response
kind and required fields; it consumes the handle before awaiting the write, so
ambiguous delivery never invites a repeated answer. The transport independently
checks a process generation and request nonce immediately before writing. It
invalidates nonces as soon as it reads account changes, request resolution or turn
completion, closing the race while those events are still queued for presentation.
Disconnect and explicit stop invalidate all outstanding interactions. Duplicate
native request IDs cannot regain approval within the same connection lifetime.
Unknown or malformed requests and requests for unowned sessions fail closed.

Supported presentations preserve existing ordinary one-time command/file approvals,
plain text questions (including secret input), HTTPS tool links, plain string MCP
forms and simple legacy path/network permission requests. Command decisions are
restricted to those offered by the engine. `grantRoot` file requests, richer
entry/glob permissions and unsupported form constraints are shown without an
approval/submit control; explicit decline remains available. A constrained form
is never flattened into unrestricted strings. Native user content remains data.
These conservative limits are visible compatibility restrictions, not universal
support for every request type in the provider protocol.

Native schema evidence: generated locally from Codex CLI `0.158.0-alpha.2.1` with
`app-server generate-json-schema --experimental`, using a temporary `CODEX_HOME`.
This inspected the schema only; it neither authenticated nor executed provider
work. It does not establish interactive runtime version gating. The general
`AgentIntegration` account-revision/capability lifecycle is still pending.

The transport has one scoped event stream. Its SPI JSON view is reserved for
isolated runners and diagnostics, avoiding a second unconsumed copy in production.
An oversized wire record closes the connection, invalidates approvals and emits
both an error and a disconnect on the current generation; filtering obsolete
process events must not hide that failure from scheduler/queue recovery.

Stage-3 event-increment verification (2026-09-27): final signed app build passed
with SwiftPM/macOS 26.5 SDK, followed by all 132 tests (optional scheduler renderer
skipped). Six new synthetic-provider tests cover decision/schema restrictions,
scoped single-use answers, transport-time invalidation, unknown/repeated requests,
old generations, turn resolution, timing/missing usage and oversized-input recovery.
Existing routing, notice, queue, scheduler, isolation and persistence fixtures passed.
Russian/English copy was reviewed; boundary, signature/source digest and diff checks
passed. No live-provider approval or installed-app click-through was performed.
