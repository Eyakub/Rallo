# 0003 — Core command semantics (M1)

- **Status:** Accepted for M1 implementation.
- **Date:** 2026-09-30
- **Implements:** sections 5–7 of `rallo-macos-build-plan.md`.

This pins down the transitions, selectors, idempotency, and error shapes that
the plan leaves to implementation. Native notification effects are M2; M1
only records reminder intent and `notification_intents` rows.

## 1. Schema v2 (migration `0002_reminders.sql`)

Added as a new migration (v1 databases from M0 exist and exercise the
backup-before-migrate path).

```sql
CREATE TABLE reminders (
    id                   TEXT PRIMARY KEY,
    item_id              TEXT NOT NULL UNIQUE REFERENCES items (id),
    deadline_ms          INTEGER NOT NULL,
    time_input           TEXT NOT NULL,       -- verbatim user input: "20m" or RFC 3339
    input_kind           TEXT NOT NULL CHECK (input_kind IN ('relative', 'absolute')),
    input_offset_seconds INTEGER,             -- UTC offset of an absolute input
    enabled              INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    disabled_reason      TEXT CHECK (disabled_reason IN
                           ('acknowledged', 'cancelled', 'item_completed', 'item_deleted', 'imported')),
    acknowledged_at_ms   INTEGER,
    generation           INTEGER NOT NULL CHECK (generation >= 1),
    created_at_ms        INTEGER NOT NULL,
    updated_at_ms        INTEGER NOT NULL,
    CHECK ((enabled = 1) = (disabled_reason IS NULL)),
    CHECK (enabled = 0 OR acknowledged_at_ms IS NULL)
) STRICT;
CREATE INDEX reminders_enabled_deadline ON reminders (deadline_ms) WHERE enabled = 1;

CREATE TABLE notification_intents (
    id                 INTEGER PRIMARY KEY,
    reminder_id        TEXT NOT NULL REFERENCES reminders (id),
    generation         INTEGER NOT NULL,
    kind               TEXT NOT NULL CHECK (kind IN ('schedule', 'cancel')),
    state              TEXT NOT NULL CHECK (state IN ('pending', 'attempting', 'applied', 'superseded')),
    created_at_ms      INTEGER NOT NULL,
    attempt_count      INTEGER NOT NULL DEFAULT 0,
    last_attempt_at_ms INTEGER,
    next_attempt_at_ms INTEGER,
    error_code         TEXT,
    resolved_at_ms     INTEGER,
    UNIQUE (reminder_id, generation, kind)
) STRICT;
CREATE INDEX notification_intents_unresolved ON notification_intents (reminder_id)
    WHERE state IN ('pending', 'attempting');

CREATE TABLE notification_observations (
    reminder_id              TEXT PRIMARY KEY REFERENCES reminders (id),
    generation               INTEGER NOT NULL,
    accepted_at_ms           INTEGER,
    pending_observed_at_ms   INTEGER,
    delivered_observed_at_ms INTEGER,
    observed_at_ms           INTEGER NOT NULL
) STRICT;

CREATE TABLE request_receipts (
    request_id    TEXT PRIMARY KEY,
    fingerprint   TEXT NOT NULL,     -- canonical JSON of the command's original inputs
    command_kind  TEXT NOT NULL,
    item_id       TEXT,
    result        TEXT NOT NULL CHECK (json_valid(result)),
    created_at_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
```

Receipts are retained indefinitely in the MVP (no silent pruning).

## 2. Reminder states

| Derived state | Row |
|---|---|
| active | `enabled = 1` (counts toward capacity; *due* when `deadline_ms <= now`) |
| acknowledged | `enabled = 0, disabled_reason = 'acknowledged', acknowledged_at_ms` set |
| cancelled | `disabled_reason = 'cancelled'` |
| completed | `disabled_reason = 'item_completed'` |
| deleted | `disabled_reason = 'item_deleted'` |

Invariants enforced in the same transaction as every mutation: at most one
reminder per item (UNIQUE); only open, nondeleted items have an enabled
reminder; `enabled = 1` implies no acknowledgement.

## 3. Transitions

`R` = the item's reminder. "Intent" = bump `R.generation`, mark this
reminder's `pending` intents `superseded`, insert a `pending` intent of the
given kind for the new generation. Every state change bumps `items.revision`
(the revision covers the item *and* its reminder) and `change_revision`.

| Operation | Precondition | Effect | Already in target state |
|---|---|---|---|
| `note` | — | new open item, revision 1 | — |
| `remind TEXT --in/--at` | capacity | new open item + enabled R (generation 1) + schedule intent, atomically | — |
| `edit ID --text` | not deleted | text + `match_key`; if R active, deadline future, and text previews enabled: schedule intent (payload refresh, same deadline) | identical text → no-op |
| `done ID` | not deleted | status done, `completed_at`; active R → disabled `item_completed` + cancel intent | done → no-op |
| `reopen ID` | not deleted | status open, `completed_at` cleared; R untouched (never re-enabled) | open → no-op |
| `delete ID` / `delete --text` | — | `deleted_at` set; active R → disabled `item_deleted` + cancel intent; status kept | deleted → no-op |
| `restore ID` | — | `deleted_at` cleared; prior open/done status kept; R untouched | not deleted → no-op |
| `reschedule ID --in/--at` | open, not deleted; capacity if R not active | creates or updates R: new deadline + input, enabled, ack cleared + schedule intent | — |
| `snooze ID --in` | open, not deleted, R exists; capacity if R not active | deadline = now + duration, enabled, ack cleared + schedule intent | — |
| `acknowledge ID` | R exists | active R → disabled `acknowledged`, `acknowledged_at` + cancel intent | not active → no-op |
| `cancel-reminder ID` | R exists | active R → disabled `cancelled` + cancel intent | not active → no-op |

Precondition failures: deleted item → `ITEM_DELETED` (exit 4); done item for
reschedule/snooze → `ITEM_NOT_OPEN` (exit 4); no reminder for
snooze/acknowledge/cancel-reminder → `NO_REMINDER` (exit 4). No-ops return
success with `changed: false` and do not bump any revision.

## 4. Capacity

`MAX_ACTIVE_REMINDERS = 32`. Inside the write transaction, before enabling a
reminder that is not already active, count `enabled = 1` rows; at 32 fail with
`REMINDER_CAPACITY_REACHED` (exit 4, detail `{limit, active}`). `BEGIN
IMMEDIATE` serializes writers, so concurrent creates cannot exceed the limit.
Snoozing/rescheduling an already-active reminder does not consume a slot.

## 5. Time input

- `--in`: `^(\d+d)?(\d+h)?(\d+m)?(\d+s)?$`, at least one group, units in that
  order, each at most once, lowercase. A day is 24 h. Zero total, overflow,
  or a deadline beyond 9999-12-31T23:59:59Z → `INVALID_TIME` (exit 2). The
  deadline is computed once from the injected clock at first commit.
- `--at`: RFC 3339 with an explicit offset (`Z` or `±hh:mm`). Unzoned input or
  a deadline `<= now` → `INVALID_TIME`. The offset is stored.
- Deadlines are integer UTC milliseconds. JSON exposes `deadline_ms` and
  `deadline` (RFC 3339, UTC).

## 6. Selectors and IDs

- **Full ID:** a UUID (any case, hyphenated) → exact lookup.
- **Prefix:** otherwise Crockford Base32 (case-insensitive, `I/L→1`, `O→0`),
  at least 6 characters, matched against `items.short_key` with an indexed
  range query. Invalid syntax or shorter than 6 → `INVALID_ID` (exit 2). No
  match → `ITEM_NOT_FOUND` (exit 3). More than one → `AMBIGUOUS_ID` (exit 4)
  with up to 10 candidates. Resolution includes deleted items (needed by
  `get`/`restore`); commands then apply the preconditions above.
- **Display ID:** the shortest unique prefix among all items, at least 6
  characters (computed from the neighbouring `short_key`s). A new item can
  lengthen another item's display ID; a previously shown shorter prefix then
  fails as ambiguous with candidates. Agents must use full IDs.
- **Exact text (`delete --text`, `search --exact`):** `match_key` equality
  (trim → NFC → case fold → NFC). Scope: nondeleted items, open and done.
  Wildcards, regex, shell syntax, and ID-shaped text are just text.

## 7. Idempotency (`--request-id`)

Accepted by every mutating command. Syntax: 1–128 characters of
`[A-Za-z0-9._:-]`, else `INVALID_INPUT`.

Inside the mutation's write transaction, **before** resolving any selector or
checking any revision:

1. Look up the receipt. If present with an identical fingerprint, return the
   stored result with `replayed: true`, combined with the *current* item
   snapshot and current scheduling status (never stale warnings).
2. If present with a different fingerprint → `REQUEST_ID_CONFLICT` (exit 4).
3. Otherwise run the command. On success, insert the receipt in the same
   transaction. Failures commit nothing and store no receipt.

The fingerprint is canonical JSON of the command kind and its *original*
inputs (e.g. `{"in":"20m"}`, not the computed deadline; the raw `--text`, not
its match key; the given selector and `if_revision`). No-ops also store a
receipt.

## 8. Delete by text

One `BEGIN IMMEDIATE` transaction: receipt check → count and fetch
candidates by `match_key` → exactly one: soft-delete it with the ID-delete
effects → receipt → commit. Zero → `ITEM_NOT_FOUND` (exit 3). More than one →
`AMBIGUOUS_ITEM` (exit 4) with `total` and up to 10 candidates (full ID,
display ID, revision, text, status, created time, reminder deadline). Nothing
is mutated on either error. A replayed request returns the original deleted
item even though it no longer matches, and never deletes a newer same-text
item.

## 9. Revision guards (`--if-revision N`)

Accepted by every ID-based mutation. Order: receipt → resolve → if already in
the target state, succeed as a no-op → if `revision != N`, fail with
`REVISION_CONFLICT` (exit 4) carrying the current snapshot → mutate. Callers
must not silently retry with the new revision.

## 10. Listing and search

- `list`: open nondeleted (default), `--all` (open + done), `--deleted`,
  `--due` (open with an active reminder whose deadline `<= now`). Filters are
  mutually exclusive. Ordering: newest `created_at` first (`--deleted`: newest
  `deleted_at` first; `--due`: earliest deadline first), ties by ID.
- `search TEXT [--exact] [--include-deleted]`: literal substring on
  `match_key` (`instr`, no LIKE/regex); `--exact` uses equality. Default scope
  nondeleted open + done.
- Pagination: `--limit N` (1–200, default 50) and an opaque `--cursor` from
  the previous page's `next_cursor` (null on the last page). Every page
  reports `total_count` computed independently of the page size, so an agent
  can claim a unique exact match only when `total_count == 1`.

## 11. Output shapes

```json
{ "schema_version": 1, "ok": true,
  "item": { "id", "display_id", "text", "status", "created_at_ms", "updated_at_ms",
            "completed_at_ms", "deleted_at_ms", "revision",
            "reminder": null | { "id", "deadline_ms", "deadline", "time_input", "input_kind",
                                 "state", "acknowledged_at_ms", "generation" } },
  "changed": true, "replayed": false,
  "scheduling": null | { "state": "pending|scheduled|unavailable", "reason", "observed_at_ms" },
  "cancellation": null | { "state": "pending", "reason" },
  "undo": { "command": "rallo restore <display_id>", "item_id" },   // delete only
  "warnings": [] }
```

Errors: `{"ok": false, "error": {"code", "message", "detail"?}}` where
`detail` is `{total, candidates[]}` (ambiguity), `{current}` (revision
conflict / precondition), or `{limit, active}` (capacity).

In M1, an active reminder reports `scheduling = {state: "pending", reason:
"awaiting_app"}` because nothing drains intents yet; M2 adds `scheduled` and
`unavailable` from native observations. An unresolved cancel intent reports
`cancellation = {state: "pending", reason: "awaiting_app"}`.
