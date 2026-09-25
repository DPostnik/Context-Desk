# Compatibility record — 2026-09-25

This is an initial prototype record, not a completed acceptance report.

**Headroom update:** an app-owned Headroom 0.38.0 proxy is now installed and integrated. A real authenticated smoke turn passed through it. See [the integration record](headroom.md) for the current profile, measured results and remaining limitations. The initial observations below predate that integration.

**Later update:** the user completed login and used a real conversation. A UI layout hang then occurred and was fixed; see [the incident record](hang-fix.md) and [the subsequent CPU measurement](cpu-after-fix.json). The observations below describe the original pre-login check, not the latest runtime state.

## Environment

| Component | Observed version |
|---|---|
| Mac | Apple Silicon, macOS 26.6.2 |
| Swift | 6.3.3, Command Line Tools |
| Codex | 0.155.0-alpha.16.4, `/Applications/ChatGPT.app/Contents/Resources/codex` |
| TOMLDecoder | 0.4.5; exact SwiftPM dependency and lockfile |
| Headroom | Source reviewed at `3aa501285705949a123444a5c102d6bbc000afd9` (0.38.0); not installed or connected |

## Verified

| Check | Evidence/result |
|---|---|
| Release `.app` build | `zsh scripts/build-app.sh` succeeded; 2.1 MB local bundle |
| Local code signature | `codesign --verify --deep --strict` succeeded |
| Real stdio protocol | `context-probe`: initialize and account/read succeeded; unauthenticated separate home |
| Schedule definitions | Probe found 12 current definitions; UI list and a paused job's details inspected |
| Native project selection | System directory picker opened the app's own repository; project and new chat screen visible |
| Persistence | SQLite close/reopen, stable project/thread IDs, rename overwrite and latest usage snapshot contract passed |
| Token accounting | Nullable usage, cache subset and reasoning-not-added-to-output contract passed |
| Protocol transport | Fragmented UTF-8/JSONL, numeric server approval ID, explicit decline and RPC errors passed |
| Recovery | Process crash rejects pending call; ambiguous turn timeout closes connection; new connection can start; no retry |
| Compaction | `contextCompaction` item appears as a transcript activity |
| Schedule parser | Multiline TOML, malformed file, unsupported schedule fallback; source unchanged by reading |

Seven Swift Testing tests passed via `zsh scripts/test.sh`. They validate the listed core contracts; they do not establish that all UI behavior or real server payload variants work.

## Initial resource snapshot

`vmmap -summary` after launching the release app, viewing jobs and opening a project, without login or an active model turn:

| Process | Physical footprint | Peak observed footprint |
|---|---:|---:|
| Context Desk UI | 43.3 MB | 69.9 MB |
| Child Codex App Server | 17.2 MB | 17.3 MB |

`ps` reported 0.0% CPU for both at this instant. This is **not** a 60-second average, battery test or active-chat budget verification. No Headroom process was running. RSS differs from physical footprint and is not used for the table above.

## Not yet verified

- OAuth completion in the UI, authenticated model catalog/rate limits and a real streaming model turn.
- Stop, restart/resume of a live conversation, notifications with a closed window, sleep/wake, expired authentication and network interruption.
- Large transcripts: rendering is lazy but `thread/read` currently loads the complete thread; paging remains required for long histories.
- MCP forms with non-string fields/enums and rich interactive payloads are intentionally not fully supported yet.
- Headroom routing, version-compatible SSE/WebSocket traffic, CCR recovery after restart/TTL, remote compaction, tokens saved and total resource overhead.
- Execution history or action notifications for jobs owned by the original Codex scheduler. This client reads definitions only.

## References

- [Official Codex App Server documentation](https://learn.chatgpt.com/docs/app-server).
- The installed binary's generated JSON schemas were inspected with `codex app-server generate-json-schema`; runtime and fixture behavior above are the direct evidence.
- [Headroom reviewed source](https://github.com/headroomlabs-ai/headroom/tree/3aa501285705949a123444a5c102d6bbc000afd9).
- [Headroom issue #3407](https://github.com/headroomlabs-ai/headroom/issues/3407) motivates testing provider identity and remote compaction; it is not evidence that this unimplemented routing path fails or succeeds.
