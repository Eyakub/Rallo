# CLI contract

`rallo` is the same interface for people and agents. This file documents what
is implemented. The canonical command set is section 5 of
`rallo-macos-build-plan.md`; the exact transitions, selectors, idempotency,
and output shapes are pinned down in
`docs/decisions/0003-core-command-semantics.md` ("0003" below), which this
file points to rather than duplicates.

Global options on every command: `--json`, `--data-dir DIR` (or
`RALLO_DATA_DIR`).

## Commands (M1)

Every mutating command accepts `--request-id KEY` (0003 §7); every ID-based
mutation also accepts `--if-revision N` (0003 §9).

| Command | Behaviour |
|---|---|
| `note TEXT` / `note --stdin` | Durably stores an open note. |
| `remind TEXT\|--stdin (--in DUR \| --at RFC3339)` | Durably stores an open note with an enabled reminder at the given deadline, atomically. Exactly one of `--in`/`--at` (clap rejects both or neither, exit 2). `--in`: `\d+d`?`\d+h`?`\d+m`?`\d+s`? in that order, at least one group, a day is 24h. `--at`: RFC 3339 with an explicit offset. Rejects zero/negative/overflowing/elapsed deadlines. Subject to the 32-active-reminder capacity (0003 §4). |
| `list [--all \| --deleted \| --due] [--limit N] [--cursor C]` | Default: open, nondeleted. `--all`: open+done, excludes deleted. `--deleted`: deleted items. `--due`: open items with an active reminder past its deadline. The three filters are mutually exclusive (clap rejects combinations, exit 2). |
| `get ID` | The item (full ID or unique prefix; 0003 §6), plus its `scheduling`/`cancellation` status. |
| `status` | App-running/data-dir/schema/pet-visibility overview (never starts the app). |
| `status ID` | Same shape as `get ID`: the item plus scheduling/cancellation detail. |
| `search TEXT [--exact] [--include-deleted] [--limit] [--cursor]` | Literal substring (or, with `--exact`, equality) over normalized text (0003 §6, §10); never regex/SQL. Default scope: nondeleted, open+done. `total_count` is independent of page size — an agent may claim a unique exact match only when it is `1`. |
| `edit ID --text TEXT` | Replaces the stored text. Identical text is a no-op (`changed: false`). |
| `done ID` | Marks the item done; disables an active reminder. Already-done is a no-op. |
| `reopen ID` | Marks the item open; never re-enables a reminder. Already-open is a no-op. |
| `restore ID` | Clears soft-deletion, keeping prior open/done status; never re-enables a reminder. Not-deleted is a no-op. |
| `reschedule ID (--in DUR \| --at RFC3339)` | Creates a reminder if the item has none, otherwise re-arms the existing one at a new deadline (new generation, acknowledgement cleared). Rejected on done/deleted items. Always changes state on success — never a no-op. Subject to capacity only if the reminder was not already active. |
| `snooze ID --in DUR` | `--in` only. Requires an existing reminder on an open, nondeleted item. Always changes state on success. |
| `acknowledge ID` | Disables an active reminder (`acknowledged`), clearing due-attention state. Already-inactive is a no-op. |
| `cancel-reminder ID` | Disables an active reminder (`cancelled`) without completing the item. Already-inactive is a no-op. |
| `delete ID` / `delete --text TEXT` | Soft-deletes, keeping open/done status; disables an active reminder. Exactly one selector (clap rejects both/neither, exit 2); `--if-revision` only with an ID selector (clap rejects it alongside `--text`, exit 2). `--text` matches the entire stored text after trim/NFC/case-fold (0003 §6, §8) among nondeleted items (open and done); zero matches is exit 3, more than one is exit 4 with candidates. Already-deleted (by ID) is an idempotent no-op. |
| `show [--reset-position]` | Persists "visible", then signals a running app or launches it (`open -g`, no activation). Intentionally launches/shows the app. |
| `hide` | Persists "hidden" and signals a running app. Never launches it. |
| `export --output PATH\|- [--format json\|csv] [--force]` | Writes a versioned export (0004): JSON is a lossless backup (items, reminders, timestamps, deleted state); CSV is spreadsheet-friendly but excludes deleted items and reminder detail beyond a resolved deadline/state. `--format` defaults from the `--output` extension (`.csv` → csv, otherwise json). `--output -` writes the export bytes directly to stdout (no envelope, `--json` ignored). Refuses to overwrite an existing file unless `--force`. Never starts the app: exporting only reads the store. |
| `import --file PATH\|- [--dry-run]` | Validates an entire export document (JSON or CSV, detected by content) before any write, classifies every record as new/identical/conflict, and applies it in one transaction behind a pre-import backup (0004). `--file -` reads from stdin. Any conflict aborts the whole import with nothing written, dry run or not. Imported reminders are always disabled and must be explicitly rescheduled. Never starts the app; a successful (non-dry-run) import signals one that is already running. |
| `setup terminal` | Links the CLI inside this running, installed app onto PATH as `rallo` (spec §10; same rules as the menu's "Enable Terminal Command…"): prefers `~/.local/bin`, falls back to `~/bin`; repairs a link left by a moved/reinstalled copy of the app; reports an already-correct link idempotently (`changed`-free success); never replaces a `rallo` that isn't a symlink to some installed `Rallo.app/Contents/Helpers/rallo`, on PATH or at the target directory. Refuses to run unless this executable is inside `/Applications` or `~/Applications`. Never touches a data directory, never starts or signals the app. |
| `doctor [--json]` | Read-only health report (M4, spec §8/§10): app install/embedding, terminal command, data directory permissions/schema/integrity/size, whether the app is running, last-observed notification authorization, active-reminder/unresolved-intent counts, and `backups/` contents. Never opens the store the normal way (no migration), never writes, never signals or launches the app. Exits `0` if every check is `ok`/`warning`, `1` if any is a `problem` (`DOCTOR_PROBLEMS`; see 0004/backup-and-restore.md for repair steps). |
| `backup [--output PATH] [--force] [--json]` | Writes a consistent snapshot of the database via SQLite's online backup API (`docs/backup-and-restore.md`): default `<data dir>/backups/manual-<now_ms>.sqlite3`, mode `0600`, atomic (temp file + `fsync` + rename). Refuses to overwrite an existing file without `--force` (`FILE_EXISTS`, exit 4, like `export`). Works while the app is running. Never starts or signals the app: like `export`, it only reads the store. |
| `update [--check] [--json]` | Distribution build only (`docs/distribution.md`): checks GitHub Releases for a newer version and, unless `--check`, downloads, verifies, and installs it. **The only Rallo command that uses the network, and only when run directly** — no background checks, no automatic updater. Refuses (`NOT_INSTALLED`, exit 2) unless this CLI is the one embedded in an installed `/Applications` or `~/Applications` copy. `--check` reports and stops. Otherwise: verifies the downloaded zip's SHA-256 against `SHA256SUMS`, the extracted bundle's identifier/version, its code signature, and that its embedded CLI runs and reports the same version — all before touching the installed app; backs up the data directory first, like `rallo backup` (skipped with no data yet); quits a running Rallo (`SIGTERM`, 5 s); swaps the app bundle atomically, restoring the previous one if the swap itself fails; and relaunches in the background exactly as other commands launch the app (pet visibility unchanged). |
| `--version [--json]` | CLI, core, database schema, and JSON contract versions. |

Pagination (0003 §10): `--limit N` (1-200, default 50) and an opaque
`--cursor` from the previous page's `next_cursor` (`null` on the last page).

## Output

- `--json` writes exactly one JSON document to stdout: `schema_version` (the
  JSON contract version, currently `1`), `ok`, the command's fields, and
  `warnings`. No ANSI sequences; keys are sorted. Diagnostics, help, and
  ambiguity candidates go to stderr.
- Mutation JSON follows 0003 §11: `item` (with `display_id` and a nested
  `reminder`, or `null`), `changed`, `replayed`, `scheduling`, `cancellation`.
  `delete` adds `undo: {command, item_id}`.
- `scheduling` (`null`/`pending`/`scheduled`/`delivered`/`unavailable`) and its
  `reason` come from the app's native notification evidence once M2 is
  draining (`awaiting_app`, `submitting`, `retrying`, `native_capacity`,
  `permission_denied`, `accepted`, `permission_not_requested`,
  `observed_in_notification_center`, or an abandonment code); the full table
  is `docs/decisions/0005-notification-protocol.md`. `cancellation` stays
  `null`/`pending` with reason `awaiting_app`/`retrying`.
- `list`/`search` JSON: `items`, `total_count` (independent of page size),
  `next_cursor`.
- Errors: `{"ok": false, "error": {"code", "message", "detail"?}}`. `detail`
  is `ConflictDetail` (0003 §11, `shared/errors.rs`): `{total, candidates}`
  for an ambiguous ID/text selector, `{current}` for a stale
  `--if-revision`, `{limit, active}` at reminder capacity, or
  `{total, conflicts}` (0004) for `IMPORT_CONFLICT` — a bounded list of
  `{id, line, index, reason}`, never note text.
- `export`/`import` JSON (0004): `export` success is
  `{"export": {"items", "path", "format"}}` (omitted when `--output -`, which
  writes the export bytes directly to stdout instead of the usual envelope).
  `import` success is `{"format", "total_records", "new", "identical",
  "conflicts": [], "warnings", "applied", "backup_path"}`; `conflicts` is
  always empty on success — a real conflict is the `IMPORT_CONFLICT` error
  above, not a partial success.
- `setup terminal` JSON: success is `{"terminal": {"status", "link", "target",
  "on_path", "path_export"}}`. `status` is `enabled` (fresh), `repaired`, or
  `already_enabled`; `link`/`target` are absolute paths (the PATH symlink and
  the CLI it points to); `path_export` is the literal
  `export PATH="$HOME/.local/bin:$PATH"` line when `on_path` is `false`,
  otherwise `null`. `NOT_INSTALLED` (this executable is not inside
  `/Applications` or `~/Applications`) and `TERMINAL_COMMAND_CONFLICT` (an
  existing `rallo`, on PATH or at the target directory, that is not Rallo's
  own link) are errors, not partial successes.
- `doctor` JSON: `{"ok", "checks": [{"id", "status", "summary", "fix"}, ...],
  "problem_count", "warning_count"}`. `ok` is `true` only when
  `problem_count` is `0` (independent of `warning_count`, which never affects
  the exit code). `status` is `"ok"`, `"warning"`, or `"problem"`; `fix` is
  `null` unless there is a concrete next step. The seven checks, always
  present and always in this order: `app_install`, `terminal_command`,
  `data_directory`, `app_running`, `notifications`, `reminders`, `backups`
  (`docs/backup-and-restore.md`). This is the one command whose top-level
  `ok`/exit code can be non-`true`/nonzero without `"ok": false` in the usual
  error-envelope sense — `doctor` always uses the success envelope, since it
  always successfully produces a report.
- `backup` JSON: success is `{"backup": {"path", "bytes"}}`. `FILE_EXISTS`
  (exit 4) mirrors `export`.
- `update` JSON: `--check`, and a non-`--check` run that finds nothing newer,
  both report `{"current", "latest", "update_available", "release_url"}`.
  Installing a newer release reports `{"current", "installed_version",
  "release_url", "backup_path", "previous_removed"}`; `backup_path` is `null`
  when there was no data directory yet to back up. A failed relaunch after an
  otherwise-successful install is a `warnings` entry, not a failure (exit 0),
  matching every other app nudge.
- Human output goes to stdout; diagnostics/warnings/candidates go to stderr.
  Stored text is shown with control characters and bidi overrides replaced by
  U+FFFD and line breaks flattened; JSON output is always lossless.
  - `note`: `Saved "text" (DISPLAYID)`.
  - `remind`/`reschedule`/`snooze`: `...; reminder at <local time with
    offset> — scheduling pending`. Never "Reminder set": native scheduling is
    not confirmed until the app applies it (M2). Local time is rendered with
    `libc::localtime_r` (the CLI is single-threaded; no timezone crate).
  - `delete`: `Deleted "text". Undo: rallo restore DISPLAYID`; if the item's
    reminder was disabled by a deletion, an added line notes that restoring
    will not re-enable it and that removing the scheduled alert is still
    pending.
  - Ambiguity (`AMBIGUOUS_ID`/`AMBIGUOUS_ITEM`): the error message, then one
    line per candidate (display ID, open/done, local creation time, reminder
    time if any, text preview), then `"N matches; showing M"` when the
    10-candidate cap truncated the list. Nothing is mutated.
  - Revision conflict: the current status/revision/text and "Nothing
    changed."
  - No-op (`changed: false`): stated plainly, e.g. `Already done: "text"
    (DISPLAYID)`.
  - `export`: `Exported N notes to PATH (json|csv).` (omitted for
    `--output -`, which writes only the raw export bytes).
  - `import`: `Would import N notes (M already here, skipped).` for
    `--dry-run`, `Imported N notes (M already here, skipped).` otherwise;
    both append `Imported reminders stay off until you reschedule them.`
    when `N > 0`, and a real import appends `Backup saved to PATH.`.
    `IMPORT_CONFLICT` lists each conflicting id/line on stderr, then `Nothing
    was imported.`; exit 4, nothing changed.
  - `setup terminal`: states what happened (added/repaired/already set up)
    and the full CLI path; when the link's directory isn't on PATH, adds the
    exact `export PATH=...` line to add to the shell's startup file.
  - `doctor`: one line per check, `[ok]`/`[warning]`/`[problem]` followed by
    its id and summary; a `fix`, when present, is an indented line beneath it.
  - `backup`: `Backup saved to PATH (N bytes).`
  - `update`: `Rallo X.Y.Z is up to date.` when there is nothing to do;
    `Updated Rallo X.Y.Z → A.B.C.` (with `Backup: PATH` appended when one was
    made) after installing.
- `SIGPIPE` has its default behaviour (`rallo list | head` ends quietly).

## Input rules

- Note text: non-empty after trimming, at most 64 KiB of UTF-8. Invalid UTF-8
  on stdin is rejected. Stdin is read only with `--stdin`.
- `--request-id`: 1-128 characters of `[A-Za-z0-9._:-]` (0003 §7). Reusing one
  with the same original inputs (not a recomputed deadline) replays the
  original committed result (`replayed: true`) against the current item
  snapshot; reusing one with different inputs is `REQUEST_ID_CONFLICT`.
- No interactive prompts in data commands.

## App nudges (never before commit, never blocking on app startup)

- `note`, `edit`, `done`, `reopen`, `delete`, `restore`: signal a running app;
  otherwise background-launch it only if the pet is currently visible.
- Any command that changes reminder scheduling/cancellation intent (`remind`,
  `reschedule`, `snooze`, `acknowledge`, `cancel-reminder`, and `done`/
  `delete`/`edit` when they left a pending schedule or cancel intent):
  signal a running app, otherwise background-launch it — regardless of pet
  visibility, since native work is now pending.
- A launch failure becomes a `warnings` entry; the exit code stays 0.
- Read commands (`list`, `get`, `search`, `status`) never start the app.
  `export` is a read command in this sense: it never signals or launches.
- `import` (non-dry-run): signals a running app (the same helper `hide`
  uses) but never launches one — imported reminders are always disabled, so
  there is no pending native work to hand off. `--dry-run` never signals.
- `setup terminal` never signals or launches the app: it only manages the
  PATH symlink, and does not touch a data directory at all.
- `doctor` and `backup` never signal or launch the app: `doctor` never opens
  the store the normal way at all (no migration under its read-only
  inspection), and `backup` only reads the store, like `export`.
- `update`, after a successful install, relaunches exactly as `show`/other
  nudges launch the app (background, no activation, current pet visibility
  preserved); a relaunch failure is a `warnings` entry, exit 0, same rule as
  every other launch failure above. `update --check`, and a run that finds
  nothing newer, never launch or signal anything.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / committed |
| 1 | `DOCTOR_PROBLEMS` — `rallo doctor` found at least one `problem`-level check (used by no other command) |
| 2 | Invalid arguments or input (nothing committed), including `INVALID_IMPORT`, `NOT_INSTALLED` |
| 3 | Not found |
| 4 | Conflict / ambiguous: `AMBIGUOUS_ID`, `AMBIGUOUS_ITEM`, `REVISION_CONFLICT`, `REQUEST_ID_CONFLICT`, `ITEM_DELETED`, `ITEM_NOT_OPEN`, `NO_REMINDER`, `REMINDER_CAPACITY_REACHED`, `IMPORT_CONFLICT`, `FILE_EXISTS`, `TERMINAL_COMMAND_CONFLICT` |
| 5 | Storage failure or lock timeout |
| 6 | Installation/platform failure for platform-only commands (e.g. `show` when the app cannot be found); `update`'s `UPDATE_CHECK_FAILED`, `UPDATE_DOWNLOAD_FAILED`, `UPDATE_VERIFICATION_FAILED`, `UPDATE_APP_BUSY`, `UPDATE_INSTALL_FAILED` |
| 7 | Incompatible schema, including an export document newer than this build supports |

See `docs/backup-and-restore.md` for the kinds of backups Rallo makes
(automatic pre-migration/pre-import snapshots, `rallo backup`, `rallo
export`) and exact restore steps.

A saved note or reminder whose app nudge failed still exits 0 and reports the
problem in `warnings`. Failure before commit is nonzero and mutates nothing.
