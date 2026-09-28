# Context Desk for iPhone — native preview

The 2026-09-27 decision is native SwiftUI first, backed by Supabase; evaluate it
for a week after the first working device installation. PWA is a possible later
replacement, not part of this implementation. A dedicated free Supabase project
was provisioned on 2026-09-27; public signup is disabled.

## Setup

1. Choose a Supabase project. Apply `supabase/migrations/202609270001_remote.sql` and then
   `supabase/migrations/202609280001_realtime.sql` and
   `supabase/migrations/202609280002_revision_continuity.sql` and
   `supabase/migrations/202609280003_photos.sql` once, in order, with its SQL editor. The migration uses Supabase Auth and PostgREST v1;
   it has no Supabase SDK dependency. Create a confirmed email/password Auth user.
   Disable public signup if the project is only for personal use.
2. In the Mac app, Settings → Mobile access, enter the project HTTPS URL,
   **public publishable or legacy anon key**, and the Auth user's credentials.
   Never use `service_role` or a secret key. Choose projects and explicitly enable
   access. Both devices use this same owner account.
3. Open `Mobile/ContextMobile.xcodeproj` in full Xcode. Select your development
   team in Signing & Capabilities and select the connected iPhone. Build and run.
   Enable Developer Mode on the phone if Xcode requests it. Signing/installation
   is separate from the unsigned simulator build script.
4. Sign in on the phone with the same project and Supabase Auth account.
5. Exercise the acceptance checks below before starting the week of observation.

Apple documents that a Personal Team provisioning profile expires after seven days:
https://developer.apple.com/help/account/basics/about-your-developer-account
No paid Apple membership, hosting plan or domain is assumed or purchased.
Supabase RLS reference: https://supabase.com/docs/guides/database/postgres/row-level-security

## Build and verification

```sh
zsh scripts/build-app.sh
zsh scripts/test.sh
python3 scripts/test-mobile-database.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer zsh scripts/build-mobile.sh
```

The PostgreSQL test creates and removes its own temporary cluster. Set
`CONTEXTDESK_POSTGRES_BIN` to a working PostgreSQL bin directory when needed.
It never accesses an existing database. The checked-in iOS project includes the UI-test target. The generator is only for
initial scaffolding and refuses to overwrite an existing project; there are no
third-party dependencies.
A macOS Swift typecheck of shared views is useful but is **not** an iOS build.

## Data and execution contract

- Remote access starts disabled after each Mac launch. Enabling it explicitly
  processes the retained cloud queue. Only selected project identities/names,
  recent chat names/text and approval details are published. Message text can
  contain file paths. Mac attachment bytes, tool output and engine credentials
  are not synchronized. Photos explicitly sent from the phone are retained in
  the owner-scoped command queue and saved on the receiving Mac.
- Supabase Realtime replaces periodic REST polling on both devices. One private
  owner channel carries compact database notifications and Presence over outbound
  WebSockets (Phoenix JSON 1.0.0). A database transaction commits data and its
  notification together. Commands still use durable REST insertion/atomic claims.
- Initial/reconnect synchronization reads the bounded snapshot after subscription
  and replication readiness. Subsequent publications and reads transfer changed
  chats with monotonic database revisions and an authoritative chat order (which
  also removes deleted chats). Unchanged snapshots produce no notification.
  Streaming changes are coalesced at 350 ms; phone invalidations at 40 ms.
- History remains bounded: up to 20 recent chats, 20 user/assistant messages per
  chat and 2,000 characters per message. Full history pagination is not implemented.
  Snapshot JSON above 1 MiB is rejected by the database. The v1 full snapshot stays
  readable for older installed clients until both devices have been updated.
- Snapshots and commands remain until the explicit Delete cloud copy and queue
  action, deletion of the Auth user, or an owner-managed database cleanup.
  Disabling access does not delete cloud data. Removing a project from selection
  takes effect after the next successful publication; the Mac still rejects its
  commands immediately based on its local selection.
- Supabase session tokens live in this app's Keychain service. The Mac's remote
  configuration and durable command journal live under the dedicated app home.
  Codex and Claude credentials/state remain on the Mac.
- A UUID identifies each command. SQL atomically claims it once; a durable local
  intent journal is written before agent dispatch. Claims never expire back to
  pending. Transport ambiguity never triggers an execution retry. A stuck claim
  or uncertain send blocks later sends for that chat; control commands can still
  be claimed. Operator reconciliation is currently manual.
- Stop carries the observed turn ID and cannot stop a newer turn. An accepted
  stop is shown as requested, not completed. Approval replies carry the exact
  pending request ID; unknown/stale requests fail closed. Truncated approval
  details cannot be approved from the phone.
- Project permissions, native provider identity and existing chat route are
  preserved. Remote sends refuse busy chats, pending interactions and existing
  desktop queues. They do not change the selected desktop chat or its draft.
- Both clients are authenticated as the same owner. RLS isolates owners and
  insert policy checks the selected device/project. This is a personal owner
  model, not separate worker/mobile roles or organization membership.
- On external power the Mac requests prevention of idle system sleep. Display
  sleep and locking remain allowed. Lid closure, forced sleep and shutdown are
  not covered. Power-source notifications update the assertion without polling.
  Sleep suspends the connection; wake reconnects while access remains enabled.
- The phone connects while foregrounded and cancels networking/retries in the
  background. Cached history and drafts remain available. Transient inactive
  scenes (e.g. Control Center) do not repeatedly recreate the socket.
- Heartbeats check transport/authentication only. Missing replies close the socket;
  reconnect uses exponential backoff with jitter (0.8–30 seconds). Network return
  wakes a pending retry. There is no periodic REST fallback. Invalid authorization
  or private-channel configuration stops automatic retries and reports recovery.
- Server connection and Mac Presence are distinct. Presence is advisory and does
  not authorize commands or prove execution. Last-update age describes data, not
  host liveness. Disconnecting the phone never stops work on the Mac.
- No push notifications or iOS background execution are implemented.

## Remaining work before declaring the original plan complete

The preview handles **existing chats**, sends, Stop and allow/deny approvals.
New-chat creation, structured question/form replies, full history pagination,
per-device revocation, automated retention and recovery UI are not implemented.
A submission with unknown delivery is retained on the phone and blocks additional
commands; this conservative behavior needs a verified reconciliation flow before
regular use. There is no automatic fallback to PWA or VPS execution.

## Acceptance checks on the actual Supabase project and iPhone

- Sign in both clients; verify another Auth owner cannot read or mutate their data.
- Send from the phone while another chat is selected on Mac; preserve its draft.
- Verify actual Codex and Claude project permissions and approval behavior.
- Test duplicate submission, stale approval and Stop for an older turn.
- Disconnect before/after insert, claim, local journaling and agent dispatch;
  restart both apps and confirm uncertain commands never rerun.
- Test offline Mac, disabled access, sleep/wake, battery transitions and Cmd+Q.
- Test Russian and English, long text, keyboard layout and accessibility on iPhone.
- Measure command/Stop latency, idle CPU, wakeups and Supabase traffic for the week.

Local status on 2026-09-27: Xcode 27.0 (27A266a), its first-launch components
and iOS 27.0 Simulator runtime are installed. Both simulator and unsigned iPhone
builds succeeded. The app was installed and launched in a dedicated simulator;
the Russian and English sign-in screens were visually checked. The macOS app
build succeeded with the full Xcode toolchain, followed by all 179 Swift tests.
The database migration/security checks passed in temporary PostgreSQL 17.11.

Physical-device follow-up: Developer Mode is enabled and a Personal Team signing
identity is available. The signed iPhone build succeeded, its signature passed
`codesign --verify --deep --strict`, and `devicectl` confirmed installation of
`com.contextdesk.mobile` on the paired iPhone. The embedded profile includes that
device and expires on 2026-10-04 at 20:05:25 UTC. First launch was initially denied by iOS
security. The user subsequently trusted the certificate. Physical launch, live Auth login
and one-time setup consumption are now verified. Supabase REST checks passed for
owner isolation, anonymous denial, selected projects, duplicates, single claiming,
immutable commands, no uncertain replay and cascade cleanup. The test used only
synthetic data; no agent task was dispatched. The Mac app still needs the user to
reopen it, select projects and enable access for an actual phone-to-agent check.

Installer handoff: a local `mobile-setup.json` with `url`, public `key`, `email`
and `password` can be placed in the dedicated Mac app home or the iPhone app's
Documents directory using development-device installation tools. Opening the Mac mobile-access settings (or launching the iPhone app) validates
and deletes it before using the values; successful login saves only session tokens
in Keychain. Never bundle or commit this file. Constructing the Mac model alone never consumes the handoff, so tests cannot
steal the installer file. The Mac still requires explicit project selection and enabling; the phone restores its own saved login on launch.
The latest Mac build succeeded (37.19 s), followed by 180 passing tests (18.495 s).
The signed iPhone build and installation also succeeded. Live phone-to-agent
execution remains unverified, so the observation week has not started.

## iPhone interface follow-up (2026-09-27)

The native chat list now supports search and message previews. The conversation
uses a scrollable transcript and bottom-pinned composer with per-chat session drafts.
The navigation-bar keyboard button and interactive scrolling dismiss the keyboard; successful
submission dismisses it automatically when the draft was not changed while sending.
A failed submission retains its text. The existing Mac artwork is packaged as the
iOS app icon. Connection age, approvals and the latest command state remain visible.
The simulator-only `-mobile-preview` and `-preview-chat` launch arguments use
synthetic content without cloud access for visual checks.

Mobile push notifications are requested but not delivered. Current Personal Team
signing has no APNs entitlement. Apple Developer Program signing, APNs registration
and a server sender must be configured before testing locked-device delivery.
Reference: https://developer.apple.com/help/account/reference/supported-capabilities-ios
There is no background polling workaround or misleading notification toggle.

Scroll regression verification: the bounded transcript uses eager layout and a
bottom default anchor; the jump button is governed by measured viewport position.
The `ContextMobileUITests` target verifies a long chat opens at its last message,
three scroll-away/jump-back cycles and keyboard dismissal. Run with:

```sh
xcodebuild -project Mobile/ContextMobile.xcodeproj -scheme ContextMobile \
  -destination 'platform=iOS Simulator,name=Context Desk Verification' \
  -derivedDataPath .build/mobile-ui-tests CODE_SIGNING_ALLOWED=NO test
```

## WebSocket delivery follow-up (2026-09-28)

The polling loops were removed from `MobileModel` and `MobileRemoteHost`.
`RemoteRealtime` owns subscription readiness, heartbeat, network changes,
reconnection and private Presence. `RemoteEventWork` serializes/coalesces event
work without a timer when clean. Authentication refresh is shared by REST and
WebSocket clients; uncertain refresh and command outcomes are never replayed.
The original database migration remains unchanged; the next migrations add
atomic compact signals, private-channel authorization and revisioned chat patches. A database sequence prevents revision reuse when a
cloud copy is deleted and recreated with the same Mac ID.
It was applied to the existing app-owned Supabase project and read back as v2.

The standalone live harness uses only app-owned setup credentials and synthetic
random device IDs; no agent task is dispatched. It does not print credentials or
save Auth sessions. Build/run explicitly (it accesses the configured live project):

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/ContextCore/Localization.swift Sources/ContextCore/MobileRemote.swift \
  Sources/ContextCore/MobileRealtime.swift scripts/verify-mobile-realtime.swift \
  -o .build/verify-mobile-realtime
.build/verify-mobile-realtime
```

Observed in the native live harness: snapshot notification 106 ms and command
notification 97 ms, measured from before the REST write through commit and receipt.
Over 26 seconds idle, two connections made zero REST data requests and exchanged
194 sent + 682 received WebSocket payload bytes. This excludes TLS/TCP overhead,
measures one short sample, and does not establish battery use or sustained p95
latency. Private-topic rejection, anonymous denial, changed-chat reads, no-op
suppression, disconnect/reconnect catch-up, deletion, Presence departure, heartbeat,
single command claiming and fixture cleanup passed. No actual engine ran.

The simulator UI suite passed in Russian and English, retaining the transcript
and composer while offline; existing scroll/keyboard regressions also passed.
Final build/test/install results are recorded in the local `docs/improvements.md`.

## Photos and keyboard overlap (2026-09-28)

The floating keyboard Done accessory was removed because it overlapped the composer
on iPhone. The navigation-bar keyboard button remains available while typing.
The photo picker accepts up to four images. It downsamples to a maximum 2048-pixel
edge and re-encodes JPEG without source metadata, capped at 512 KiB per photo.
Previews can be removed before submission; photo-only messages are supported.
Photo drafts are held per chat in memory and retained on submission failure.

Apply the additive photos migration and restart the updated Mac app before using
photos. A per-chat capability flag prevents selection against an older Mac snapshot.
Photos are sent atomically in the immutable owner-scoped command, not public URLs.
The existing command RLS, single-claim rules and uncertain-delivery receipt apply.
The Keychain receipt contains identity/text only; status queries omit photo bytes.
Cloud photo payloads remain until the device cloud copy is deleted. The receiving Mac
validates JPEG decoding, dimensions and size, writes generated filenames under its
own `mobile-photos/<command UUID>` directory, and supplies these paths in the agent's
prompt for image-tool processing. Local images are retained for conversation use;
existing project permissions still apply to agent file access. No engine credentials
or source photo filenames are transferred. This is file-based image-tool input,
not a native multimodal input block. Photo contents are not included in snapshots.
