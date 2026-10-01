# 0006 — Pet state (M3)

- **Status:** accepted; implements spec §2 "Pet state, in priority order".
- **Date:** 2026-09-30

The core computes the pet's pose and any one-shot transition; Swift owns
animation timing and rendering. Rust never decides *when* to show a
transition or *how long* it lasts — only *what* is true right now.

## Inputs

`Store::pet_snapshot()` is the only I/O: a cheap read-only projection reusing
existing indexes (`items_open_by_created` for `open_count`;
`reminders_enabled_deadline` joined to `items` for `due_count` and
`next_due_at_ms`, the same join `list --due` already uses). No migration was
needed.

```
PetSnapshot { open_count, due_count, next_due_at_ms, completion_seq, save_seq }
```

`next_due_at_ms` is the earliest deadline *after* now among the same
due-eligible set (open, nondeleted, enabled), so Swift can arm one timer for
the next transition instead of polling every second.

`decide(inputs: &PetInputs) -> PetDecision` is a pure function — no clock, no
storage — so every row of the priority table is a plain unit test. Besides
the snapshot, `PetInputs` carries what only Swift knows: `visible`,
`reduced_motion`, `animations_paused`, and two watermarks —
`seen_completion_seq` / `seen_save_seq` — plus `was_due` (last decision's
pose was `Due`, so a completion/save made while due can be told apart from
the falling edge).

## Rules

Priority, matching the plan table exactly:

1. `!visible` → `Hidden`, event `None`, `animate = false`, `ambient = false`.
2. `due_count > 0` → pose `Due`; event `Attention` only on the rising edge
   (`!was_due`), otherwise `None`. A completion or save made while still due
   never celebrates — the due state owns the whole priority slot.
3. Else `completion_seq > seen_completion_seq` → event `Celebrate`.
4. Else `save_seq > seen_save_seq` → event `Acknowledge`.
5. Steady pose (when not due): `Idle` if `open_count > 0`, else `Sleeping`.
6. `animate = visible && !reduced_motion && !animations_paused`. Reduced
   motion and the pause preference change presentation only — they never
   change `pose` or `event`, matching "reduced motion modifies presentation,
   not the underlying priority of due work."
7. `ambient = animate && pose ∈ {Idle, Sleeping}` — low-frequency idle motion,
   never during `Due` or a transient event.

`accessibility_label` is always computed from `due_count`/`open_count` with
correct singular/plural ("1 reminder due" / "2 reminders due", "1 open note"
/ "2 open notes", "no open notes"), independent of pose — a screen reader
should be able to ask "what's true" even while hidden.

Missing notification permission and database errors are not modeled here
(plan §2): they are separate health indicators the app surfaces elsewhere,
never a pet mood.

## Counters

`metadata` keys `events.completion_seq` / `events.save_seq` (INTEGER,
0 if absent — no migration; same `metadata` table pattern as
`notifications.*` in `reminders::protocol`). Both increment inside the same
write transaction as the change they report:

- `completion_seq`: `Store::complete` and the notification action `Done`
  (which applies the same completion transition) — only on the branch that
  actually flips an item to done, i.e. never for an already-done no-op or an
  idempotent replay (those return before reaching that code).
- `save_seq`: `create_note` and `create_reminder` — always, since both always
  create a new item on the branch that runs (replays return earlier).

Neither counter moves for `edit`, `reopen`, `restore`, `acknowledge`,
`cancel_reminder`, `reschedule`, `snooze`, or import: those mutate through
`repository` functions directly (import) or simply aren't a save/completion
by definition, and none of them route through the two call sites above.

## Why Swift owns timing, and how coalescing works

The core has no concept of "played" or "in progress" — Swift is the one
process rendering frames, so it is the only place that can know a transient
has actually finished. Coalescing follows directly from the watermark
design: if five completions land before Swift next calls `decide`, the seq
jumped by five but the reducer still returns exactly one `Celebrate` (rule 3
only compares "any newer" against the watermark, not a count). Swift plays
that one transient, then sets `seen_completion_seq` to the *current*
`completion_seq` (not `+1`) before its next decision — so the whole burst
never queues a second animation. The same rule and mechanism apply to
`save_seq`/`Acknowledge`. Startup follows the same shape: Swift initializes
`seen_completion_seq`/`seen_save_seq` to the current snapshot's values
before its first `decide()` call, so old events never replay as a
celebration on launch.

## Preference

`pet.animations_paused` (bool, default `false`) follows the existing
preferences pattern (`preferences::mod`): getter, and a setter that bumps
`change_revision` only when the value actually changes. It feeds `decide`'s
`animations_paused` input; it does not gate `pet_snapshot` or the counters.

## Extended by 0007

0007 ("Agent attention") adds `agents_waiting`/`agent_waiting_seq`/
`agent_done_seq` to `PetSnapshot` and `seen_agent_waiting_seq`/
`seen_agent_done_seq` to `PetInputs`, and folds them into this priority
table without renumbering it:

- Row 2 (`Due`) becomes `due_count > 0 || agents_waiting > 0`, still one
  pose and one `was_due` watermark. The rising-edge rule for `Attention`
  (`!was_due`) is unchanged; a new waiting agent additionally fires
  `Attention` on `agent_waiting_seq` crossing its own watermark, even while
  already `Due` for an unrelated reminder — the two sources are attention
  events for genuinely different reasons, so neither's edge should be
  swallowed by the other already holding the pose.
- Rows 3-4 (`Celebrate`/`Acknowledge`) gain a second `Acknowledge` source: a
  finished agent (`agent_done_seq` past its watermark), checked alongside
  the existing save watermark. (Inert since 0007's amendment: no row
  becomes `done`, so this source never fires.) `Celebrate` still outranks both; the two
  `Acknowledge` sources share the same event, so their relative order
  never changes what Swift plays.
- The accessibility label appends `, N agent(s) waiting` when
  `agents_waiting > 0`, independent of pose, same as the rest of the label.

See 0007 for where `agents_waiting`/the two agent seqs come from
(`agent_sessions`, schema v3). 0009 removed `agent_done_seq` and
`seen_agent_done_seq` and moved the sessions to the runtime file.
