# Headroom integration — 2026-09-25

Headroom is an independent provider plugin. The app has no Headroom-specific Swift dependency; it discovers the separately installed manifest through the generic host. All provider-specific code and installation live in [`plugins/headroom`](../plugins/headroom/README.md). See the [versioned plugin protocol](provider-plugins.md).

## Request path

Context Desk sends JSON-RPC to the official Codex app-server over stdio. For a Headroom conversation, Codex sends Responses requests to the app-owned loopback Headroom process. Headroom optimizes the request and forwards it to the ChatGPT Codex backend using the authentication headers supplied by Codex. The Swift client and runner do not read or copy auth.json.

Headroom does not run Codex and does not index an entire project merely because a folder is open. This integration optimizes context collected by Codex at the model-request boundary.

## Installed versions and ownership

- Codex compatibility target: `0.155.0-alpha.16.4` (existing official app binary).
- Headroom: `headroom-ai[proxy]==0.38.0`; reviewed upstream commit `3aa501285705949a123444a5c102d6bbc000afd9`.
- Python: 3.12; all 92 Python packages pinned with artifact hashes in `plugins/headroom/headroom.lock`.
- Installation: `zsh scripts/install-headroom.sh`, using uv. No service, launch agent, global provider setup, or second automation scheduler.
- Runtime location: `~/Library/Application Support/Context Desk/plugins/headroom/`.
- The app launches the proxy with a minimal environment. Config, caches, state and diagnostic logs are scoped to this directory. Full-message logs, telemetry, update checks, subscription polling and traffic learning are disabled.
- The process binds a kernel-assigned port on 127.0.0.1. The host validates the per-launch instance ID and plugin protocol/version before configuring Codex; the plugin validates its pinned Headroom version and chooses its fixed compression profile. The app terminates its child on shutdown; the child also watches its parent for unexpected exit.

Run `zsh scripts/install-headroom.sh` after changing the runner or the dependency lock. Installation does not touch `~/.codex` or existing Codex credentials.

## Initial compression profile

`cache-lossless` uses Headroom's cache-oriented mode with lossless structural compression, Kompress disabled, no image optimization, no response cache and no CCR retrieval markers/tool injection. This avoids persisting lossy compressed history whose originals can later expire from CCR. Memory and code-graph indexing are not enabled.

Headroom may remove formatting or compact schemas without reducing every request. Proxy-reported tokens removed are not a billing guarantee and are not the subscription usage percentage. Settings counters cover the current proxy process across all Headroom conversations, not the selected conversation alone.

## Routing and failures

New installations and older saved chats without a route use Direct. Explicit saved route preferences remain unchanged. Headroom starts only when selected as the default or needed by an existing Headroom chat. Each chat persists its route. Change the default in Settings → Внешние интеграции and create a new chat to use the new route. Thread start and resume explicitly pass the corresponding provider ID.

The app supplies `contextdesk_headroom` through process-local Codex overrides, with `name = "OpenAI"`, `wire_api = "responses"`, ChatGPT authentication and WebSockets enabled. The exact display name preserves the remote-compaction capability check documented in upstream issue #3407. Existing Direct chats continue to use `openai`.

Headroom retry handling is disabled; the custom Codex provider's request and stream retry limits are zero. A missing/stopped proxy never falls back to Direct. New Headroom sends are blocked and queued work pauses after a detected proxy failure. No turn is automatically replayed after an ambiguous transport failure.

## Historical verification (before independent plugin extraction)

Executed a real, ephemeral, read-only Codex turn using only this application's existing authentication:

```sh
swift run context-probe --plugin headroom \
  --home "$HOME/Library/Application Support/Context Desk/codex" --smoke-test
```

Observed: Headroom 0.38.0 ready; initialize/account read succeeded; authenticated=true; turn completed; proxy requests=2; proxy-reported tokens removed=354. The prompt asked for a fixed short reply without reading files or invoking tools. These measurements establish the request path, not representative compression savings or answer-quality equivalence.

Swift tests cover loopback-only provider configuration, preserved provider identity, route persistence/legacy migration, proxy lifecycle and instance validation, missing runtime, and existing queue/transport/persistence contracts.

Not yet established: remote compaction end to end, representative long-task token/cost/latency comparisons, sleep/wake behavior, lossy CCR restart/expiry recovery, or cross-chat memory. No claims are made for those features.

## References

- [Official Codex custom-provider configuration](https://learn.chatgpt.com/docs/config-file/config-advanced).
- [Headroom proxy documentation](https://docs.headroomlabs.ai/docs/proxy).
- [Reviewed Codex integration source](https://github.com/headroomlabs-ai/headroom/tree/3aa501285705949a123444a5c102d6bbc000afd9/headroom/providers/codex).
- [Remote-compaction provider-name issue #3407](https://github.com/headroomlabs-ai/headroom/issues/3407).

Current plugin extraction validation is recorded in `improvements.md`; the historical real-request measurements above were not repeated by this change.
