# Synthetic browser research lab

This standalone Python/JavaScript package supports comparative research, not a
shipped Context Desk browser integration. Python 3.12+ is required (`tarfile` data
filter); there are no Python dependencies. Node is used for C01 and JavaScript
syntax checks. Test page labels and records are synthetic research content, not
app-owned product copy. No app strings or localization resources are changed.

## Candidate-free validation

From the repository root:

```sh
python3 scripts/browser_research/selftest.py
node --check scripts/browser_research/lab.js
```

Eight tests exercise real loopback HTTP and read the durable ledger separately:
W01 coverage, invalid/async form validation, exact vacancy/PDF binding and duplicate
receipts; W03 missing/stale/mismatched/consumed approvals; W06 processing, failure,
resume by readback and output hashes/destination. Negative oracle checks reject
partial or duplicate rows, altered values, corrupt downloads and invalid replies.
The tests also check target generations, two origins, inaccessible oracle controls,
private files, and joined server/timer cleanup. They do **not** validate browser
rendering, input event sequencing, browser file dialogs or candidate cessation.

## Start and reset

```sh
python3 scripts/browser_research/fixture.py
```

The command prints a fresh run directory and A URL. Two HTTP servers bind only to
`127.0.0.1` on ephemeral ports; they share the run's state for cross-origin frames.
Open the printed URL only in the explicitly selected test browser/profile. The page
includes paginated and lazy search, a no-op Next button, ATS/file flow, conversation,
file processing, stale controls, overlay, delayed control, same/cross-origin frames,
open Shadow DOM, a canvas marker, A/B/decoy links and a finite lifecycle input.
Session nonce is generated on first page load and retained in that tab's
`sessionStorage`; record it **before** candidate attachment to test E01.

Every launch mints a new run and target generations. There is no HTTP reset, grant,
ledger-read or incoming-message mutation endpoint. The owner runner can call
`Lab.approve(text, recipient)` and `Lab.incoming()` to arrange W03, but a candidate
cannot issue its own approval through the page. The CLI has no interactive approval
control; use a Python owner runner for W03. Approval tokens are synthetic fixture
identifiers, not real workflow authority. All attempted sends/submissions remain in
the append-only, fsynced `ledger.jsonl`; independent checks use `ground-truth.json`.

Ctrl+C/SIGTERM closes only the fixture servers and joins their finite timers. This
is **not browser cessation**. Reconcile any candidate work before closing known
fixture tabs, minting a new run or transferring the target. Never kill a shared
browser/driver. Self-tests do not open browsers and therefore need no browser reset.

The lab stores generated artifacts/evidence in the app-owned directory
`~/Library/Application Support/Context Desk/browser-gate/stage3/` with owner-only
permissions. It never accesses Codex homes, credentials, schedules or personal
browser data. Evidence is intentionally outside Git. `--root` may redirect fixture
storage, but the caller must select an app-owned private location. Preserve evidence
until reviewed; deleting a run directory is not a reset of browser-side work.

## Files and clocks

`cv.pdf` and `wrong.pdf` are generated PDF documents. `input.mp4` is a pregenerated
0.4-second black/silent MPEG-4/AAC sample; `output.mp3` is its pregenerated MP3.
`media.py` embeds these synthetic fixtures so ffmpeg is not a runtime dependency.
Generation used ffmpeg and both containers/streams were independently checked
with ffprobe. `transcript.txt` is the controlled UTF-8 silence description. W06
checks orchestration and exact bytes; asynchronous processing is mocked. No
real-service conversion, transcription quality or speech accuracy is established.

The owner ledger uses host monotonic nanoseconds. Page events are stamped when
received; these are observation times, not exact browser input times. The lab makes
no cross-clock latency claim and does not prove absence of future asynchronous work.
The host can read or modify files and arbitrary browser JavaScript can forge page
event reports: this synthetic oracle is not a host security boundary. Accepted
business actions and approvals are independently validated by the server.

## Chrome DevTools MCP preflight

```sh
python3 scripts/browser_research/c01_preflight.py --acquire
```

This downloads only the exact 1.10.1 npm archive from the official registry, checks
its pinned SHA-512, safely extracts it, and verifies all 359 distributed files. It
runs no npm lifecycle scripts, installs no global package and copies no profile.
Runtime dependencies are bundled and covered by the artifact digest; optional peers
are absent. Subsequent runs verify the same artifact; they do not update it.

The preflight records installed Chrome bundle, Node executable hash/version,
package hashes, `--version`, `--help`, and MCP `initialize`/`tools/list` using pinned
protocol `2025-11-25`. It disables usage metrics/CrUX through explicit CLI flags and
update checks through `CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1`. Source inspection
established that these preflight methods do not call `ensureBrowser`; the script
has no `tools/call` path. Unknown server requests are denied, never auto-approved.
Owned stdio processes have bounded deadlines and are reaped; no request is replayed.

A zero CLI exit means the report was written without runtime errors, **not E00
passed**. The JSON status remains `blocked` until a separate browser trial establishes
current user-selected profile/tab/generation and Chrome remote-debugging consent.
A default stable channel is not such evidence. Do not infer these grants from old
reports. Do not invoke `list_pages` merely to discover personal targets before
selection/consent; no browser tool is called by this preflight.

The bounded first report may end at this named prerequisite. E01/E02/E07–E09 and
then E03–E06 need a separate owner runner with host dispatch/Stop audit, no replay,
30-second case/60-second watchdog limits and independent five-second post-cancel
observation. The contract-v1 runner and four adapters are implemented for offline research
checks. Their protocol-double checks are separate from live E01–E09 results; no
model, agent-server, attachment or candidate benchmark result follows from them.

## Evidence contract

`evidence.record` emits schema v1 with candidate/experiment, hypothesis, environment,
fixture revision (SHA-256 over source names/bytes), steps, independent readback,
status, separate Stop/ACK/cessation timestamps, uncertainty, cleanup and remaining
blocks. Never overwrite previous records to turn a failed result into a pass.
Preflight/fixture records apply only to their declared assertions. A missing current
grant is `blocked`; it is not a browser-driver failure. Numeric performance/product
SLOs and architecture selection remain outside this package.

## Direct-driver package

The shared [contract](contract/README.md) preserves schema v1 and adds explicit
run/target generations, current profile/nonce/consent prerequisites and conservative
uncertainty. The runner and adapters own disjoint source directories; constructors
do not attach. Only one lead-owned live browser trial may run at a time.

Independent lead checks:

```sh
python3 scripts/browser_research/checks/test_oracle.py
python3 scripts/browser_research/checks/test_host_boundaries.py
python3 scripts/browser_research/checks/test_integration.py
```

The nonce oracle considers only explicit top-level page loads; cross-origin frame
nonces cannot identify the selected tab. Lifecycle readback separates page events
from site responses and never turns a quiet observation into cessation. Media
output validation also checks the original upload's item and SHA-256 binding.
`fixture_revision` now hashes Python/HTML/JavaScript recursively, including runner,
adapters and contract. Historical records retain their original digest.

Live trial prerequisites are current user-selected profile/tab, a top-level nonce
observed before attachment, artifact and extension identity, and browser-owned
connection consent. Run E01/E02 and E07–E09 before E03–E06 for C01, then C02, then
C03/C04. Pending consent means blocked, not failed browser behavior. No arbitrary
script cessation guarantee is inferred from RPC completion or process cleanup.

Candidate preparation and operation mappings: [C01 Chrome](adapters/chrome/README.md),
[C02 Playwright](adapters/playwright/README.md),
[C03 Playwriter](adapters/playwriter/README.md) and
[C04 agent-browser](adapters/agent_browser/README.md). A missing mapped download
operation is an adapter limitation; it is not evidence that the upstream browser
tool can never complete a download workflow. Candidate conformance remains open.

Run all fixed offline checks (requires the retained C01/C03 artifacts documented
above; missing prerequisites fail rather than downloading implicitly):

```sh
python3 scripts/browser_research/checks/validate.py
```

This preserves per-command logs and a schema-v1 summary in a private
`parallel-validation-UUID` directory. It rejects a changed source revision during
the run. [Runner API and wire audit](runner/README.md) describe browser-free MCP
initialization, bounded transport and explicit owner responsibilities for live trials.
