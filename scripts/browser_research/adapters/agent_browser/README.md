# C04 agent-browser 0.38.1 offline comparator

This contract-v1 adapter targets the native `agent-browser` 0.38.1 MCP facade,
CLI child and daemon path. The pinned release tag resolves to source commit
`aff6125c023b810ea3f2e5deec5379e9a4270bdc`. Source identity is distinct
from a downloaded or installed executable's identity.

From the repository root:

```sh
python3 scripts/browser_research/adapters/agent_browser/preflight.py --acquire
PYTHONPATH=scripts/browser_research python3 scripts/browser_research/adapters/agent_browser/test_adapter.py -v
```

Preflight checks npm 0.38.1 against its pinned SHA-512 and hashes each of its
distributed files. It checks the local-architecture native release asset against
GitHub's pinned release SHA-256 and size. Archives/assets stay as owner-only data
under `evidence.ROOT`; nothing is extracted, installed, chmodded executable or
launched. A schema-v1 blocked `E00.json` and full `environment.json` are written
under a fresh `agent-browser-checks-UUID` directory. Here Node v23.10.0 is below
the npm/source route's declared >=24 engine. A verified native asset is an artifact
check, not a runtime or installed binary check.

The runner injects `rpc(method, params, request_id, deadline_ns)`. Runtime
admission additionally requires an exact app-owned native executable hash, an
explicit loopback CDP endpoint, selected profile, current browser connection
approval, app-owned namespace/session and owner attestation that that session is
already bound with `--pin-tab` to the selected CDP target ID. This adapter does
not call `agent_browser_connect`: pinned source says enabling pinning without an
existing binding creates a blank tab. The owner must establish and audit the
binding before `attach`; no discovery, automatic fallback, profile copy, storage
state import/export or daemon shutdown is part of this package. The tool profile
must include `core`, `state` and `debug` for the mapped methods; the host must
restrict dispatch to the allowlist below despite those broader MCP profiles.

`attach` reads `agent_browser_session_info`, verifies active version/namespace/
session, then checks the tab list for the exact active CDP target ID and fixture
URL. It evaluates the top page's run, generation and pre-existing session nonce.
Every action repeats the tab/identity guard. The pinned tab behavior is source
evidence and owner attestation: MCP session info does not expose the pin flag.
Its `browserLaunched` field means `state.browser.is_some()` in pinned source;
it also covers CDP attachment and does not establish process ownership.
CDP has browser-wide visibility; the guard/action pair is not atomic, so E02 still
requires browser runtime and independent decoy evidence.

| Contract operation | Typed MCP tool / admitted native fields |
| --- | --- |
| observe | `agent_browser_snapshot`: `interactive`, `compact`, `depth`, `selector` |
| click | `agent_browser_click`: `selector` |
| fill | `agent_browser_fill`: `selector`, `text` |
| evaluate | `agent_browser_eval`: `script` (fixture research only) |
| wait | `agent_browser_wait_ms`: `ms` from 0 to 30,000 |
| upload | `agent_browser_upload`: `selector`, `files`; existing files under app-owned synthetic roots only |
| download | `agent_browser_download`: `selector`, `path`; new destination directly under an app-owned output directory only |

The owner must hash and validate downloaded bytes and destination independently.
The path check rejects an existing or dangling symlink, but native write follows
the check later; the runner must own the private output directory to close that race.
MCP/CLI success alone is not output proof. The adapter omits batch, navigation,
tab creation/switch/close, arbitrary CLI options, file/state helpers and chat.

Pinned `mcp.rs` handles stdin lines synchronously and ignores id-less
notifications, including MCP cancellation. Its per-tool CLI timeout can kill the
owned CLI child while the daemon remains busy with an accepted action. Thus
`cancel()` latches host Stop but sends no notification or claims ACK/cessation.
Timeout/loss/malformed results and late replies remain uncertain, with no replay.
`detach()` blocks while in flight/uncertain and never closes an attached browser
or shared daemon. Runner/owner cleanup may affect only verified owned children;
separate oracle observation and reconciliation are necessary before reuse.

The protocol doubles cover prerequisites, mapping, target/generation mismatch,
file boundaries, loss/malformed output, Stop during a guard, no cancellation
notification, late response and no replay. They do not establish E01/E02/E07–E09
browser runtime outcomes.
