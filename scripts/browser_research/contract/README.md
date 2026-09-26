# Direct-driver contract v1

Import `contract` with `scripts/browser_research` on sys.path. Synchronous adapter
methods use an injected transport; the runner owns finite deadlines and audit.
No method retries. Constructors never attach. Transport implementation may reside
in runner; adapters accept a callable `rpc(method, params, request_id, deadline_ns)`
returning an MCP result dictionary (raising on transport/protocol failure).
Adapters must document extra constructor prerequisites and support this injection.

Result statuses are existing evidence.STATUSES. Unsupported is `not applicable`
with an explicit reason. Prerequisites missing is `blocked`. Timeout/loss after
dispatch is `failed`, uncertain true; never infer cessation from response/EOF/ACK.
Cancel sends only a notification through an optional injected
`notify(method, params)`; no notification ACK or cessation may be invented.

Target identity comprises all Target fields. Nonempty current profile, explicit
target ID and pre-attachment fixture nonce are required. Current browser consent
must be supplied separately as an explicit constructor prerequisite, default false.
Attach must compare observed run/generation/URL/nonce with expected target; do not
navigate to manufacture a match, discover unrelated content, or silently select a
fallback. Describe any browser-wide visibility. An adapter may block if its pinned
protocol cannot enforce the contract. Host checks are not driver enforcement proof.

Operations are `observe`, `click`, `fill`, `evaluate`, `wait`, `upload`, `download`;
arguments use candidate-native tool fields, with explicit documented mappings.
The adapter uses a fixed allowlist, validates target/deadline and rejects unexpected
operations before dispatch. `evaluate` is a research capability, not a safe executor.
No arbitrary forwarding, scheduled jobs, real applications/messages or personal files.

The runner freezes the admitted Target, serializes dispatch, records every accepted
and rejected request plus host monotonic timestamp, and latches Stop/uncertainty.
Late responses cannot clear the latch; rejected dispatch never reaches transport.
Independent oracle observation and an explicitly recorded reconciliation are needed
to release an uncertain target. No automatic reset/replay. Separate request IDs,
run IDs and target generations. Observe at least five seconds after cancellation;
elapsed observation alone is not cessation. Case deadline 30s; watchdog 60s.

Extend evidence schema v1 additively with `adapter_contract_version`, `host_audit`,
`adapter_state`, `artifact_identity`, and `run_generation` as needed. Preserve all
existing lifecycle timestamp names and statuses. Evidence level `protocol double`
cannot be labelled browser runtime. Store evidence privately under evidence.ROOT.
Cleanup closes only verified owned children/transports; never shared browser/daemon,
never browser_close as detach. Unknown server requests fail closed. Tests must cover
denial, stale target, timeout/loss, late reply, Stop and unsupported cancellation.
