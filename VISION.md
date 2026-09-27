# Context Desk — project vision

Date: 2026-09-25; revised 2026-09-27.

Source: agreed product direction, audit of version 0.2.1 at `a6d5b2c`, and user request to update the plan.

Status: accepted direction and revised implementation plan. Stage 1 has a typed contract foundation and a source-audited capability matrix; execution still uses the existing paths. Stages 2–6 remain planned. See [AGENT_CONTRACT.md](AGENT_CONTRACT.md) for boundaries and acceptance evidence.

## Purpose

Context Desk is a persistent, native macOS workspace for AI-assisted development, independent of a particular agent vendor. Users keep their projects, history, instructions and workflows in one application while choosing which supported agent and account performs the work.

The central use case is sequential choice: work through one subscription or account, then explicitly switch to another when needed. Simultaneous use of multiple agents or models is not required for this value proposition. This does not remove existing support for concurrent chats.

An integration must use an authentication and access method supported by its provider. The application does not make subscriptions interchangeable, pool their quotas, or guarantee that every subscription supports every integration.

## Two independent extension points

### Agent integrations

The application will define a versioned, typed integration contract. Each agent module translates operations and events to and from its engine's native protocol. Native RPC method names, JSON payloads and permission-answer encoding belong inside adapters, not application orchestration or views.

The contract should cover:

- Connection lifecycle, authentication status and supported models.
- Starting and continuing sessions, sending work, interruption and completion.
- One-shot scheduled execution and isolated structured generation for titles and archive summaries.
- Streaming messages, tool activity, approval requests and user questions.
- Reading normalized history and registering supported app-owned tools and workflow resources.
- Usage and account limits where the engine exposes them.
- Errors and explicit recovery states without ambiguous automatic retries.
- Declared capabilities, compatibility versions and native session references scoped to an agent and connection identity.

Design the contract against both existing execution paths: interactive Codex and Claude Code print-mode jobs. Extract the full Codex integration first, then migrate the existing Claude job adapter before adding interactive Claude support. Different adapters may expose different capabilities; missing functionality must be visible rather than emulated through another agent.

Start with separate Swift targets and an in-process contract so dependencies can be checked. Independently installable agent modules require a later transport, packaging and compatibility decision; internal extraction alone does not deliver that capability.

### Request optimization integrations

A separate extension point handles compatible request routing and optimization, including caching, context reduction and metrics. Users should be able to choose an agent independently from the available optimization modules, including an explicit no-optimization route.

Independence does not imply universal compatibility. A module must declare requirements for the request protocol, authentication, streaming and tool calls. An engine must expose a supported way to route requests through that module. The application should offer only validated combinations.

Examples of target configurations:

- Codex without an optimization module.
- Codex with the existing Headroom route.
- Claude Code with an optimization module, once that combination is implemented and verified.

Claude Code compatibility with Headroom or any other optimizer is not established by this vision. Optimization and savings must be measured; they are not guaranteed by installing a module.

The selected route must remain visible. An unavailable module must not silently cause fallback to another route, account or agent.

The existing process-plugin protocol v1 configures Codex Responses proxies using OpenAI authentication and the app's Codex home. Preserve that behavior during extraction and move its engine-specific configuration into the Codex adapter. Agent selection, optimization routing and browser/tool integration are separate concerns; Claude support must not be inferred from an existing optimization plugin's presence.

## Ownership and boundaries

| Layer | Responsibility |
| --- | --- |
| Application | Projects, app conversation identities, readable history and archive, drafts and queues, scheduler and run ledger, portable instructions and routine definitions, navigation, explicit choices and presentation of permissions. |
| Agent integration | Protocol translation, connection and authentication lifecycle, native session mapping, capability reporting, normalized events/history, permission encoding, model/metric decoding and supported tool configuration. |
| Agent engine | Task execution, native session state, its tool system and enforcement of its supported permissions. |
| Optimization integration | Explicitly configured request processing and truthful metrics for supported routes. |

The app-owned history is a portable record, not a replacement for all engine state. Today Codex owns the actual chat transcripts; SQLite stores app metadata, usage, timing and generated archive summaries. Opening an archived chat still reads its transcript from Codex. A summary is not a complete transcript.

Introduce stable app conversation IDs with explicit agent/connection identities and native session references. Migrate chats, queued messages, archive summaries, timing, usage and scheduled-run associations together. Existing records map to the existing app-owned Codex connection. Preserve unavailable integrations as unavailable; retain their readable records without rerouting execution. Model selections, account status and defaults must be scoped to the integration.

Define normalized transcript snapshots with completeness and revision information, backfill through adapters and preserve the original engine's execution state. Readable local history must ship before claiming independence from an installed engine. Cross-agent continuation remains an explicit handoff into a new session.

Codex credentials, settings and sessions remain in the app-dedicated home. Current Claude jobs use existing CLI authentication/configuration in place and disable session persistence; they do not establish an equivalent app-owned Claude home. Before interactive Claude support, establish and validate its authentication/configuration boundary explicitly. Do not copy credentials or silently mutate either external installation's state.

The application must not imply that two engines have identical permission or sandbox semantics. An adapter must preserve the requested restrictions or report that it cannot support them. Unknown requests fail closed.

In particular, the current Claude job runner denies new permission prompts but does not receive the app's `Project.accessMode`. That behavior must not be presented as equivalent to Codex's workspace/network sandbox. The shared contract carries permission intent, while each adapter validates and encodes the restrictions it actually supports.

Titles and archive summaries require separately verified isolated generation: bounded input, tools disabled, structured output, explicit model/route, and no retry after uncertain delivery. Disable this capability where its restrictions cannot be established. Never silently send one agent's conversation to another agent for background processing.

Browser and workflow configuration should be app-owned descriptions that adapters register through supported mechanisms. Today browser launch settings and skill registration are Codex-specific. Render agent identity dynamically, offer model/effort controls by capability, and distinguish unavailable usage or account-limit data from zero. New or changed app-owned copy must ship in Russian and English.

## Switching agents and transferring context

Choosing a different agent for a new chat is the simplest initial switch. Existing sessions remain associated with their original agent.

Continuing a task with another agent is an explicit handoff into a new session. A portable handoff should include the goal, relevant instructions, decisions, changed files, actual validation results and remaining work. It must distinguish historical output from instructions.

A handoff cannot promise identical hidden context, internal reasoning, tool state or native session continuation. Switching must not replay commands, duplicate a pending turn, approve outstanding requests or silently resume queued work.

## Portable routines

Routines should belong to the application rather than one engine's proprietary configuration. Their portable definition should express intent, inputs, steps, constraints and completion checks.

For example: inspect the changes, run the project's checks, resolve failures, and prepare a commit. Each integration maps supported parts to its engine. Unsupported requirements must be visible; provider-specific extensions must be identified as such rather than treated as portable.

Portable routine definitions and a scheduler are separate concerns. The app already owns schedules and run history and executes Codex and Claude Code jobs while running, under the user's standing authorization of 2026-09-27. Reuse this scheduler when extracting adapters. Preserve durable claims before dispatch, single-owner locking, concurrency limits, missed-run handling, cancellation and uncertain-run pauses without automatic retry.

External schedule definitions are imported only on explicit selection. Imports remain paused until review and confirmation that the original schedule is disabled. Never mutate external Codex automations or Claude schedules. Executing a scheduled prompt does not yet provide a general portable multi-step routine format. Execution while the app is closed remains future work.

## Current implementation versus target

Currently shipped:

- A native SwiftUI/AppKit client backed by Codex, with app-dedicated credentials and state.
- Projects, chat navigation, drafts, queues, archive, notifications and usage displays.
- Process-based provider plugins for compatible Responses request routes inside Codex, including the optional Headroom integration.
- App-owned schedules and persistent run history: Codex jobs create app chats; Claude Code print-mode jobs record their result in run history.
- Semantic chat titles and archive summaries generated through isolated Codex requests.
- Browser MCP launch configuration and app-owned workflow skills registered with Codex.

Not yet implemented:

- Extracted Codex module and runtime adoption of the new engine-independent contract.
- Interactive Claude Code sessions and agent selection for chats; the existing job-only adapter is not full interactive support.
- App-owned portable transcripts and cross-agent handoffs.
- Portable routine definitions and execution mappings.
- A validated compatibility model spanning multiple agents and optimization modules.

Existing provider plugins are the starting point for the optimization layer. They are not currently interchangeable agent engines.

## Implementation plan

Stage 1's contract foundation is implemented; subsequent stages remain planned. Each stage should preserve current behavior and pass its acceptance checks before the next dependent stage enables new execution paths.

### 1. Define the contract against both existing engines

Status (2026-09-27): contract foundation implemented in the independent `AgentContract` Swift target. [Capability matrix and semantics](AGENT_CONTRACT.md) document both existing execution paths, unsupported operations, identity/route boundaries, cancellation and uncertain delivery. Production adapters are not yet extracted or connected to this API. No new execution path is enabled.

Define typed identities, operations, events, outcomes and capabilities for interactive sessions, scheduled jobs, isolated generation, permissions, history, tools, model discovery and optional metrics. Use the existing Claude job path to challenge assumptions inherited from Codex before stabilizing the API. Keep connection/account selection separate from optimization routes.

Acceptance: document the capability matrix for current Codex and Claude jobs; classify unsupported operations explicitly; define uncertain delivery, cancellation and recovery without fallback or replay. Native RPC payloads must not be part of the app-facing API.

### 2. Introduce identity and persistence migration

Add app conversation IDs, agent/connection references and native session mapping. Migrate dependent records together, including queues, summaries, timings, usage and job-run links. Define the transcript snapshot schema now; full readable-history delivery is part of stage 5.

Acceptance: legacy data loads with the original Codex association; identical native IDs from different connections stay distinct; migration interruption does not partially remap records; missing agents retain their records without dispatch or fallback. Queued and uncertain work must not resume merely because data was migrated.

### 3. Extract the complete Codex integration

Move RPC calls and event parsing, account/model discovery, permissions, history decoding, metrics, optimization-route configuration, browser/skill registration and isolated generation into the Codex adapter. Application code continues to own navigation, queues, scheduling policy and presentation. Enforce the boundary through separate Swift targets.

Acceptance: interactive chats, parallel work, approvals, interruption, archive operations, titles, summaries and Codex scheduled jobs preserve their behavior. Application/UI code cannot import the native Codex transport or issue its RPCs. No tool-enabled substitute is used for isolated generation; unknown requests and unavailable routes continue to fail closed.

### 4. Route the existing scheduler through agent executors

Replace engine-specific dispatch branches with the common execution contract while retaining the existing scheduler and Claude print runner. Expose Claude's external-CLI identity mode and capability limits. Validate requested project restrictions before dispatch; unsupported restrictions must produce an explicit outcome.

Acceptance: both engines satisfy shared lifecycle/error tests with their different capability sets. Preserve ownership locking, durable claims, concurrency limits, import confirmation, stop behavior and uncertain-run recovery. Codex jobs still create app chats without disturbing the selected conversation; Claude job results remain readable in run history.

### 5. Deliver interactive Claude and readable local history

Establish the supported Claude authentication/configuration boundary and pinned protocol. Add streaming, user questions, approvals, interruption, session recovery and explicit agent selection for new chats. Implement normalized transcript persistence and adapter-based backfill with completeness/revision tracking. Keep native sessions bound to their original engine. Gate background titles, summaries, tools and metrics on independently verified capabilities.

Acceptance: perform an end-to-end workflow on each supported engine without losing readable history or weakening permissions. Saved history is readable when its engine is unavailable, with incomplete backfills clearly identified. Disconnects do not replay turns; switching does not transfer pending approvals, queue entries or native session IDs to another engine. Verify all changed app-owned UI in Russian and English.

### 6. Extend handoffs, routines and validated compatibility

Add explicit context handoff into a new session, portable multi-step routine definitions and independently verified optimizer combinations. Decide separately whether agent modules need external packaging and installation. Neither general plugin packaging nor universal optimizer compatibility is a prerequisite for the first two-engine workflow.

Acceptance: handoff content distinguishes historical evidence from instructions, records provenance and never replays actions. Unsupported routine requirements and optimizer combinations remain visible and unavailable rather than silently altered.

## Validation and delivery

Keep regression coverage for routing, token accounting, persistence, queues, approvals, archive behavior, scheduler recovery and background isolation. Add migration and adapter-contract tests, including colliding native IDs, missing engines, account changes, unsupported restrictions, cancellation and ambiguous delivery. A dependency check must prevent native protocol usage in app/UI targets.

For each implementation change, build successfully with `zsh scripts/build-app.sh`, then verify the result and run `zsh scripts/test.sh` and relevant capability checks before committing and pushing. Record actual results and distinguish fixture coverage from live-provider verification. Do not claim readiness when required validation fails or remains blocked; never interrupt a running user session automatically.

Progress should be evaluated by whether a user can change supported agents without rebuilding their project setup, losing readable history, or weakening permissions. Full feature parity and simultaneous multi-agent orchestration are not prerequisites.
