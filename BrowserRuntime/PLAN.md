# Chrome DevTools integration

Source: user-approved implementation following the 2026-09-26 board, application
and authenticated LinkedIn benchmarks. This is an adapter, not a browser engine.

## Delivery sequence

1. Install and verify Chrome DevTools MCP 1.10.1 by published SHA-512; connect it
   through an app-bundled stdio adapter and an opt-in native settings control.
   Keep browser data under Context Desk and leave Codex/project policies intact.
2. Add compact selector-based card extraction, incremental scrolling, stable
   metadata checks, explicit partial results and bounded response sizes.
3. Verify navigation and pagination postconditions. Persist private checkpoints,
   at-most-once action records and per-session latency/byte counters.
4. Keep one upstream process and one token-owned work tab. Serialize requests,
   deny unknown protocol requests and latch uncertain transport outcomes.
5. Build the app, then validate Swift behavior, both copy languages, transport
   failure cases and real Chrome against local lazy-loading/no-op fixtures.
   Commit and push only after the build and required checks pass.

## Acceptance and limits

- Empty/loading lists and blank placeholders must not be called complete.
- A successful click must not imply successful pagination or submission.
- Reusing an action ID must never dispatch again, including after restart.
- Missing runtime must not prevent ordinary Codex use when browsing is disabled.
- No automatic browser login, credential copying, scheduler changes or model-turn retries.
- Existing native form tools remain available through a scoped action tool;
  submission confirmation is an explicit read-only verification, never a replay.
- Site selectors and task-level all-pages scheduling remain agent responsibilities.
  A saved page checkpoint is evidence, not permission to replay a prior action.
- This release adds metrics, but does not claim a measured production speedup.

Configuration reference: https://developers.openai.com/codex/mcp
Research and private benchmark artifacts remain outside published source.

## Delivered validation — 2026-09-26

The first integration milestone is implemented. The signed app build, 75 Swift
tests, 14 adapter tests, bundled real-Chrome fixture, real-Codex tool discovery
(enabled and disabled), and package verification passed. RU/EN copy reviewed.
No live Settings UI click-through or production speedup measurement is claimed.
Dedicated RAM sampling and automatic checkpoint resume remain future work; the
current checkpoint is durable evidence and never a replay queue.
