# 0016 — Plain-language reminder times

- **Status:** accepted (user, 2026-10-06). Amends 0003 §5 (`--at` also takes
  a phrase) and, for phrases only, §7 (the fingerprint holds the resolved
  instant). Lifts the build plan's "no natural-language date interpretation"
  for this fixed grammar only: it is a deterministic rules table, not a
  language model, and anything outside it is refused.
- **Date:** 2026-10-06

## Context

`--at` takes RFC 3339 with an explicit offset (0003 §5). Agents can build
that, though they often don't know the user's offset; a person typing
`2026-10-09T17:00:00+06:00` won't. The panel has three presets (20 min, 1 h,
tomorrow 9:00) and no way to type a time. Every reminder app surveyed (Due,
Fantastical, Todoist, Apple Reminders) reads "fri 5pm".

## Decision

### Grammar

Case-insensitive, surrounding and repeated spaces ignored, English only.

| Part | Accepted | Examples |
|---|---|---|
| Time | `h[:mm]` + `am`/`pm` (space optional), `HH:MM` (24 h), `noon` | `9am`, `9:30pm`, `9 am`, `17:00`, `noon` |
| Day | `today`, `tomorrow`/`tmrw`, weekday full or short (`mon`, `tue`/`tues`, `wed`, `thu`/`thur`/`thurs`, `fri`, `sat`, `sun`) | `fri`, `friday`, `thurs` |
| Date | month name or 3-letter abbreviation + day, either order, optional 4-digit year; ISO `YYYY-MM-DD` | `oct 20`, `20 oct`, `october 20 2027`, `2026-10-20` |
| Relative | `in` + the `--in` grammar, or `in` + a number + one spelled unit (`min`/`mins`/`minute(s)`, `h`/`hr`/`hrs`/`hour(s)`, `day(s)`) | `in 2h30m`, `in 2 hours`, `in 45 min` |
| Order | a day or date and a time in either order; `at` before a time and `on` before a day or date are optional | `fri 5pm`, `5pm fri`, `on fri at 5pm` |

At most one day-or-date and one time. Nothing else may be left over.

### Resolution

`now` is the local wall-clock time when the command runs. Examples use Tue
6 Oct 2026, 10:30.

| Input | Rule | Example |
|---|---|---|
| Time only | today if strictly after `now`, else tomorrow | `9am` → Wed 7 Oct 09:00; `3pm` → Tue 6 Oct 15:00 |
| Day or date only | 09:00 that day | `fri` → Fri 9 Oct 09:00 |
| Weekday | 1–7 days ahead, never today, with or without a time | `tue`, `tue 3pm` → Tue 13 Oct |
| `today`/`tomorrow` + time | exactly that; `INVALID_TIME` if not after `now` (the user named the day, so no rolling) | `today 9am` → error |
| `today` alone | `INVALID_TIME` ("add a time") | |
| Date without year | this year unless the date is before today, then next year; `INVALID_TIME` if the result is not after `now` | `jan 5` → 5 Jan 2027; `oct 6` alone → error (09:00 passed) |
| Date with year, or ISO date | exactly that; `INVALID_TIME` if not after `now` or not a real date | `feb 30` → error |
| `in …` | `now` + the duration, as `--in` | `in 2 hours` → 12:30 |

Refused with `INVALID_TIME` and a hint (`couldn't read "later" as a time; try
"in 2h", "5pm" or "fri 9am"`): `later`, `soon`, `tonight`, `next week`,
`this weekend`, `next fri` (readers disagree which Friday), a bare hour like
`9` (am or pm?), `midnight` (start or end of the day?), and anything else
outside the grammar.

### Clock changes

The phrase resolves to a local wall-clock date and time; the offset used is
the one in force at that date and time (`mktime` with `tm_isdst = -1`), not
today's. A wall-clock time skipped by a spring-forward change moves forward
by the gap (02:30 → 03:30); a time that occurs twice in an autumn change
resolves to the earlier one.

### Where it applies

- **CLI.** `remind --at` and `reschedule --at` try RFC 3339 first, exactly as
  today, then the phrase. Output is unchanged: the human line already prints
  the resolved local time, and JSON already carries `deadline_ms`/`deadline`.
  `--in` and `snooze --in` are unchanged.
- **Panel.** "Remind Me" gains **Custom…**: a popover with a text field, a
  live preview of the resolved time (or the hint, dimmed), and **Set**. Return
  sets, Escape closes. The swipe tray keeps its three presets.
- **Agents.** `skills/rallo/SKILL.md` tells agents to pass the user's own
  words when they fit the grammar, since Rallo knows the Mac's time zone and
  its clock changes, and to report the resolved time from the response.

### Architecture

Resolve at the edge; the core's write path is untouched.

- `rallo-core/src/reminders/phrase.rs`: parse and resolve, pure. Takes `now`
  as a local wall-clock value and returns a local wall-clock value, or `in`'s
  duration. No platform code, so tests pin `now`.
- `rallo-platform-macos`: local wall-clock ↔ UTC instant via
  `localtime_r`/`mktime`, shared by the CLI and the app so both resolve the
  same way. Both functions are reentrant; nothing in Rallo sets `TZ` at run
  time.
- The CLI turns the result into RFC 3339 with the target's offset and passes
  `TimeSpec::At` as today. The FFI exposes one function, phrase + `now_ms` →
  `deadline_ms` or an error with the hint; the panel previews with it and sets
  the reminder through the existing `remindAt`.

So the stored `input_kind` is `absolute`, `time_input` is the resolved RFC
3339 string, and there is no schema or export-format change.

**Idempotency.** For a phrase, the 0003 §7 fingerprint holds the resolved
RFC 3339 rather than the words typed. A `--request-id` retry that resolves
differently (`9am` retried across midnight) gets `REQUEST_ID_CONFLICT`,
never a second reminder.

## Alternatives

- **A third `input_kind` storing the phrase.** Keeps the typed words in the
  fingerprint, but needs a schema migration, an export-format version (0004
  accepts only `relative`/`absolute`), and time-zone code in the core. Too
  much for one retry edge case.
- **A parsing crate (`chrono-english`, `interim`).** Adds `chrono` (~300 KB
  to each binary) and brings its own rules, which differ from the table
  above (rolling, the 09:00 default, the refusals).

## Testing

- Unit tests in `phrase.rs` against a fixed `now`: every grammar row, every
  resolution row, every refusal, case and spacing.
- Clock changes: the conversion with `TZ=America/New_York` across the
  spring-forward and autumn changes.
- CLI integration: `--at "fri 5pm"` stores the expected deadline, RFC 3339
  is unchanged, refusals exit 2 with nothing written, and `reschedule --at`.
- Swift: preview formatting test; Custom… clicked through in the app, with
  Dark and Light screenshots.

Size: about 50–100 KB across both binaries; no new dependency.
