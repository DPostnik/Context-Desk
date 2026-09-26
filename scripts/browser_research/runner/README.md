# Direct-driver runner, contract v1

This package runs one selected synthetic Lab target through a contract-v1 adapter.
It supplies a bounded JSON-RPC stdio transport, a host action gate, separate wire
admission audit, Stop/uncertainty latch, finite cleanup and schema-v1 evidence.
It never starts a browser by itself. The owner must establish current browser
profile, selected tab, pre-attachment nonce, artifact identity and connection
consent before constructing an adapter with those prerequisites.

The transport command must be an explicit, pinned executable and argument list.
`StdioRPC.start()` creates one owned child. Its `close()` sends EOF and, if needed,
terminates only that direct child; it never kills a process group, browser or
shared daemon. Unknown server requests receive JSON-RPC `-32601`; unknown server
notifications fail the transport. Replies arriving after a deadline are recorded
as late and cannot satisfy another ID. A blocked or partial write poisons the
transport because its wire outcome is uncertain. Maximum JSON line size is 4 MB.

Use `WireGate` for a real adapter so every `tools/call` write is admitted against
the active request ID, target generation and deadline. The adapter's internal
guard RPC may use `request_id + ':guard'` and attachment identity RPC may use
`request_id + ':attach'`. A Stop closes later write admission before the adapter
can send another action. A write admitted before Stop can still have delayed
browser effects. `host_audit` covers adapter invocations; `wire_audit` covers
actual stdio write admission and completion. Neither proves browser cessation.

```python
from contract import Target
from runner import DirectRunner, StdioRPC, WireGate

# command/env/target are established by the owner after E00 prerequisites.
with StdioRPC(command, env=env, stderr_path=private_root / 'driver.stderr') as transport:
    catalog = transport.initialize_mcp(expected_server_version=expected_version)
    # Checks protocol 2025-11-25, exact server version and tools/list.
    gate = WireGate(transport, target)
    adapter = CandidateAdapter(rpc=gate.rpc, notify=gate.notify, **candidate_prerequisites)
    runner = DirectRunner(adapter, target, wire_gate=gate)
    try:
        if runner.preflight().status == 'passed' and runner.attach().status == 'passed':
            result = runner.dispatch('observe', {})
            # Exact operation arguments are defined by the chosen adapter.
    finally:
        runner.close()
# The outer context reaps the owned transport even when initialization fails.
# Include transport.cleanup in the final private evidence.
```

`DirectRunner` freezes one `Target` (run, generation, exact loopback A/B/decoy
URL, nonce, profile and native target ID). Its methods are `preflight()`,
`attach()`, `dispatch(operation, arguments, target=...)`, `stop()`,
`observe_after_cancel(reader, observer=..., seconds=5)`, `reconcile(...)`,
`evidence(...)`, `write_evidence(path, ...)` and `close()`. The adapter owns
candidate-specific validation and tool argument mapping. The runner checks the
shared operation allowlist and rejects stale targets before adapter invocation.
The 30-second case and 60-second watchdog defaults come from the experiment
protocol. Shorter overrides are for explicit protocol-double checks only.

Stop is terminal for this runner. It latches uncertainty for active calls and
previously admitted effect-capable calls, even when the adapter returned success.
Cancellation notification has no invented ACK or cessation timestamp. After Stop,
`observe_after_cancel` takes two bounded independent readbacks at least five
seconds apart by default. A quiet fixture ledger is not sufficient to call
`reconcile`: explicit evidence from an independent executor observer, with
`executor_drained=True`, source and details, is required. A short observation
marked `protocol_double=True` cannot reconcile. The caller must determine whether
the claimed cessation condition actually follows from its observer; this runner
does not verify browser/process internals.

Offline self-check (no browser, native input, model or credentials):

```sh
PYTHONPATH=scripts/browser_research python3 -m runner.selfcheck
```

The command creates a private `runner-checks-UUID` directory below
`evidence.ROOT` and prints `summary.json`. It uses ephemeral Lab ports and an
owned Python stdio peer. Its results are protocol-double evidence, not C01/C02
browser runtime evidence. The lead-owned cross-package checks can be run with
`PYTHONPATH=scripts/browser_research python3 -m unittest discover -s scripts/browser_research/checks -v`.
