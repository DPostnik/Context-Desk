# Improvement log

This is the persistent record of product improvements, fixes, and deferred work. Initial import: 2026-09-25, from all 11 archived chats for this project in Context Desk (74 user messages and completion summaries). Local-only [source excerpts](archived-improvement-discussions.md), excluded from the published repository, preserve the original wording and JSONL line numbers.

Statuses describe evidence in the archived discussions, not a new code audit or runtime test:

- **Delivered (reported):** a completion summary reports implementation and an app rebuild.
- **Implemented (reported):** source changes were reported, but that discussion did not confirm an app rebuild. Later builds may include them; this import does not establish that.
- **Needs review:** an audit finding or proposed capability without a confirmed resolution in these discussions.
- **Deferred:** explicitly postponed by the user.

## Changes — 2026-09-25

| ID | Improvement and resulting behavior | Status | Evidence |
| --- | --- | --- | --- |
| IMP-001 | Move the model selector to the right, next to Send. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-174) |
| IMP-002 | Expand the composer to the window width. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-174) |
| IMP-003 | Show processing state inside the chat and immediate sending feedback. Queue behavior was subsequently refined in IMP-007. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-174) |
| IMP-004 | Add an explicitly selected Full Access mode saved per project folder. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-174) |
| IMP-005 | Display user messages on the right with a blue background and assistant messages on the left with a gray background. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-352) |
| IMP-006 | Make expanded tool activity rows more compact and gray. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-352) |
| IMP-007 | Queue follow-up messages above the composer; allow removal or Interrupt and Send. Add a queued message to the transcript only when sending. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-352) |
| IMP-008 | Integrate a managed local Headroom proxy, routing new chats through it and exposing status/counters in settings. Existing chats retain their direct route. | Delivered (reported) | [Summary and real-request check](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-665) |
| IMP-009 | Clear stale connection errors after successful reconnection or a server response. | Delivered (reported) | [Initial fix](archived-improvement-discussions.md#01a0d88f-8bd3-7b03-915a-53e6e819d675-line-157), [rebuild](archived-improvement-discussions.md#01a0d88f-8bd3-7b03-915a-53e6e819d675-line-346) |
| IMP-010 | Run independent chats concurrently; stop controls and queues apply to the selected chat. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d88f-8bd3-7b03-915a-53e6e819d675-line-346) |
| IMP-011 | Enlarge project click targets and open a new conversation when selecting a project. Refined by IMP-021. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d88f-8bd3-7b03-915a-53e6e819d675-line-346) |
| IMP-012 | Delete chats through a context menu with confirmation; delete their queues and require stopping active work first. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d88f-8bd3-7b03-915a-53e6e819d675-line-428) |
| IMP-013 | Archive and restore chats within each project; retain readable history and pause preserved queues. | Delivered (reported) | [Summary](archived-improvement-discussions.md#01a0d88f-8bd3-7b03-915a-53e6e819d675-line-511) |
| IMP-014 | Initially show five chats, with Show More adding five; search shows all matches. | Implemented (reported) | [Summary](archived-improvement-discussions.md#01a0d8b3-0034-77a0-ad2a-fe9e9af7b9c1-line-125) |
| IMP-015 | Animate project expansion/collapse, arrow rotation, and movement of neighboring projects. | Delivered (reported) | [Refined animation and rebuild](archived-improvement-discussions.md#01a0d8b3-0034-77a0-ad2a-fe9e9af7b9c1-line-391) |
| IMP-016 | Persist blue unread indicators for chats and projects; clear them and completion notifications when the transcript end is visible in the active window. | Implemented (reported) | [Summary](archived-improvement-discussions.md#01a0d8b3-0034-77a0-ad2a-fe9e9af7b9c1-line-293) |
| IMP-017 | Preserve separate new-chat drafts per project while switching projects, chats, or schedules. Persistence is limited to the running app session. | Delivered (reported) | [Scope](archived-improvement-discussions.md#01a0d8b3-7f9e-7ff3-a7fd-eff21b5d26b7-line-76), [rebuild](archived-improvement-discussions.md#01a0d8b3-7f9e-7ff3-a7fd-eff21b5d26b7-line-178) |
| IMP-018 | Restore white chat/composer backgrounds, a thin border, and a contrasting insertion cursor. | Implemented (reported) | [Summary](archived-improvement-discussions.md#01a0d8b6-5cf1-7410-a65c-cb870fca579c-line-59) |
| IMP-019 | Show a pulsing loading dot while opening a chat or awaiting a model response; respect reduced motion. | Implemented (reported) | [Summary](archived-improvement-discussions.md#01a0d8c3-d5ef-7ce2-88f1-e59fbbf99974-line-104) |
| IMP-020 | Constrain transcript/composer text to the visible width and reset horizontal scrolling to fix overflow and hidden input text. | Implemented (reported) | [Summary](archived-improvement-discussions.md#01a0d8c5-5f1d-70f3-8451-3b8c7a6375ad-line-247) |
| IMP-021 | Clicking an expanded project from its chat collapses its list, selects the project, and opens a new chat. Supersedes the earlier keep-current-chat behavior. | Delivered (reported) | [Behavior](archived-improvement-discussions.md#01a0d8cd-9855-7402-9714-563bcee6bcb0-line-65), [rebuild](archived-improvement-discussions.md#01a0d8cd-9855-7402-9714-563bcee6bcb0-line-174) |
| IMP-022 | Add a compatible app build workflow with signature validation and preservation of the previous bundle on failure; require a rebuild before reporting app changes ready. | Delivered (reported) | [Summary and test limitation](archived-improvement-discussions.md#01a0d8cd-9855-7402-9714-563bcee6bcb0-line-276) |
| IMP-023 | Show an app-wide startup loader until account checking completes, then display the workspace, sign-in, or a connection error with retry. | Implemented (reported) | [Summary](archived-improvement-discussions.md#01a0d8cf-ca34-7141-8755-ed2a811cf0e3-line-92) |
| IMP-024 | Add 16 pt trailing padding to sidebar running/unread indicators. | Implemented (reported) | [Summary](archived-improvement-discussions.md#01a0d8cf-ca34-7141-8755-ed2a811cf0e3-line-119) |

### IMP-017 follow-up — 2026-09-25

- Source: current user request to preserve composer text in existing chats as well as new chats until the app quits; `DeskModel.swift`, `DraftTests.swift`.
- Behavior: each existing chat keeps its own in-memory draft across chat/project/schedule navigation and repeated opening. New-chat drafts remain separate per project. Emptying or submitting the composer clears its stored draft; confirmed chat deletion removes it. Text typed while a new thread is being created follows that thread when it becomes selected. Drafts are not added to persisted state and a fresh model starts empty.
- Status: delivered in the local app build. `zsh scripts/build-app.sh` succeeded using SwiftPM and the compatible macOS 26.5 SDK; the signed `build/Context Desk.app` was replaced. The running session was not restarted.
- Validation: `zsh scripts/test.sh` passed all 57 tests, including navigation/isolation/clearing/session-lifetime and failed-send draft restoration coverage, existing queue/send checks, and Russian/English localization checks. Draft coverage preserves Russian and English text, emoji, newlines and spaces verbatim. No product copy changed. `git diff --check` passed. No live UI click-through validation performed.

### IMP-016 follow-up — 2026-09-25

- Source: current user request to clear app-wide notifications automatically after reading them in chat; `DeskModel.swift`, `DeskView.swift`, `UnreadResponseTests.swift`.
- Behavior: completion notices retain their existing transcript-end read acknowledgement. Action/input notices now link to their request and disappear from the shared in-app list and macOS Notification Center when the request is shown in the active chat, answered, resolved by the server, or its turn completes. Viewing a request never approves it or removes the pending action. Other chats and unread responses retain their notices.
- Status: delivered in the local app build. `zsh scripts/build-app.sh` succeeded on 2026-09-25 using the compatible macOS 26.5 SDK/direct compiler fallback; the signed `build/Context Desk.app` was replaced. Running sessions were not restarted.
- Validation: added a regression test for chat/loading/jobs guards, scoped notice removal, repeated acknowledgement, and preservation of pending approval. `zsh scripts/test.sh` could not run tests because the installed Swift Testing framework/macros are incompatible with the toolchain. No UI runtime validation performed.

Additional follow-up on 2026-09-25 after the user reported notices still remaining:

- The read callback previously required the entire transcript end and no running turn. It could not acknowledge a completed answer while a subsequent turn was running. Track the completed assistant item's ID per unread chat, recover it from the matching turn when loading history, and acknowledge once that answer's final content is visible or has been scrolled past. Trailing blank layout paragraphs no longer delay this acknowledgement. The existing shared-list/macOS cleanup and matching-completion guards remain in use.
- Added `completedAnswerCanBeReadWhileNextTurnIsRunning` coverage for a visible completed answer above a long running response, and for keeping a newer offscreen answer unread. `zsh scripts/build-app.sh` succeeded and replaced the signed local app bundle. `zsh scripts/test.sh` was attempted but tests did not run because the installed Swift Testing framework/macros are incompatible. No live UI reproduction or click-through validation was performed.

### IMP-025 — Clickable transcript links — 2026-09-25

- Source: current user request for Markdown link titles and opening links on the computer; `TranscriptLinks.swift`, `NativeTranscript.swift`, `TranscriptLinksTests.swift`.
- Behavior: standard `[title](destination)` links display a clickable title, including angle-bracket destinations containing spaces. Bare web addresses are detected. Explicit clicks open HTTP/HTTPS URLs, mail links, and local files with macOS default applications. Absolute source paths accept a trailing line/column reference and open the file (no editor-specific line navigation). Inline/fenced code and tool output remain literal; unsupported URL schemes and remote file hosts are not opened.
- Status: delivered in the local app build. `zsh scripts/build-app.sh` succeeded on 2026-09-25 using the compatible macOS 26.5 SDK/direct compiler fallback; the signed `build/Context Desk.app` was replaced. Running sessions were not restarted.
- Validation: added regression coverage for Markdown titles, local paths, encoded URL queries, code literals, bare URLs, and rejected schemes. `zsh scripts/test.sh` was attempted and stopped at the incompatible Swift Testing framework/macro probe; tests did not run. No UI click-through validation performed.

### IMP-026 — Build and verify before commit/push — 2026-09-25

- Source: current user correction of the requested development workflow.
- Behavior: `AGENTS.md` now records standing authorization and the required order: complete the change, build successfully, verify the result and relevant checks, commit task changes, then push. Failed or blocked required validation prevents commit/push. This supersedes the immediately preceding proposal to commit before building.
- Status: recorded in project instructions.
- Validation: reviewed the updated instructions and ordering. Documentation-only change; no app rebuild required. The latest app build succeeded, but the previously reported Swift Testing incompatibility remains unresolved; no commit or push was performed in this follow-up.

### IMP-027 — Standalone app repository and optional external integrations — 2026-09-25

- Source: user request to publish Context Desk itself; Headroom is an external optional provider, with other experiments to follow.
- Behavior: new installations default to Direct. Headroom starts only for explicit default selection or existing Headroom chats. Existing routes remain unchanged. The Swift adapter is isolated in `HeadroomIntegration`, and the external runner/requirements live in `integrations/headroom`. Neither Python nor the Headroom package is bundled or required for Direct mode. Added source/build/install/packaging documentation; release archives and private discussion exports are excluded from Git.
- Status: delivered locally and validated for source publication. Other providers are future work, not delivered by this change.
- Validation: initial builds and ZIP checks passed, but publication was held while Swift Testing was incompatible. After the IMP-022 toolchain repair, `zsh scripts/build-app.sh` succeeded with Swift 6.4, SDK 26.5 and SwiftPM; `zsh scripts/test.sh` passed all 43 tests, including Direct defaults, explicit Headroom selection and existing Headroom chats. Signature, source digest, ZIP integrity, shell/Python syntax and staged whitespace checks passed. No live authenticated model request or GUI session restart was performed.

### IMP-022 follow-up — Repair local Apple toolchain — 2026-09-25

- Source: user authorization to fix the incompatible development tools automatically.
- Behavior: installed the complete Apple Command Line Tools 27.0 update through `softwareupdate`, replacing the mixed Swift 6.3.3/6.4 installation. Swift 6.4 and SwiftPM now launch successfully. No app session was restarted and no unrelated OS update was installed.
- Status: delivered and verified.
- Validation: installer exited successfully; compiler and SwiftPM version checks passed. First build with SDK 27 failed because CLT lacks the SwiftUI macro plugin, leaving the previous app bundle intact. Strengthened the SDK probe to compile a SwiftUI `@State` view; it now rejects SDK 27 and selects installed SDK 26.5. The final `zsh scripts/build-app.sh` succeeded using SwiftPM, and `zsh scripts/test.sh` passed all 43 tests. This also validates the previously blocked notification, transcript link, persistence, token-accounting, routing and integration regressions. No system restart or app-session interruption was needed.

### IMP-028 — Independent provider plugins — 2026-09-25

- Source: user request to make Headroom an independent plugin for the next version.
- Behavior: introduced manifest/process protocol v1 and generic discovery, lifecycle, health, metrics and provider routing. Headroom-specific Swift targets and UI branches are removed. `plugins/headroom` owns its manifest, installer, runner, pinned dependencies and documentation. New providers require no app source changes or rebuild. Legacy and missing route IDs persist; missing or failed plugins do not fall back to Direct or approve/retry work. Plugin code/runtimes are not included in the app bundle. Settings discover independently installed plugins.
- Status: delivered in Context Desk 0.2.0; Headroom plugin 1.0.0 is packaged and installed separately. Protocol v1 covers Responses proxy providers, not arbitrary UI plugins.
- Validation: final `zsh scripts/build-app.sh` passed, and `zsh scripts/test.sh` passed all 44 tests. A first compile caught an optional-chaining typo, which was corrected before the successful build. Clean test-target recompilation exposed a missing Testing macro search path in SwiftPM; passing the installed plugin path explicitly fixed it. The Headroom plugin was packaged, extracted and installed from its independent archive; `context-probe --plugin headroom --plugin-check` passed startup/health/shutdown without connecting to Codex or making model requests. Tests cover multiple providers, independent process lifetimes, incompatible manifests/protocol/instance/version, removed providers, scoped overrides and legacy route persistence. Both archive integrity checks, app signature/source digest checks, version 0.2.0 and absence of Headroom/plugin manifests from the app bundle were verified. Shell/Python syntax checks passed; no live app session was restarted.

### IMP-030 — Project ordering and favorite chats — 2026-09-25

- Source: current user request to drag projects up/down and pin individual chats from different projects above all project folders; `Models.swift`, `DeskModel.swift`, `DeskView.swift`, `SidebarOrganizationTests.swift`, `scripts/build-app.sh`.
- Behavior: drag project headers onto another header to move to that position, with drop highlighting and Move up/Move down context-menu alternatives. Only the app's typed project payload is accepted; unknown IDs and self-drops do nothing. Pin/unpin chat context-menu actions populate a shared Favorites section above projects, including project names, unread/running indicators, search and existing chat actions. Chats remain available in their project; archived pins remain readable and deletion removes the pin with the chat. Project array order and optional chat pin flags persist in the app's dedicated SQLite state; legacy records decode without pins. New app labels have Russian and English copy.
- Status: delivered in the signed local app bundle; running sessions were not restarted.
- Validation: final `zsh scripts/build-app.sh` succeeded with SwiftPM/macOS SDK 26.5. An initial invocation completed bundle replacement but exited nonzero after a concurrent edit to the executing build script; the unchanged script was rerun successfully. Signature verification and the exported drag-type declaration passed. `zsh scripts/test.sh` passed all 46 tests after fixing new test assertions that initially failed macro compilation. New regression coverage exercises both reorder directions, invalid/self drops, legacy decoding, cross-project pins, unpinning, archived pins, deletion and reload through fresh SQLite store instances. Reviewed all new labels in both languages; `git diff --check` passed. Live mouse drag/drop and visual UI validation were not performed.

Follow-up on 2026-09-25 after the user confirmed pins work but project dragging does not:

- Replaced the project-header SwiftUI Button/Transferable drag path with an AppKit view that owns hit testing, mouse tracking, native drag sessions and drop destination callbacks. The SwiftUI label remains display-only. Movement of at least four points starts one drag; a drag never selects or collapses the project. Ordinary clicks, accessibility activation, RU/EN move menus and drop highlighting remain available. Drops require a matching project payload from a header in the same window; foreign/self/malformed drops are rejected. Neighbor menu actions capture project IDs instead of mutable array indices.
- Status: replacement implemented and rebuilt; pin behavior confirmed by the user. Full physical mouse dragging in the running app remains unverified.
- Validation: `zsh scripts/build-app.sh` passed with SwiftPM/macOS SDK 26.5 and replaced the signed bundle. Signature and source-digest checks passed. `zsh scripts/test.sh` passed all 52 tests after correcting actor isolation and an override declaration in the new test double. Three new AppKit tests cover hit testing over a hosted label, click versus drag threshold, single drag initiation, no activation after drag/outside release, accessibility press, local payload validation, drop routing and highlight cleanup. These use synthetic mouse events and a dragging-info test double; they do not exercise a physical WindowServer drag session. Existing order/pin persistence tests still pass. Existing Russian/English copy was preserved and reviewed; `git diff --check` passed. No running app session was interrupted.

Chat ordering follow-up on 2026-09-25:

- Source: current user request to drag chats relative to one another inside projects; `ChatRow.swift`, `ProjectHeader.swift`, `DeskView.swift`, `DeskModel.swift`, `Models.swift`, sidebar/native drag tests and bundle drag-type registration.
- Behavior: project chat rows now use the shared native AppKit mouse/drag handling, with target highlighting and RU/EN Move up/Move down menu actions. Only chats in the same project and same active/archive section can be reordered; project drags, foreign sources and rows undergoing archive/delete changes are rejected. Pin, rename, archive/restore, delete confirmation, click-to-open and running/unread indicators remain available. Optional per-chat ranks persist in SQLite; legacy lists keep recency ordering until first rearranged, then new replies no longer move existing chats. New chats appear first. Archive/restore clears the moved chat's rank so it enters the destination section above its saved order. Search, pagination and selected-chat reveal use the same ordering. Favorites retain their existing independent presentation.
- Status: implemented and delivered in the signed local bundle; no running session was restarted.
- Validation: `zsh scripts/build-app.sh` succeeded with SwiftPM/macOS SDK 26.5; signature and source-digest verification passed. `zsh scripts/test.sh` passed all 55 tests. Added coverage for both reorder directions, legacy decoding, cross-project/archive/self/missing rejection, reply-time stability, new chats, persisted order across fresh SQLite stores, deletion, and native chat drop routing/scope/disabled guards. Existing project mouse tracking and drop tests also passed. All introduced/reused menu copy has RU/EN pairs; `git diff --check` passed. Native drop callbacks were tested with a dragging-info test double; physical mouse dragging in the running app was not performed.

Compact chat row follow-up on 2026-09-25:

- Source: user report that chat rows became too large after drag support; request to restore the previous sizes.
- Behavior: removed the fixed 56-point chat row height in `DeskView.swift`. The original SwiftUI label now determines row height with the existing callout font, two-line title limit, 16-point horizontal padding and 8-point vertical padding. The native drag/click surface is overlaid within that measured size, preserving compact one-line rows and natural wrapping for longer titles. No product copy changed.
- Status: delivered in the rebuilt signed app bundle; running sessions were not restarted.
- Validation: `zsh scripts/build-app.sh` succeeded; signature and current-source digest verification passed. `zsh scripts/test.sh` passed all 55 tests, including native drag routing, mouse tracking and persisted ordering. `git diff --check` passed. Source review confirmed the previous label sizing values; no live visual check was performed.

Additional compact-row clarification on 2026-09-25:

- Source: user clarified that chat row height is still excessive and requested smaller padding (the preceding mention of width was corrected).
- Behavior: reduced the shared chat label's vertical padding from 8 to 4 points per side, reducing row height by 8 points for the same content. Applies to project, archive and favorite chat rows. Horizontal padding, text styles, wrapping and native drag behavior are unchanged. This supersedes the 8-point vertical padding described above; no product copy changed.
- Status/validation: delivered after successful `zsh scripts/build-app.sh`; signature, current-source digest and `git diff --check` verified. Reviewed the one-line layout-only change; no new tests were added and the previously passing 55-test suite was not rerun for padding alone. No live visual check or running-session restart was performed.

Compact project header follow-up on 2026-09-25:

- Source: user request to make project rows smaller and remove the folder-path subtitle beneath each name.
- Behavior: project headers are now 32 points high instead of 64, with 4-point vertical padding instead of 12. Removed the path subtitle and vertically centered the single-line name, folder icon, disclosure arrow and unread indicator. Full paths remain in the existing hover tooltip and search matching. No app-owned copy was introduced or changed.
- Status/validation: delivered after successful `zsh scripts/build-app.sh`; signature, current-source digest and `git diff --check` passed. Reviewed header dimensions and preservation of the tooltip, native drag and click callbacks. No new tests were added or suite rerun for this presentation-only change; no live visual check or running-session restart was performed.

### IMP-028 follow-up — Bilingual plugin UI and clearer setup — 2026-09-25

- Source: user report that English mode shows Russian plugin text and external connection controls are unclear; request to require both languages for every change.
- Behavior: all host-owned plugin labels/status/errors now use paired RU/EN copy. Protocol v1 adds optional bilingual descriptions, status and metric labels while retaining old plugin fallbacks. Headroom 1.0.1 provides both languages. Settings separate Codex account from optional Plugins, explain No plugin/Direct, show installation/connection state, and place Apply selection beside the picker; it cannot reconnect during active work. AGENTS.md now requires both languages in the same change. App version: 0.2.1.
- Status: delivered in app 0.2.1 and independent Headroom plugin 1.0.1.
- Validation: `zsh scripts/build-app.sh` passed; `zsh scripts/test.sh` passed 49 tests including RU/EN selection, paired plugin fields, legacy fallback and missing/idle/selected/connecting states. Headroom's standalone Python bilingual status/manifest test passed. An isolated real plugin process returned valid RU/EN health/metrics without model requests. Only the installed runner and manifest were atomically updated for the next launch with unchanged dependencies; before/after health checks confirmed the existing active instance/version was preserved. App and plugin archives, shell/Python syntax and staged whitespace checks passed. No live app session was restarted or interactive visual check performed.

## Outstanding findings and decisions

These are historical findings requiring revalidation against current code before implementation. They are not newly reproduced defects. All audit items below come from the [archived audit](archived-improvement-discussions.md#01a0d88f-8bd3-7b03-915a-53e6e819d675-line-64).

| ID | Follow-up | Status |
| --- | --- | --- |
| AUD-001 | Prevent queued-message loss between persistence and sending; preserve sending/unknown-delivery states without automatic retry. | Needs review |
| AUD-002 | Unify transport shutdown handling so oversized responses cannot leave stale running/connected state. | Needs review |
| AUD-003 | Invalidate pending approvals across reconnects and bind responses to connection generations. | Needs review |
| AUD-004 | Explain requested paths, network access, and turn-wide permission duration accurately. | Needs review |
| AUD-005 | Enforce a supported engine/protocol version or capability check at connection time. | Needs review |
| AUD-006 | Bound long-history memory/stream buffering and assess paginated loading and streaming performance. | Needs review |
| AUD-007 | Expose command output/exit codes, file diffs, and useful tool details in the activity history. | Needs review |
| AUD-008 | Cover queue crash windows, stale approvals, and transport limits through server-event tests; evaluate Headroom quality and savings on real workloads. | Needs review |
| IDEA-001 | Voice input: explicitly postponed pending validation of the use case. | Deferred — [decision](archived-improvement-discussions.md#01a0d86c-2d2d-7081-bef5-236fd61cb9ad-line-415) |

Other discussions are retained as context, not counted as shipped product improvements: [cross-chat history access](archived-improvement-discussions.md#01a0d8c9-bdef-7142-a678-784fa0d9b545-line-35), [read-only schedules](archived-improvement-discussions.md#01a0d8d4-e15a-70b0-bb09-8bd5ba86c664-line-33), and [repository setup](archived-improvement-discussions.md#01a0d8d4-e15a-70b0-bb09-8bd5ba86c664-line-90). No shared chat memory or independent scheduler was established by those discussions.

## Maintenance

For each future feature or fix, add or update one entry with a stable ID, date, concrete behavior, status, and source (chat/turn ID, relevant files, or requested issue/PR). Record validation and build results as they actually occurred. Merge repeated requests into the existing item; explicitly record superseded behavior. Keep requests, deferred ideas, and unresolved findings separate from delivered changes. Do not infer completion from archiving a chat.

This initial import changed documentation only; it did not rerun historical tests or rebuild the app. Future archive imports must remain scoped to this project and use the app's dedicated home without mutating conversation state.
