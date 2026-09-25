# Context Desk — project vision

Date: 2026-09-25  
Source: product direction agreed with the user in the current project discussion.  
Status: accepted direction; the architecture below is a target, not a claim of shipped support.

## Purpose

Context Desk is a persistent, native macOS workspace for AI-assisted development, independent of a particular agent vendor. Users keep their projects, history, instructions and workflows in one application while choosing which supported agent and account performs the work.

The central use case is sequential choice: work through one subscription or account, then explicitly switch to another when needed. Simultaneous use of multiple agents or models is not required for this value proposition. This does not remove existing support for concurrent chats.

An integration must use an authentication and access method supported by its provider. The application does not make subscriptions interchangeable, pool their quotas, or guarantee that every subscription supports every integration.

## Two independent extension points

### Agent integrations

The application defines a versioned integration contract. Each agent module translates that contract to and from its engine's native protocol.

The contract should cover:

- Connection lifecycle, authentication status and supported models.
- Starting and continuing sessions, sending work, interruption and completion.
- Streaming messages, tool activity, approval requests and user questions.
- Usage and account limits where the engine exposes them.
- Errors and explicit recovery states without ambiguous automatic retries.
- Declared capabilities, compatibility versions and session identifiers scoped to an integration.

The first module will extract the existing Codex integration. Claude Code is the intended second integration and the first practical test of independence from Codex. The exact module transport and packaging remain implementation decisions.

### Request optimization integrations

A separate extension point handles compatible request routing and optimization, including caching, context reduction and metrics. Users should be able to choose an agent independently from the available optimization modules, including an explicit no-optimization route.

Independence does not imply universal compatibility. A module must declare requirements for the request protocol, authentication, streaming and tool calls. An engine must expose a supported way to route requests through that module. The application should offer only validated combinations.

Examples of target configurations:

- Codex without an optimization module.
- Codex with the existing Headroom route.
- Claude Code with an optimization module, once that combination is implemented and verified.

Claude Code compatibility with Headroom or any other optimizer is not established by this vision. Optimization and savings must be measured; they are not guaranteed by installing a module.

The selected route must remain visible. An unavailable module must not silently cause fallback to another route, account or agent.

## Ownership and boundaries

| Layer | Responsibility |
| --- | --- |
| Application | Projects, app-owned history and archive, drafts, portable instructions and routine definitions, navigation, explicit choices and presentation of permissions. |
| Agent integration | Protocol translation, connection and authentication lifecycle, engine session mapping, capability reporting and normalized events. |
| Agent engine | Task execution, native session state, its tool system and enforcement of its supported permissions. |
| Optimization integration | Explicitly configured request processing and truthful metrics for supported routes. |

The app-owned history is a portable record, not a replacement for all engine state. Today Codex owns the actual transcripts; independent history requires an explicit data model and migration plan. Credentials and engine state must remain isolated and must not be copied from the user's existing installations.

The application must not imply that two engines have identical permission or sandbox semantics. An adapter must preserve the requested restrictions or report that it cannot support them. Unknown requests fail closed.

## Switching agents and transferring context

Choosing a different agent for a new chat is the simplest initial switch. Existing sessions remain associated with their original agent.

Continuing a task with another agent is an explicit handoff into a new session. A portable handoff should include the goal, relevant instructions, decisions, changed files, actual validation results and remaining work. It must distinguish historical output from instructions.

A handoff cannot promise identical hidden context, internal reasoning, tool state or native session continuation. Switching must not replay commands, duplicate a pending turn, approve outstanding requests or silently resume queued work.

## Portable routines

Routines should belong to the application rather than one engine's proprietary configuration. Their portable definition should express intent, inputs, steps, constraints and completion checks.

For example: inspect the changes, run the project's checks, resolve failures, and prepare a commit. Each integration maps supported parts to its engine. Unsupported requirements must be visible; provider-specific extensions must be identified as such rather than treated as portable.

Portable routine definitions and a scheduler are separate concerns. The current scheduled-job viewer remains read-only. This vision does not authorize writing to existing Codex automations, creating another scheduler, or running migrated routines.

## Current implementation versus target

Currently shipped:

- A native SwiftUI/AppKit client backed by Codex, with app-dedicated credentials and state.
- Projects, chat navigation, drafts, queues, archive, notifications and usage displays.
- Process-based provider plugins for compatible Responses request routes inside Codex, including the optional Headroom integration.

Not yet implemented:

- An engine-independent agent contract and extracted Codex module.
- A Claude Code integration and agent selection.
- App-owned portable transcripts and cross-agent handoffs.
- Portable routine definitions and execution mappings.
- A validated compatibility model spanning multiple agents and optimization modules.

Existing provider plugins are the starting point for the optimization layer. They are not currently interchangeable agent engines.

## Implementation direction

1. Define ownership, capabilities, normalized events and persistence boundaries.
2. Extract Codex behind the common contract while preserving current behavior.
3. Add Claude Code and validate an end-to-end workflow, including approvals, interruption and session recovery.
4. Add explicit agent selection and portable context handoffs.
5. Introduce portable routine definitions and independently validated optimization combinations.

Progress should be evaluated by whether a user can change supported agents without rebuilding their project setup, losing readable history, or weakening permissions. Full feature parity and simultaneous multi-agent orchestration are not prerequisites.
