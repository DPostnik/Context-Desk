# Context Desk

A personal native macOS client for Codex. SwiftUI/AppKit, Foundation processes and SQLite; no Electron, browser engine or local web server.

The long-term direction is an agent-independent development workspace with separate agent and request-optimization integrations. See [Project vision](VISION.md) for the accepted direction, ownership boundaries and the distinction between current support and planned architecture.

Provider integrations are independently installed process plugins.

Personal documentation and research live in the local-only `docs/` directory, excluded from Git and fresh clones.

Context Desk is a standalone native macOS client for Codex. It connects directly by default. Headroom is an optional, separately installed external integration; Python and Headroom are not required to build or run the app in Direct mode.

The repository contains the Swift application, tests, assets, and build scripts. Build outputs and private application data are excluded from Git. Package the app with `zsh scripts/package-app.sh`.

## Run

Build with `zsh scripts/build-app.sh`, then open `build/Context Desk.app`. To install locally, quit the app and copy that bundle to `~/Applications/`. In the app, open a project folder and choose **Войти** to use the official ChatGPT login. Enable notifications in Settings if wanted. Projects opened here and their chats are independent of the existing Codex desktop history.

The bundled app is ad-hoc signed for this Mac, not notarized for distribution. It locates the existing official Codex binary in `/Applications/ChatGPT.app`, `/Applications/Codex.app`, `/opt/homebrew/bin` or `/usr/local/bin`. The binary is not bundled or redistributed.

## Optional external integration: Headroom

The standalone Headroom plugin is installed with `zsh plugins/headroom/install.sh` (requires `uv` and Python 3.12). Dependencies are pinned with hashes in `plugins/headroom/headroom.lock`. The generic plugin host starts/stops the separately installed proxy on a dynamically assigned loopback port. It does not run `headroom init` or edit global Codex settings.

New installations default to **Без плагина / No plugin**. Explicitly saved choices and existing chat routes are preserved. Install Headroom separately only if you want it, select it in Settings → Плагины / Plugins, and reconnect before creating a new Headroom chat; the current route appears below the composer. The same settings section shows proxy status and process-wide request/token counters.

## Current features

- Open local project folders; create, reopen, rename, archive, restore and delete chats; native streaming text with clickable Markdown links/monospaced code, model/reasoning choice and Stop. The transcript uses an AppKit text view and collapses long commands by default.
- Explicit command/file approvals, turn-scoped permission grants, user questions and basic MCP text forms. Unsupported client requests are rejected. Unknown MCP form schemas can be declined.
- Unread completed responses show a blue dot on their chat and project, retained across restarts. The dot clears when the completed answer’s final content is visible in the active window, even during a subsequent turn; opening a long unread chat starts at the top. Scrolling up suspends automatic following until the end is reached again. Reading a response clears completion notices without dismissing pending approvals.
- Action badges and macOS notifications; clicking a notification opens the associated chat. Closing the window leaves the app running; quitting stops its engine connection.
- Read-only viewer for `~/.codex/automations/*/automation.toml`. It does not start, modify or schedule jobs. The original Codex app continues to run them. A definition's status is not an execution result.
- Context estimate and cumulative input/cached/output counts: click the context label for details. Missing data stays unknown; cached tokens are a subset of input, not extra tokens. Context percentage is an estimate, not the exact compaction threshold.
- Account quotas: **Usage и лимиты** at the bottom of the sidebar shows remaining percentages per bucket/window, reset dates in the local time zone, last refresh time and manual refresh. Data comes from `account/rateLimits/read`, preferring `rateLimitsByLimitId` with legacy fallback; sparse update notifications trigger a full read. No polling or model requests. Failed refreshes visibly mark the retained snapshot as stale; logout/account changes clear it. Subscription quotas are separate from chat context.

Enter sends a message; Shift+Enter inserts a newline (Command+Return also sends). While a turn is active, messages stay in a persistent queue above the composer. Successful completion starts the next message as a separate turn. Each queued card can be removed or prioritized with “Прервать и отправить”; dispatch waits for the matching turn-completed event, not just the interrupt acknowledgment. Stop and failure pause that chat's queue until explicitly resumed. Disconnect and app restart pause all queues. Queued messages enter the transcript only when dispatched.

The native transcript draws outgoing tinted bubbles on the right and neutral assistant bubbles on the left. Expanded tool rows use compact spacing and secondary text color. Native text selection, bounded layout and streaming suffix updates remain in place.

Different chats can run concurrently, including chats in the same project. Each chat has its own active turn, queue, priority message and Stop action; only one turn runs at a time within a chat. Expanding a different project opens a new-chat composer, and its first message creates a separate conversation. Project rows reveal and conceal chat lists with a clipped, animated height and a soft spring; the sidebar uses a SwiftUI scroll stack so neighboring projects move continuously instead of native List row insertion/removal. Selecting the current project from a conversation collapses its chat list and opens the new-chat composer. Active and archived lists initially show five chats each, with “Показать ещё” revealing five more. Collapsing a project resets these limits; search shows all matches. Reduced Motion disables the sidebar animation. No automatic retry of model requests. A timed-out turn start or steering request closes the connection to avoid an accidental duplicate send. There is no automatic switch from a Headroom session to Direct.

Delete an idle chat from its context menu → **Удалить чат…** and confirm. The client calls `thread/delete` in its dedicated Codex home, then removes the chat, its queued messages and usage snapshot from app metadata. Active chats must be stopped first. Failed or unconfirmed deletion keeps the chat visible and pauses its queue; no automatic retry is made. Project files and other chats are unaffected.

Archive an idle chat from its context menu → **Архивировать**. Each project has an **Архив** disclosure containing its archived conversations. Their history remains readable; **Восстановить** returns a chat to the active list. Archive/restore use `thread/archive` and `thread/unarchive`, preserve usage and queued messages, and keep the queue paused until explicitly resumed. Older saved chats without an archive flag remain active.

## Data

App state lives in `~/Library/Application Support/Context Desk/`:

- `metadata.sqlite`: projects, thread IDs and latest usage snapshots.
- `codex/`: separate `CODEX_HOME`; the official engine owns login and transcripts.
- `probe-home/`: unauthenticated compatibility probe state.
- `plugins/<id>/`: separately installed provider plugins and their private runtime data.
- `headroom/`: legacy runtime, retained unchanged when upgrading.

The app does not copy credentials, change the existing `~/.codex/config.toml` or initialize Headroom globally. Credentials for this dedicated home use Codex's file backend inside its private directory. Codex diagnostics are drained without writing raw protocol/prompt logs. Headroom diagnostic logs stay under the app directory; full request/response logging and telemetry are disabled. Do not publish or sync this directory. To back up your state, quit the app and back up the whole directory privately.

## Development

Requirements: Apple Silicon Mac, macOS 14+, Swift 6 toolchain/Command Line Tools, official Codex CLI. Built with macOS 26.6.2, Swift 6.4 and the macOS 26.5 SDK. Intel and older supported OS versions have not been tested.

```sh
zsh scripts/test.sh
swift run context-probe
zsh scripts/build-app.sh
open 'build/Context Desk.app'
```

The build and test scripts select a compatible SDK and retain a fallback for older broken SwiftPM installations. After an app change, rebuild the bundle, quit the running app with Cmd+Q, and reopen it. Tests use a local Python protocol simulator; no model calls or account credentials. The probe initializes the real official engine in a separate home, reads account status and counts local schedule definitions; it sends no model turn.

TOMLDecoder is pinned to 0.4.5 with `Package.resolved`. SwiftUI/AppKit, SQLite and Foundation come from the OS. Updating the installed Codex binary can change its experimental protocol; rerun the probe and contracts before relying on a newer version.

The app version and build number are set in `scripts/build-app.sh` and written into the bundle's `Info.plist`.

## Next milestones

1. Verify authenticated chat, Stop, restart/resume and real approvals/notifications using a disposable local project.
2. Add large-transcript paging and test long streaming responses/resource usage.
3. Run representative Direct/Headroom comparisons for quality, cache effects, latency and token usage. The smoke test establishes routing, not workload-level savings.
4. Test remote compaction end to end before enabling broader compression profiles; CCR retrieval/expiry and cross-chat memory remain future work.
