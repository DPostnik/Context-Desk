---
name: schedule-control
description: Inspect, import, edit, enable or pause Context Desk recurring tasks through the running scheduler. Transfer originals only through an available supported source-scheduler tool.
metadata:
  description-ru: Импорт, изменение, включение и пауза постоянных рутин через планировщик Context Desk.
  description-en: Import, edit, enable and pause ongoing routines through the Context Desk scheduler.
---

# Schedule control

Use `scripts/schedule-control.py` with Python 3.9+ and the running app. Never edit its ledger, external schedule files, credentials or locks. This channel does not run immediately, delete jobs, change existing schedules, or grant project permissions.

- `list`: current app jobs and their instructions.
- `catalog`: current readable Codex source definitions with content digests, app jobs and existing project IDs/paths. Unreadable/unknown definitions are excluded; absence is not proof of deletion or pause. This does not list cloud ChatGPT Tasks.
- `import --source-id ID --project-id UUID --time-zone Europe/Warsaw --model MODEL --effort EFFORT --recurring [--prompt-file FILE]`: creates one **disabled** copy. It reads a fresh catalog, compares the source digest on execution, preserves the exact RRULE, and rejects duplicate sources. Pinned source model/effort must match. For inherited settings, resolve explicit choices from authorized context; do not claim source-thread settings were imported. `--recurring` attests that this is ongoing work: one-time tasks and finite pilots are excluded, even if their syntax is repetitive. The scheduler additionally rejects COUNT/UNTIL and unsupported rules. No source session is resumed.
- `update --job-id UUID [--prompt-file FILE] [--enable | --pause] [--confirm-source-disabled] [--model MODEL --effort EFFORT]`: changes an existing job through its owner; project, engine, route, schedule and permissions remain unchanged. Model and reasoning change only when both explicit flags are supplied under user authorization; omitted values preserve the current pair. Model availability is verified by execution, not by a successful configuration write. Frozen routine definitions still require the routine editor.
- `status REQUEST_ID`: inspect the existing receipt without resubmitting. Each request prints its ID. Timeout or uncertain persistence is not authorization to retry, including imports with a new ID.

## Authorized recurring transfers

The user's standing authorization of 2026-09-27 permits selecting ongoing routines, disabling their originals and enabling checked copies without asking again for each transfer. Preserve scope, source coverage, time zone, permissions and pending evidence. This does not authorize sending messages or executing the routine during migration.

1. Inspect `catalog`, canonical workflow and current app jobs. Reject finite tasks and duplicates. Prepare the destination prompt, project and explicit inherited settings. Import disabled and verify the returned job before touching the original.
2. Discover an available **supported source tool**, such as `automation_update` in the source app. Read its actual schema. Read the exact source and check active-run state if supported. Use only its pause operation for the selected source; never substitute direct TOML edits, another scheduler, credentials from another app, guessed IPC or a model turn in the old thread. No source tool is bundled with this skill. If absent, report that concrete blocker and leave the copy disabled.
3. Confirm the pause through a fresh source-tool read and the matching source definition. If the original has an active run or its execution state is unknown, do not enable the copy until that uncertainty is resolved. An uncertain pause response must not be repeated automatically. Do not resume the original as automatic rollback.
4. Compare current instructions/schedule with the imported snapshot; resolve any drift before enabling. Use `update --enable --confirm-source-disabled` only after the exact original is confirmed paused. The app independently verifies the local Codex definition. This flag records observed confirmation; it does not require another user question within standing authorization. Claude/unknown imports remain outside this channel.
5. Verify prompt, source, project, enabled flag, schedule/timezone and nextRun in the completed response. A configured task is not proof of a successful run. Do not run a production task just to test migration.

Unclaimed requests expire after 60 seconds; claimed requests never replay after a crash. Updates reject concurrent edits and active runs. Keep checkpoints private. The app must remain open and the Mac awake. A newly built control capability requires Cmd+Q/reopen; never interrupt a running user session automatically. If an installed editable skill is older, use the matching bundled client until it can be updated without overwriting user edits.

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
