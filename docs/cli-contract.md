# CLI contract

`rallo` is the same interface for people and agents. This file documents what
is implemented. The exact transitions, selectors, idempotency,
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
| `setup skill [--print] [--agent claude\|codex]...` | Writes the agent skill embedded in this CLI (`skills/rallo/SKILL.md` of the same version) for every *detected* agent -- Claude Code/Cursor (`~/.claude` is a directory) and Codex (`$CODEX_HOME`, or `~/.codex` when that's unset/empty, is a directory) -- or, when neither is detected, Claude Code/Cursor alone. `--agent` (repeatable) installs only the named agents instead, creating their directories even when undetected. Claude Code/Cursor's copy goes to `~/.claude/skills/rallo/SKILL.md`; Codex's goes to `$CODEX_HOME/skills/rallo/SKILL.md` and Codex additionally gets `$CODEX_HOME/rules/rallo.rules`, a generated Codex execpolicy file that pre-approves Rallo's everyday note/reminder commands (never `update`/`setup`/`backup`/`import`/`export`/`doctor`) so Codex's sandbox doesn't block its notes store in `~/Library`. Every chosen target is inspected before anything is written: if any holds something that isn't Rallo's own (skill or rules), the whole command fails (`SKILL_CONFLICT`, exit 4, naming every such path) and nothing is written. Otherwise each target is installed/updated atomically (temp file + rename), reporting an identical file idempotently and replacing an older Rallo copy (skill: frontmatter `name: rallo`; rules: first line starting `# Rallo <version>: written by \`rallo setup skill\`...`). Warns when no `rallo` is on PATH. `--print` writes the skill to stdout instead, installs nothing, and ignores `--agent`. Works from any copy of the CLI; never touches a data directory, never starts or signals the app. |
| `doctor [--json]` | Read-only health report (M4, spec §8/§10): app install/embedding, terminal command, agent skill, agent hooks, data directory permissions/schema/integrity/size, whether the app is running, last-observed notification authorization, active-reminder/unresolved-intent counts, and `backups/` contents. Never opens the store the normal way (no migration), never writes, never signals or launches the app. Exits `0` if every check is `ok`/`warning`, `1` if any is a `problem` (`DOCTOR_PROBLEMS`; see 0004/backup-and-restore.md for repair steps). |
| `backup [--output PATH] [--force] [--json]` | Writes a consistent snapshot of the database via SQLite's online backup API (`docs/backup-and-restore.md`): default `<data dir>/backups/manual-<now_ms>.sqlite3`, mode `0600`, atomic (temp file + `fsync` + rename). Refuses to overwrite an existing file without `--force` (`FILE_EXISTS`, exit 4, like `export`). Works while the app is running. Never starts or signals the app: like `export`, it only reads the store. |
| `update [--check] [--json]` | Distribution build only (`docs/distribution.md`): checks GitHub Releases for a newer version and, unless `--check`, downloads, verifies, and installs it. **The only Rallo command that uses the network, and only when run directly** — no background checks, no automatic updater. Refuses (`NOT_INSTALLED`, exit 2) unless this CLI is the one embedded in an installed `/Applications` or `~/Applications` copy. `--check` reports and stops. Otherwise: verifies the downloaded zip's SHA-256 against `SHA256SUMS`, the extracted bundle's identifier/version, its code signature, and that its embedded CLI runs and reports the same version — all before touching the installed app; backs up the data directory first, like `rallo backup` (skipped with no data yet); quits a running Rallo (`SIGTERM`, 5 s); swaps the app bundle atomically, restoring the previous one if the swap itself fails; and relaunches in the background exactly as other commands launch the app (pet visibility unchanged). |
| `agent-event --agent claude\|codex` | 0007: reads one Claude Code/Codex hook payload (JSON, capped at 1 MiB) from stdin and records the mapped session state (`docs/decisions/0007-agent-attention.md`'s event table). Hidden from `--help`: `rallo setup hooks` installs it as the hook command; it is not meant to be typed by hand. **Always exits 0 and writes nothing to stdout** (a nonzero exit or stdout output could block or contaminate the calling agent); every problem (invalid JSON, a missing/too-long `session_id`, a busy or unavailable store) is one line on stderr instead. Only `hook_event_name`, `session_id`, `cwd`, `notification_type`, and `tool_name` are ever read; prompt/model text (`prompt`, `last_assistant_message`) is never read, stored, or logged. Walks process ancestry (no `ps`, no shelling out) to find the terminal/editor app to bring forward, only for a `waiting`/`working` write. On a change, posts the usual per-data-directory change signal; never launches or nudges the app. |
| `agents [--json]` | Lists fresh (≤24h) Claude Code/Codex sessions waiting on the user (0007, 0009): `waiting` only, most recent first (a finished turn removes its session). First prunes sessions whose agent process has gone, posting the change signal if it removed any; never launches the app. |
| `agents clear [--agent claude\|codex] [--session ID] [--json]` | Removes tracked sessions matching the given filters (default: every session, any freshness — not limited to what `agents` would currently show); reports the number removed. Posts the change signal when it removed at least one. |
| `setup hooks [--agent claude\|codex]... [--remove] [--print] [--json]` | Installs the `agent-event` hook command (0007) for every *detected* agent -- Claude Code/Cursor and Codex, using the same detection `setup skill` does -- or, when neither is detected, Claude Code alone; `--agent` (repeatable) targets only the named agents instead. Merges into Claude Code's `~/.claude/settings.json` `hooks` (created as `{}` if missing) and/or Codex's `$CODEX_HOME/hooks.json` `hooks` (created as `{"hooks":{}}` if missing): Claude gets `PermissionRequest`, `Notification`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SessionEnd`; Codex gets `PermissionRequest`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SessionEnd`, `Interrupt`. Each event gets one group with no `matcher` (so it fires for every tool): `{"hooks": [{"type": "command", "command": "\"<installed CLI path>\" agent-event --agent <claude\|codex> \|\| true", "timeout": 10}]}` (`\|\| true`: an older or missing CLI never fails a hook, since exit 2 would block `Stop`). The CLI path is this running, installed copy's embedded CLI (same resolution as `update`); refuses (`NOT_INSTALLED`, exit 2) from a copy that isn't installed in `/Applications` or `~/Applications` (skipped for `--remove`, which never needs that path). Rallo's own entries are recognised by shape (a command containing `/Rallo.app/Contents/Helpers/rallo` and ` agent-event --agent `), not by exact path, so a stale entry from a moved/reinstalled copy is still found and replaced. Re-running removes every Rallo entry it finds first, then (unless `--remove`) appends fresh ones, dropping an emptied group/event array/`hooks` key only if this pass itself emptied it; reports `already_installed` and writes nothing when that nets out to no change. `--remove` deletes only Rallo's entries and reports `removed`/`not_present`. Everything else in the file, including key order, is preserved exactly. Before a file's first write it is copied to `<file>.rallo-backup` (skipped if one already exists); writes are atomic (temp file + rename). A file that is not valid JSON (or not a JSON object) is refused (`HOOKS_CONFIG_INVALID`, exit 4, naming every such path) with nothing written to *any* target -- every target is checked before anything is written. `--print` shows the groups this would add per targeted agent and writes nothing. Never touches a data directory, never starts or signals the app. |
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
- `setup skill` JSON: success is `{"skill": {"installs": [{"agent", "status",
  "path", "rules"}, ...]}}`, one entry per targeted agent (in the order given
  by `--agent`, or detection order `claude` then `codex` by default). `agent`
  is `claude` or `codex`; `status` is `installed`, `updated`, or
  `already_installed`; `rules` is `null` for `claude` and `{"status", "path"}`
  (the same three statuses) for `codex`. With `--print`, `{"skill":
  {"content"}}` (ignores `--agent`). `SKILL_CONFLICT` (exit 4: at least one
  targeted path -- named in the message -- holds a skill or rules file that
  isn't Rallo's, left untouched; nothing is written for any target) is an
  error.
- `agent-event` never emits JSON (or anything else) to stdout, `--json` or
  not: every outcome, success or failure, is silent on stdout by design (0007).
- `agents` JSON: `{"sessions": [{"agent", "session_id", "state", "place",
  "detail", "app_path", "app_pid", "focus", "updated_at_ms"}, ...]}`, fresh
  (≤24h) `waiting` rows whose agent is still running, most recent first.
  `agent` is `"claude"`/`"codex"`; `state` is `"waiting"`; `place` is the
  last two folders of the agent's working directory (`"~"` for home);
  `focus` is `"cmux:<workspace>:<panel>"` or `"tty:/dev/ttysN"` (0009).
  `place`/`detail`/`app_path`/`app_pid`/`focus` are `null` when not known
  (e.g. no terminal ancestor was found, or an agent never reports a tool
  name for that event). Until 0009 rows carried `cwd` instead of `place`.
- `agents clear` JSON: `{"cleared": N}`. Posts the change signal when `N > 0`.
- `setup hooks` JSON: success is `{"hooks": {"targets": [{"agent", "status",
  "path", "backup_path"}, ...]}}`, one entry per targeted agent. `status` is
  `installed`, `updated`, `already_installed` (install mode), or `removed`,
  `not_present` (`--remove`); `backup_path` is `null` unless this call's write
  was this file's first modification and a `<file>.rallo-backup` was made (or
  no write happened at all, e.g. `already_installed`/`not_present`).
  `--print` reports `{"hooks": {"groups": [{"agent", "path", "events"}, ...]}}`
  instead, installing nothing. `HOOKS_CONFIG_INVALID` (exit 4, naming every
  unparsable file) and `NOT_INSTALLED` (exit 2, install/`--print` only) are
  errors, not partial successes -- nothing is written for any target either way.
- `doctor` JSON: `{"ok", "checks": [{"id", "status", "summary", "fix"}, ...],
  "problem_count", "warning_count"}`. `ok` is `true` only when
  `problem_count` is `0` (independent of `warning_count`, which never affects
  the exit code). `status` is `"ok"`, `"warning"`, or `"problem"`; `fix` is
  `null` unless there is a concrete next step. The nine checks, always
  present and always in this order: `app_install`, `terminal_command`,
  `agent_skill`, `agent_hooks`, `data_directory`, `app_running`,
  `notifications`, `reminders`, `backups` (`docs/backup-and-restore.md`).
  `agent_hooks` (0007) is `ok` "Not installed (optional)..." when no Rallo
  hook entry exists anywhere, `ok` "Installed for ..." when every one found
  points at this installed copy's CLI path, a `warning` with fix
  `rallo setup hooks` when at least one points elsewhere (a stale path, or
  this copy isn't installed at all), and `ok` (unchanged, noting the path)
  when a hooks file itself isn't valid JSON -- like `agent_skill`, `doctor`
  never writes, so an invalid file is only ever reported, never touched. This
  is the one command whose top-level `ok`/exit code can be non-`true`/nonzero
  without `"ok": false` in the usual error-envelope sense — `doctor` always
  uses the success envelope, since it always successfully produces a report.
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
  - `setup skill`: one line per targeted agent stating what happened
    (installed/updated/already installed) and the path -- Codex's line also
    notes `rallo.rules` -- then a line naming which agent(s) pick it up from
    there; `--print` prints only the skill's Markdown.
  - `doctor`: one line per check, `[ok]`/`[warning]`/`[problem]` followed by
    its id and summary; a `fix`, when present, is an indented line beneath it.
  - `backup`: `Backup saved to PATH (N bytes).`
  - `update`: `Rallo X.Y.Z is up to date.` when there is nothing to do;
    `Updated Rallo X.Y.Z → A.B.C.` (with `Backup: PATH` appended when one was
    made) after installing.
  - `agent-event`: nothing, ever, on stdout -- see above.
  - `agents`: one line per session, waiting first: `waiting  Claude Code ·
    Desktop/rallo — Waiting for permission: Bash · 2 min ago` (agent label,
    place, a detail phrase, and a relative age); `No agent sessions.` when
    empty.
  - `agents clear`: `Cleared N agent session(s).`
  - `setup hooks`: one line per targeted agent stating what happened (added/
    updated/already installed/removed/no hooks present) and the file path;
    Codex's line also notes that it will ask to trust the new hooks next time
    it starts. `--print` prints the groups it would add as JSON.
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
- `setup skill` never signals or launches the app, and does not touch a
  data directory.
- `doctor` and `backup` never signal or launch the app: `doctor` never opens
  the store the normal way at all (no migration under its read-only
  inspection), and `backup` only reads the store, like `export`.
- `update`, after a successful install, relaunches exactly as `show`/other
  nudges launch the app (background, no activation, current pet visibility
  preserved); a relaunch failure is a `warnings` entry, exit 0, same rule as
  every other launch failure above. `update --check`, and a run that finds
  nothing newer, never launch or signal anything.
- `agent-event` (0007): posts the change signal on a pet-visible change (a
  new/changed `waiting`/`done` row, or a deleted one); **never** launches or
  nudge-launches the app, even though it is technically a write -- an agent
  finishing a tool call must never be the reason Rallo's icon appears.
- `agents clear` posts the change signal when it removed at least one
  session; `agents` posts it only when its prune removed a session whose
  agent had gone (0009). Neither launches anything.
- `setup hooks` never signals or launches the app, and does not touch a
  data directory.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / committed |
| 1 | `DOCTOR_PROBLEMS` — `rallo doctor` found at least one `problem`-level check (used by no other command) |
| 2 | Invalid arguments or input (nothing committed), including `INVALID_IMPORT`, `NOT_INSTALLED` |
| 3 | Not found |
| 4 | Conflict / ambiguous: `AMBIGUOUS_ID`, `AMBIGUOUS_ITEM`, `REVISION_CONFLICT`, `REQUEST_ID_CONFLICT`, `ITEM_DELETED`, `ITEM_NOT_OPEN`, `NO_REMINDER`, `REMINDER_CAPACITY_REACHED`, `IMPORT_CONFLICT`, `FILE_EXISTS`, `TERMINAL_COMMAND_CONFLICT`, `SKILL_CONFLICT`, `HOOKS_CONFIG_INVALID` |
| 5 | Storage failure or lock timeout |
| 6 | Installation/platform failure for platform-only commands (e.g. `show` when the app cannot be found); `update`'s `UPDATE_CHECK_FAILED`, `UPDATE_DOWNLOAD_FAILED`, `UPDATE_VERIFICATION_FAILED`, `UPDATE_APP_BUSY`, `UPDATE_INSTALL_FAILED` |
| 7 | Incompatible schema, including an export document newer than this build supports |

See `docs/backup-and-restore.md` for the kinds of backups Rallo makes
(automatic pre-migration/pre-import snapshots, `rallo backup`, `rallo
export`) and exact restore steps.

A saved note or reminder whose app nudge failed still exits 0 and reports the
problem in `warnings`. Failure before commit is nonzero and mutates nothing.
