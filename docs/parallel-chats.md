# Parallel chats and project selection — 2026-09-25

Chat execution state is keyed by thread ID. Each thread owns its sending lock,
active turn ID, queue pause state, deferred Stop and priority message. A draft
without a thread uses its selection generation until thread/start returns an ID.
Switching the selected chat does not transfer execution state or Stop targets.
Global logout, reconnect and quit checks still account for every running chat.
A shared transport disconnect pauses every queue; turns are never replayed.

Project buttons have a full-width rectangular hit region and larger padding.
Selecting a project's header leaves an existing chat and opens the new-chat
composer. Clicking again while composing preserves the draft. Queued messages
in another thread cannot divert the new message into that thread.

## Verification

The SwiftPM entry point currently fails to load BuildServerProtocol, and the
installed Swift Testing macros are incompatible with Testing.framework.
The app was compiled directly with swiftc using the existing SwiftPM build plan
and its explicit macOS SDK path. No system toolchain files were modified.

The queue and connection regression function bodies were also compiled into a
standalone local runner, with Swift Testing expectations replaced by checked
Boolean assertions. Eight invocations passed, covering:

- Existing queue ordering, priority interruption and restart persistence.
- Concurrent chats while a turn/start acknowledgment is delayed.
- Independent Stop targets and queue progression across projects.
- Creating a new conversation in the selected project while other chats run.
- Stop before start acknowledgment, followed by switching chats.
- Stale connection warnings clearing without hiding unrelated errors.
- Fragmented replies, explicit approvals and protocol errors.
- Both ambiguous turn/start and turn/steer timeouts, and process exit.

These checks use a local protocol simulator, no credentials or model requests.
They do not establish end-to-end behavior with concurrent authenticated turns.
