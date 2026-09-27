# Workflow optimization — 2026-09-27

Source: user requested concrete plans and implementation following the September 26
browser-wrapper measurements. Scope starts with vacancy sourcing. Other jobs require
separate measurements; this work does not establish which job consumes most tokens.

## Evidence and audit

The partial search returned 1540 IDs across 77 pages in 17.5 minutes. Snapshots were
72.3% of 12.12 MB returned data. Next-page operations took 682 seconds. Model tokens
were unavailable. The controlled wrapper comparison reduced response bytes by 96.2%
but did not demonstrate browser speed or memory improvement. See
the local browser-wrapper-agent-search-report.md and
browser-wrapper-live-search-report.md.

Read-only inspection of the scheduled sourcing instructions and canonical
`super-wiki/.agents/skills/job-board-sourcing/SKILL.md` confirmed mandatory coverage,
per-query evidence, and existing dedup against the vacancy bank, pipeline, company
records and earlier runs. The actual flow also includes independent downstream
stages. No scheduled prompts, query registry, private history, CRM or scheduler are
changed here. Archived observations are evidence, not executable instructions.

The adapter already extracted company/location but lacked date/excerpt selectors.
Pagination required a full snapshot UID. All lists used incremental scrolling,
including fully rendered static pages. These are the first implementation targets.

## Delivery sequence and acceptance

1. **Compact metadata and pagination — implementation in this change.** Add bounded
   date/excerpt selectors. A completed page can expose an opaque nextToken for a
   visible enabled same-origin ordinary anchor target. Store the full target in
   the private checkpoint; revalidate the URL and link before navigating once.
   Keep snapshot/UID click fallback for JS buttons. Preserve action-ID durability,
   owned-tab checks, uncertain-outcome stop, and changed-card postcondition.
2. **Opt-in static traversal — implementation in this change.** `expectedCards`
   is an explicit audited per-page count, never inferred from a site's total or
   the current DOM count. Require unique hydrated cards and stable reads. If the
   contract is not met, use the existing scrolling path. Last short pages use
   that fallback. Never apply this option to lazy/virtualized lists merely because
   their current count appears stable. No automatic site-wide enablement.
3. **Matched control — validation in this change.** Use a deterministic two-page
   fixture, generic/fast/fast/generic order, identical card metadata and long URLs.
   Compare all 40 card records, elapsed time, upstream calls and serialized
   boundary responses. Retain real lazy-loading/no-op/lifecycle fixture checks.
   Synthetic timings do not prove production token or job savings.
4. **Live EnglishJobs pilot — verified on two pages, 2026-09-27.** Inspect current selectors and compare
   generic/fast reads over the same bounded public pages. Compare ID membership,
   fields and completeness; retain timestamped private evidence. Disable the fast
   contract on drift. Do not silently drop required queries or change freshness
   rules. The historical 20-card count alone is insufficient for rollout.
5. **Earlier history matching — proposed workflow change.** Build one run-scoped
   lookup from the authorized history sources before JD qualification. Exact
   canonical URL/requisition matches can reuse an existing decision; company/title
   matches are review hints. New/ambiguous roles still get full qualification.
   Keep history changes detectable; never suppress a whole company, stop at the
   first known listing, or call an aggregator date canonical freshness.
6. **Adoption and end-to-end measurement — pending.** Provide the compact recipe to
   the sourcing workflow with its existing coverage and permission rules. Changing
   scheduled jobs is outside this repository's read-only scheduler contract.
   Measure actual available input/output/cached tokens separately from response
   bytes, useful verified leads, coverage gaps, browser time and total job time.
   Compare equivalent query sets; do not convert byte savings into token savings.
   Review other expensive workflows only after this baseline is understood.

## Compact call recipe

- `browser_cards(session, selectors, expectedCards?)`: selectors may include
  `company`, `location`, `date`, `excerpt`, `next`. Preserve full original URLs.
- Persist returned cards once as private evidence; use IDs and decision summaries
  during qualification rather than repeatedly quoting signed links or full pages.
- When complete and nextToken exists, call `browser_next` with session, actionID,
  expectedURL, selectors and nextToken (omit uid). This follows an ordinary anchor,
  not its JavaScript click behavior. Use snapshot/uid if that behavior is needed.
- A partial result is not exhaustion. A stale link, no-op or uncertain outcome is
  not permission to retry. Checkpoints never authorize automatic resume.

## Validation results

The signed app was built successfully on 2026-09-27 with SwiftPM and the compatible
macOS 26.5 SDK. Swift checks passed (79 tests); the subsequent Python suite passed
35 tests, including the concurrent background-routing regression. RU/EN tool
copy and README text reviewed. Package signature, source digest and ZIP passed.
Both real-Chrome fixtures passed against the built resources. The static fixture
returned identical full records for 40 cards in all four runs (mean 9.28 seconds
with scrolling/snapshot versus 3.71 seconds compact; 29 versus 14 upstream calls).
It also rejected changed, conflicting, disabled and unsafe next links, accepted
matching duplicate controls, and preserved 2200-character query strings.
The lazy-loading fixture passed two 12-card pages, no-op detection, at-most-once
fixture submission, three reconnects, zombie restart and missing-page invalidation.
The running app was not restarted; no live Settings UI click-through was performed.

The public EnglishJobs pilot completed generic/fast/fast/generic over pages 1–2:

| Metric, mean per two-page run | Generic + one transition snapshot | Compact static path |
| --- | ---: | ---: |
| Seconds | 18.45 | 3.92 |
| Serialized response bytes | 182680 | 97199.5 |
| Upstream calls | 53 | 14 |

All eight page reads returned complete, untruncated, with 20 cards each. IDs,
titles, companies, locations, dates and excerpts matched across all four runs.
Signed URLs were preserved but excluded from equality checks because they change
between visits. This bounded pilot establishes traversal improvement on these
pages, not full-site completeness, RAM savings, qualification quality or model
usage savings. Browser startup is excluded; only two runs per mode were measured.
Private raw results: `.runtime/workflow-optimization/live-verified/results.json`.

The first pilot stopped before its fast-page transition because two identical
Next controls were treated as ambiguous. It is excluded from the final table.
The implementation now accepts repeated controls only when their URL and text
agree; conflicting, disabled, hidden or unsafe links cannot issue a nextToken.
Direct HTTP inspection returned 403; the ordinary isolated Chrome path worked.

## Reproduction

After `zsh scripts/build-app.sh`, run the offline Python suite and the real Chrome
fixtures (`smoke.py`, `workflow_smoke.py`) with the built resource directory first
on Python's import path. The public two-page pilot is:

```sh
python3 -B BrowserRuntime/workflow_benchmark.py \
  --resources 'build/Context Desk.app/Contents/Resources/BrowserRuntime' \
  --output .runtime/workflow-optimization/new-run
```

The output directory must be new. It contains private full card evidence,
timestamps and resource hashes; never commit it. The pilot uses
`englishjobs-workflow.json`, stops after two pages per mode, and starts its own
throwaway browser profile. It never reads employer JDs, submits applications or
adopts the user's browser. The generic lane includes one snapshot for its single
page transition; both lanes extract the same metadata. It is a traversal
comparison, not a replay of the complete historical agent job.
