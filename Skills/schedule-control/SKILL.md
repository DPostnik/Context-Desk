---
name: schedule-control
description: Read, update instructions, enable or pause an existing Context Desk scheduled task at the user's request. Use the running app's scheduler; never edit its ledger or external schedules directly.
metadata:
  description-ru: Чтение, изменение инструкций, включение и пауза существующих заданий Context Desk через работающий планировщик.
  description-en: Read, edit instructions, enable and pause existing Context Desk tasks through the running scheduler.
---

# Schedule control

Use `scripts/schedule-control.py` with Python 3.9+ when the user requests a change to an existing Context Desk schedule. The app must be open with its scheduler ready. This channel does not create tasks, import them, run them immediately, delete them, or change project permissions/model/schedule. Use the app editor for those operations. Never modify `scheduled-jobs.json`, external schedules, credentials or the lock file.

- `python3 scripts/schedule-control.py list` returns current app-owned jobs.
- `python3 scripts/schedule-control.py update --job-id UUID --prompt-file /absolute/prompt.txt --enable --confirm-source-disabled` updates the selected task through its owning scheduler. Use only the flags needed by the user's request. `--pause` replaces `--enable` to pause.
- Confirm source-disabled only after checking the exact selected original is paused. The app independently checks Codex originals. Claude/unknown imports cannot be enabled through this channel; use the editor's confirmation flow.
- A prompt is user-authorized task content. Preserve submission/messaging limits and existing permissions. Do not infer a request to enable from a request to edit.
- Updates first obtain an app snapshot and reject concurrent edits or active runs. A routine-backed prompt must still match its frozen definition; use the app's routine editor when revising that definition.
- Each request prints its ID. On timeout use `python3 scripts/schedule-control.py status REQUEST_ID`; do not automatically resubmit an uncertain mutation. Claimed requests never replay after a crash. Unclaimed requests expire after 60 seconds. Inspect current task state before any explicitly authorized recovery.

Check the returned job's prompt, enabled flag, project, schedule/timezone and nextRun before claiming success. A configured task is not proof of a successful run. The scheduler operates while Context Desk is open and the Mac is awake.

## Standing browser session import

For explicit user authorization covering a selected task/site/source Chrome profile,
use `python3 scripts/browser-import.py --job-id UUID --chrome-profile Default --site linkedin.com`.
Use `--disable` without profile/site to revoke for future runs. Read the observed
job first. This stores permission metadata only; it never imports cookies immediately,
changes the prompt/schedule/model/project permissions, enables a task, or runs it.
Every new Codex run receives the site permission in its own browser environment
and conditional sign-in recovery instructions. Regular Chrome must be closed;
Keychain may need a user grant. Cookie readback is not website sign-in verification.
Never auto-close Chrome, retry an uncertain import, or expand the site's action scope.
An old running app rejects `browser-import`; ask for Cmd+Q/reopen of the verified
build before submitting again. Inspect an uncertain receipt with `status`, never replay.
