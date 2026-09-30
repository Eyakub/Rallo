# 0005 — Notification protocol (M2)

- **Status:** accepted; implements spec §8 and the §9 platform operations.
- **Date:** 2026-09-30

Rust decides; Swift observes and acts. Swift never infers scheduling state:
it reports native evidence, asks the core for the next piece of work,
performs it, and reports the outcome. All native effects run through one
drainer in the app process that holds the instance lock.

## Identity

- Native request identifier: `rallo.reminder.<reminder uuid>` — stable per
  reminder, so re-adding replaces a pending request of an older generation.
- `userInfo`: `reminder_id`, `item_id`, `generation` (integer), `deadline_ms`.
  No note text outside `content.title/body`.
- Category `rallo.reminder` with actions `rallo.done` (complete the item) and
  `rallo.snooze.10m`. The default action opens the item. Dismissal changes
  nothing.

## Intent lifecycle

`notification_intents.state`:

| State | Meaning |
|---|---|
| `pending` | desired, not being attempted (never tried, backing off, or blocked) |
| `attempting` | durably marked before a native effect; outcome unknown until finished |
| `applied` | native effect confirmed (schedule: pending readback matched; cancel: removed) |
| `superseded` | a newer generation replaced it |
| `abandoned` | terminal; a schedule intent whose deadline elapsed before confirmation |

Recording an intent (0003 §3) now supersedes **both** `pending` and
`attempting` intents of the reminder, so an in-flight attempt that finishes
after a newer intent was recorded can never mark it applied.

`error_code` on an unresolved intent is its blocking/retry reason:
`permission_denied`, `native_capacity`, `not_in_readback`,
`trigger_mismatch`, `missing_from_readback`, or a native error code. On an
abandoned intent: `deadline_elapsed_unattempted`, `deadline_elapsed_retrying`,
or `delivery_unconfirmed`.

## Operations (rallo-core `reminders::protocol`, exported via UniFFI)

### `record_native_observations(authorization, pending, delivered) -> CleanupPlan`

Called at the start of every drain pass with Rallo-owned requests only.

1. Stores `notifications.authorization` (+ observed time) and the observed
   pending count in `metadata`; bumps `change_revision` only if the
   authorization changed.
2. For each pending/delivered request whose reminder exists, upserts
   `notification_observations` for that `(reminder, generation)`
   (`pending_observed_at_ms` / `delivered_observed_at_ms`). A new generation
   resets the row.
3. **Evidence resolves crash windows.** An `attempting` schedule intent whose
   generation is pending with the right trigger (deadline rounded up to the
   second) or delivered is marked `applied` — no second `add()`.
4. **Evidence reopens silent losses.** An `applied` schedule intent of the
   current generation with a future deadline (> now + 2 s) that is neither
   pending nor delivered goes back to `pending` with `missing_from_readback`
   and backoff.
5. Returns identifiers to remove, both lists limited to the
   `rallo.reminder.` prefix:
   - `remove_pending`: unparsable identifiers, unknown reminders, reminders
     not enabled.
   - `remove_delivered`: delivered entries of reminders not enabled
     (completed, deleted, cancelled, acknowledged). Delivered entries of
     enabled reminders stay: the user has not acted on them.

Swift performs the cleanup before asking for work, so orphans are removed
before new capacity is used.

### `next_platform_work() -> NextWork`

Mutating (it may abandon). Considers unresolved intents only.

- A schedule intent whose reminder deadline has elapsed:
  - `pending`, never attempted → `abandoned` / `deadline_elapsed_unattempted`;
  - `pending` after failed attempts or `missing_from_readback` →
    `abandoned` / `deadline_elapsed_retrying`;
  - `attempting` with no evidence (step 3 above did not resolve it) →
    `abandoned` / `delivery_unconfirmed`.
  An elapsed deadline is **never** submitted: macOS delivers it immediately.
  There is no automatic replay; the user can snooze to make a new attempt.
- Skips intents with `next_attempt_at_ms > now`; skips schedule intents
  blocked by `permission_denied` while the stored authorization is still
  `denied` (cancels always run).
- If the last observed Rallo pending count is ≥ 48 (half of the measured
  100-per-app limit), schedule work stays `pending` / `native_capacity`.
- An `attempting` intent is re-eligible (only the lock holder drains, so it
  is a crashed attempt); re-adding the same identifier is safe before the
  deadline.
- Order: cancels (oldest first), then schedules (earliest deadline first).
- Returns `Work(Schedule{…} | Cancel{…})` or
  `Idle{ next_wake_at_ms }` (earliest backoff expiry, if any).
- Schedule work carries display content: the note's title line (and the rest
  flattened as the body) when `notifications.preview_text` is on; otherwise
  "Rallo reminder" / "Open Rallo to see it."

### `begin_platform_attempt(intent_id, generation) -> Started(token) | Superseded`

In one write transaction: the intent must be unresolved and still the
reminder's current generation; a schedule intent's reminder must be enabled
with a future deadline. Marks it `attempting`, increments `attempt_count`,
sets `last_attempt_at_ms`, clears `next_attempt_at_ms` / `error_code`, and
commits **before** Swift touches UserNotifications. The token is
`(intent_id, generation, attempt_count)`.

### `finish_platform_attempt(token, outcome) -> Finished{ applied, superseded, retry_at_ms }`

Compare-and-set on `(intent_id, state = attempting, attempt_count)`. A stale
token (the intent was superseded, or a later attempt started) changes nothing
and reports `superseded`.

| Outcome | Effect |
|---|---|
| `Accepted{ readback_trigger_ms }` (schedule) | trigger within `[deadline, deadline + 1000)` → `applied`, observation `accepted_at_ms`; otherwise treated as `trigger_mismatch` |
| `Removed` (cancel) | `applied` |
| `NotConfirmed` | `add()` returned but readback lacks it → retry, `not_in_readback` |
| `TransientFailure{ code }` | back to `pending`, retry after 1, 5, 30, then 60 s (capped) |
| `PermissionDenied` | back to `pending` / `permission_denied`, no timer; resumes when authorization changes |

Resolution and error changes bump `change_revision` so the UI and
`rallo status` update.

### `apply_notification_action(reminder_id, generation, action) -> Applied(item) | Stale{ item?, reason }`

Actions carry IDs and generation only. The core reloads the reminder; the
action applies only if the generation is current, the reminder is enabled,
and the item is not deleted. `rallo.done` completes the item (disabling the
reminder with a cancel intent); `rallo.snooze.10m` snoozes it. Anything else
is `Stale` with `changed`, `deleted`, or `missing`; the app opens the current
item and says "This reminder changed" (or explains that it is gone).

## Scheduling status (JSON `scheduling`, FFI `ReminderSnapshot`)

Computed from the reminder's **current** generation only:

| Condition | `state` / `reason` |
|---|---|
| schedule intent `pending`, never attempted | `pending` / `awaiting_app` |
| `attempting` | `pending` / `submitting` |
| `pending` with a retry error | `pending` / `retrying` |
| `pending` / `native_capacity` | `pending` / `native_capacity` |
| `pending` / `permission_denied` | `unavailable` / `permission_denied` |
| `applied`, delivered observed | `delivered` / `observed_in_notification_center` |
| `applied`, authorization `authorized`/`provisional`/`ephemeral` | `scheduled` / `accepted` |
| `applied`, authorization `not_determined` | `scheduled` / `permission_not_requested` |
| `applied`, authorization `denied` | `unavailable` / `permission_denied` |
| `abandoned` | `unavailable` / its abandonment code |

`observed_at_ms` is the latest native observation for that generation.
"Delivered" means macOS listed it in Notification Center; it never means
the user saw or acknowledged it. Only an explicit action acknowledges.

Cancellation status: an unresolved cancel intent → `pending` /
`awaiting_app` (never attempted) or `retrying`.

## Drainer (Swift)

One `@MainActor` drainer; a pass never overlaps another (`isDraining` plus a
`needsAnotherPass` flag, not an actor whose awaits could interleave). A pass:
read authorization, pending, delivered → `record_native_observations` →
remove the cleanup identifiers → loop `next_platform_work` →
`begin_platform_attempt` → native effect → pending readback →
`finish_platform_attempt`, until `Idle`. Then arm a one-shot timer for
`next_wake_at_ms`. Triggers: launch, change-revision change, the wake timer,
authorization change, and notification responses.

`add()` success alone never marks a schedule applied: pending readback must
list the identifier with the expected trigger.

## Fault injection

Rust tests drive the protocol with `ManualClock` through every crash window:
before/after commit, after `begin` (no native effect), after native acceptance
before `finish`, during cancellation, after delivery before bookkeeping, and
a newer intent recorded mid-attempt. The installed app accepts
`--fault-injection <point>` (only with a non-default data directory) and
exits at that point, for end-to-end checks against real UserNotifications.

## Limits we accept

- Not exactly-once: a request delivered just before a crash can be followed
  by nothing (never replayed) — we choose a missed popup over a duplicate.
- A retry near the deadline races with delivery.
- Clock changes move nothing: deadlines are fixed UTC instants.
