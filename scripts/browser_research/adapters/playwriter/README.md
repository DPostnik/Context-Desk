# C03 Playwriter 0.7.0 extension comparator

`PlaywriterAdapter` implements direct-driver contract v1 through an injected
`rpc(method, params, request_id, deadline_ns)` that returns an MCP tool result,
and an optional one-way `notify(method, params)`. It does not start a relay,
open or close a browser, select a fallback tab, call `reset`, switch to direct
CDP, run a model, or replay an ambiguous action. Constructors make no RPC.

Run offline checks from the repository root:

```sh
PYTHONPATH=scripts/browser_research python3 scripts/browser_research/adapters/playwriter/test_adapter.py -v
```

The tests use protocol doubles, a minimal Node VM double for generated
`evaluate` code, and a private, removed
`browser-gate/stage3/playwriter-checks-*` directory. `preflight()` checks the
retained official npm archive SHA-512, its 498 distributed files and selected
extracted source files read-only. Stage 1–2 extracted only part of the archive;
this is source identity, not an installed runtime or transitive dependency lock.
The npm 0.7.0 dependency ranges include `@xmorse/playwright-core ^1.59.12`
and `@modelcontextprotocol/sdk ^1.30.0`; exact installed dependency versions
must be locked and checked before a browser trial. Historical extension
`0.0.148` is prior runtime evidence, not proof of today's installed extension.

`attach` remains `blocked` until the owner verifies current extension identity
and attachment approval, selected profile/tabs, explicit relay endpoint and
ownership, exact locked runtime, and these process settings:

- `PLAYWRITER_HOST` names the existing, owner-checked relay route. In 0.7.0
  this avoids `execute`'s local `ensureRelayServer` auto-start/recovery branch.
- `PLAYWRITER_AUTO_ENABLE=false` prevents the relay and executor from creating
  an initial tab when no manually enabled tab is available.
- `PLAYWRITER_DIRECT` is unset, retaining the extension route.

The booleans supplied to the constructor are **host assertions**. The adapter
cannot authenticate its injected process, observe current Chrome consent, or
prove the extension's tab restrictions. No old relay PID, selected tab or grant
is reusable. `Target.target_id` must be the explicit CDP target ID, while URL,
run, generation and nonce come from the selected fixture A/B/decoy page before
attachment. The adapter checks a single exact URL match in `context.pages()`,
then uses Playwriter's existing-session `getCDPSession({page})` helper and
`Target.getTargetInfo` to compare the CDP target ID. It reads the top page's
`window.CONFIG` and session nonce. It does not rely on Playwriter's default
`page` variable, which may be the first connected tab. Connected extension
tabs may still be visible in the same context; these checks are not a
driver-enforced isolation boundary.

Every action has a separate identity guard RPC and repeats that guard within
the action script. A Stop during the first guard withholds action dispatch.
The runner must atomically gate actual transport writes against Stop; the
adapter's synchronous callable cannot close that last handoff race. A Stop,
timeout or transport loss during the action leaves the target uncertain.
Playwriter 0.7.0 `execute` races async code against a timeout; the already
dispatched browser promise can continue. Historical Gate 0 tests observed a
finite delayed effect after a 250 ms timeout and after task-server death.
These failures are retained as historical counterexamples, not rerun by this
adapter. MCP cancellation notifications have no ACK or established browser
cessation; `cancel` therefore never reports a cancellation pass.

| Contract operation | Generated Playwriter `execute` code |
| --- | --- |
| `observe` | `locator('body').ariaSnapshot()` |
| `click` | `locator(selector).click()` |
| `fill` | `locator(selector).fill(value)` |
| `evaluate` | `page.evaluate(pageWrapper, {source, argument})`: the wrapper invokes the supplied function inside the page context; arbitrary JavaScript is not a safe executor |
| `wait` | `getByText(text).waitFor({state:'visible'})` |
| `upload` | `locator(selector).setInputFiles(filePaths)` for existing files in declared app-owned synthetic roots |
| `download` | `waitForEvent('download')` plus click, then `saveAs` to a new path in a declared app-owned private root |

The evaluate wrapper is passed as a function value, not a quoted function
expression. Playwright evaluates strings without invoking a returned function.
The Node VM regression check preserves that distinction and checks argument
serialization, asynchronous results and separation of host/page globals.

Generated code never calls `resetPlaywright`, `context.newPage`, navigation,
direct CDP discovery, or arbitrary MCP tool names. The caller supplies only
the listed arguments; all others are rejected. The result marker reports tool
completion, not independent fixture correctness. The runner must verify search
coverage, form receipt, upload file identity, downloaded hash/destination and
ledger effects separately. In particular, whether the pinned fork and current
extension support `saveAs` through this route remains a browser-runtime test.

`inspect_state()` returns JSON-serializable local state without browser RPC.
`detach()` only releases the local target and optionally calls a verified
caller-owned MCP transport cleanup callback. It never closes the shared relay,
extension tab or browser, and transport closure does not prove browser-work
cessation.

Source basis: integrity-verified `playwriter-package.tgz` and selected
`src/{mcp,executor,cdp-relay,cdp-session,utils}.ts` retained under app-owned
`research-2026-09-26-stage12`. Browser E00 current prerequisites and E01–E09
remain untested for this adapter.
