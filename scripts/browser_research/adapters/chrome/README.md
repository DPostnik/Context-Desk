# C01 direct-driver adapter (Chrome DevTools MCP 1.10.1)

`ChromeAdapter` implements shared contract v1 through injected
`rpc(method, params, request_id, deadline_ns)` and optional
`notify(method, params)`. It never launches Chrome, attaches at construction,
opens another tab, selects a fallback, retries a request, or calls `browser_close`.
The transport returns the MCP **tool result** dictionary for `tools/call`, not
the enclosing JSON-RPC envelope. Pass `scripts/browser_research/` on `sys.path`.

Run the offline protocol doubles from the repository root:

```sh
python3 scripts/browser_research/adapters/chrome/test_adapter.py -v
```

The test creates and removes a private `browser-gate/stage3/chrome-checks-*`
directory. It reads the existing pinned npm archive/extraction at
`browser-gate/stage3/c01-1.10.1` and calls no browser/native/model service.
`preflight()` rechecks the archive SHA-512 and all 359 extracted files read-only.
Reuse `c01_preflight.py` for the separate Node/Chrome bundle and MCP stdio
preflight; do not interpret either check as current browser attachment.

Before `attach`, the owner must independently establish the current selected
Chrome profile, current debugging/connection consent, a pre-existing fixture
nonce, explicit numeric MCP page ID, and an exact loopback fixture URL for the
run. It must also prove that the injected transport is the pinned 1.10.1
process with page ID routing enabled and telemetry/CrUX/update controls set.
Set `runtime_binding_verified=True` only after that host-side check. The adapter
cannot authenticate its injected callable or establish consent from old reports.
`attach(Request(..., operation='attach'))` calls `evaluate_script` on the
explicit page ID and compares run, generation, A/B/decoy target, URL, live
nonce, and its sessionStorage value. This checks the top page's `window.CONFIG`;
it does not navigate or enumerate tabs. A transport using the selected page
instead of page ID routing would invalidate this check. The MCP connection may
still see browser-wide pages; page routing is not a driver-enforced isolation
grant.

Each operation requires the same frozen `Target` and an unexpired host monotonic
deadline. A fresh page-scoped identity read precedes native dispatch; Stop or
deadline expiry during that read withholds the action. The runner must serialize
and atomically gate transport writes against Stop. The identity read and the
native action are two distinct MCP calls, so the adapter alone cannot close a
user navigation or Stop race between them. Browser content is not a security
authority; the check applies to the controlled fixture only.

| Contract operation | C01 tool and accepted arguments |
| --- | --- |
| `observe` | `take_snapshot`: optional `verbose` |
| `click` | `click`: `uid`, optional `dblClick`, `includeSnapshot` |
| `fill` | `fill`: `uid`, `value`, optional `includeSnapshot` |
| `evaluate` | `evaluate_script`: `function`, optional UID `args`, `waitForStableDom` |
| `wait` | `wait_for`: nonempty `text` list, optional positive `timeout` capped to remaining deadline |
| `upload` | `upload_file`: `uid`, `filePaths`, optional `includeSnapshot`; absolute existing files under declared app-owned synthetic roots only |
| `download` | `not applicable`: pinned C01 has no dedicated download/save tool or destination control. A page click can trigger a browser download, but cannot certify the requested output path. |

The adapter adds `pageId` to every tool call and rejects caller-provided
`pageId`, `filePath`, `serviceWorkerId`, and other unexpected native fields.
`evaluate` remains arbitrary page JavaScript, intended only for admitted
synthetic research. No arbitrary tool forwarding is available.

`cancel(request_id)` latches local Stop during attach/identity guard or an
active action. If `notify` exists it sends MCP `notifications/cancelled` for the
actual in-flight RPC ID. This is only a one-way notification: C01 provides no
ACK or proven browser-work cessation. A cancelled action or transport loss
leaves `uncertain=True` and blocks later operations/detach until the runner's
independent reconciliation. Late action success never clears that latch.
`inspect_state()` reports local JSON-serializable state without browser RPC.
`detach()` drops the local binding and invokes only the caller-supplied verified
owned transport cleanup callback, if any. It never closes a shared browser or
claims that closing the transport proves cessation.

Source basis: the exact extracted 1.10.1 `ToolDefinition.js`, `ToolHandler.js`,
`McpContext.js`, `McpResponse.js`, `tools/{pages,input,script,snapshot}.js`,
and `config/mcp-options.js`. Runtime browser behavior, permission enforcement,
download destination, Stop/ACK/cessation and E01–E09 remain untested.
