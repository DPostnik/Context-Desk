# C02 Playwright MCP adapter (contract v1)

This is an offline direct-driver adapter for `@playwright/mcp` **0.0.82** and its
exact `playwright` / `playwright-core` **1.64.0-alpha-1789764292000** pair. The
Playwright source at `78ff4260d79b924724bdcc4ccd89e463b8f43b0d` describes
extension **0.4.0**; that is source evidence, not an installed-extension check.

From the repository root:

```sh
python3 scripts/browser_research/adapters/playwright/preflight.py --acquire
python3 -m unittest discover -s scripts/browser_research/adapters/playwright -p 'test_*.py' -v
```

Preflight downloads three exact npm tarballs into app-owned private `evidence.ROOT`,
checks pinned registry SHA-512, hashes all distributed regular files and confirms
package/dependency versions. It neither extracts/executes packages nor runs npm
scripts, installs a browser/extension, starts a service or attaches a profile.
`E00.json` is schema-v1 evidence and `environment.json` has the full file hashes.
Exit 0 means artifact checks completed; E00 remains **blocked** on actual extension
identity, explicit selected profile/fixture tab, pre-attachment nonce and current
extension connection approval. No approval-bypass token is used.

The runner injects `rpc(method, params, request_id, deadline_ns)` and optionally
`notify(method, params)`. It supplies `artifact_verified=True` only after reading a
successful artifact report, actual extension version/hash, selected profile and
connection approval. The adapter accepts `Target.target_id` as `index:N` in the
extension group's `browser_tabs` list. It lists/selects that index, reads the top
page's `window.CONFIG`, `location.href` and `window.fixtureSessionNonce`, and
compares run, generation, exact URL and nonce. Every action repeats a list/current
tab and identity readback. URL is restricted to an exact loopback fixture A/B/decoy
path. Tab indexes are **not stable browser tab IDs**, and the readback/action pair
is **not atomic**. E02 needs runtime group/second-client/decoy evidence; this host
guard does not prove driver-enforced isolation. `browser_tabs list` may create a
blank tab if the extension group has none, per pinned source, so the host must
already have a selected fixture tab before attachment.

| Contract operation | Pinned candidate tool and accepted fields |
| --- | --- |
| observe | `browser_snapshot`: `target`, `depth`, `boxes` |
| click | `browser_click`: `target`, `element`, `button`, `doubleClick`, `modifiers` |
| fill | `browser_fill_form`: `fields` |
| evaluate | `browser_evaluate`: `function`, `target`, `element` |
| wait | `browser_wait_for`: `time`, `text`, `textGone` |
| upload | `browser_file_upload`: `paths`, only existing files beneath supplied synthetic roots |
| download | `not applicable`: no direct pinned download tool mapped |

Evaluation is arbitrary page JavaScript and is admitted only as a research
capability on the synthetic fixture. The adapter deliberately does not expose
`browser_run_code_unsafe` (server-side code), navigation, tab creation/close or
arbitrary tool forwarding. Download links/output paths require independent
fixture/host validation; an MCP response alone cannot prove downloaded bytes.

Stop latches before transport cancellation. If a matching RPC is in flight,
`notifications/cancelled` uses its actual MCP request ID. The notification has no
ACK/cessation implication. The pinned server passes `extra.signal` to its backend,
but the inspected mouse/form/run-code handlers do not consume it. Late replies,
timeouts and transport exceptions preserve uncertainty; no call is replayed.
`detach()` releases adapter references only when no work is in flight or uncertain;
otherwise it returns blocked and retains the target. It never closes the shared
browser, extension group or daemon. The runner owns its verified transport child and must
audit dispatch, observe after Stop and reconcile an uncertain target separately.

The protocol-double tests cover denied prerequisites, native field mapping,
run/generation/nonce/target mismatch, stale current tab, unsupported calls,
transport ambiguity, Stop during an identity guard, notification ID and late
response. They are **not** browser runtime evidence for E01/E02/E07–E09.
