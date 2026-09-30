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
| `--version [--json]` | CLI, core, database schema, and JSON contract versions. |

Pagination (0003 §10): `--limit N` (1-200, default 50) and an opaque
`--cursor` from the previous page's `next_cursor` (`null` on the last page).

## Output

- `--json` writes exactly one JSON document to stdout: `schema_version` (the
  JSON contract version, currently `1`), `ok`, the command's fields, and
  `warnings`. No ANSI sequences; keys are sorted. Diagnostics, help, and
  ambiguity candidates go to stderr.
- Mutation JSON follows 0003 §11: `item` (with `display_id` and a nested
  `reminder`, or `null`), `changed`, `replayed`, `scheduling`
  (`null`/`pending`/`scheduled`/`unavailable`), `cancellation`. `delete` adds
  `undo: {command, item_id}`.
- `list`/`search` JSON: `items`, `total_count` (independent of page size),
  `next_cursor`.
- Errors: `{"ok": false, "error": {"code", "message", "detail"?}}`. `detail`
  is `ConflictDetail` (0003 §11, `shared/errors.rs`): `{total, candidates}`
  for an ambiguous ID/text selector, `{current}` for a stale
  `--if-revision`, or `{limit, active}` at reminder capacity.
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

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / committed |
| 2 | Invalid arguments or input (nothing committed) |
| 3 | Not found |
| 4 | Conflict / ambiguous: `AMBIGUOUS_ID`, `AMBIGUOUS_ITEM`, `REVISION_CONFLICT`, `REQUEST_ID_CONFLICT`, `ITEM_DELETED`, `ITEM_NOT_OPEN`, `NO_REMINDER`, `REMINDER_CAPACITY_REACHED` |
| 5 | Storage failure or lock timeout |
| 6 | Installation/platform failure for platform-only commands (e.g. `show` when the app cannot be found) |
| 7 | Incompatible schema |

A saved note or reminder whose app nudge failed still exits 0 and reports the
problem in `warnings`. Failure before commit is nonzero and mutates nothing.
