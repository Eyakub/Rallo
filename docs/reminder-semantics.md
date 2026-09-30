# Reminder semantics

Reminder intent, scheduling, and the native notification protocol are built in
M1–M2. This file records the contract as it is implemented and the platform
behaviour it relies on. Observations are from macOS 27.0 (26A428) on the
machine in `platform-support.md`; they are not claims about other versions.

The M2 notification protocol — intent lifecycle, the `reminders::protocol`
operations, the full scheduling/cancellation status table, and the
fault-injection list — is specified in
`docs/decisions/0005-notification-protocol.md`.

## Product capacity: 32 active reminders

Rallo caps the MVP at **32 active reminders**. This is a deliberately
conservative product boundary pending capacity verification, **not an Apple
limit**. Creating a reminder beyond it is rejected before commit with
`REMINDER_CAPACITY_REACHED`; it is never silently turned into a plain note.

## Delivery is not exactly-once

Rallo does not describe notification delivery as exactly-once. Reusing a
request identifier replaces a *pending* request but can alert again if the
earlier notification was already delivered, and a delivered notification may
already have been dismissed. Retries close to a deadline race with delivery.

## Platform observations (M0 notification probe)

Measured with `Rallo.app/Contents/MacOS/Rallo --probe …` under the installed
app identity (`com.razlio.rallo`, ad-hoc signed).

| Observation | Result | Consequence for Rallo |
|---|---|---|
| Pending-request limit | **100 per app.** Batches of 1, 32, 64, 65 were fully accepted and read back; 101, 128, 256 left exactly 100 pending. | 32 leaves wide headroom; orphan cleanup still runs before new scheduling. |
| Behaviour over the limit | `add()` returns **no error**; an **arbitrary** request is evicted (not the newest, not the latest deadline — e.g. submission #67 of 101 disappeared). | Acceptance must be confirmed by pending readback, never inferred from `add()` success. Rallo must never approach the limit, since overflow can drop an *existing* reminder. Bulk probes refuse to run while Rallo reminders are pending. |
| Trigger fidelity | Full-component UTC `UNCalendarNotificationTrigger`: `nextTriggerDate` matched the intended whole second for all 256 requests. | Fixed-instant semantics work as designed. |
| Sub-second deadlines | Deadlines are rounded **up** to the next whole second; delivery matched the rounded instant. | An alert is never early. |
| Already-elapsed instant | Accepted, `nextTriggerDate == nil`, and **delivered immediately** (≈10–20 ms). | Submitting an elapsed deadline creates an immediate alert. Reconciliation must never (re)submit an elapsed deadline; overdue handling follows the recovery matrix. |
| Before authorization | With status `not_determined`, `add()` succeeds, requests read back as pending, and elapsed ones appear in the delivered list. | "Accepted" and even "delivered" do not imply the user saw anything. Scheduling status must combine acceptance with authorization state. |

| App exited | A request accepted earlier fired at its deadline with no Rallo process alive. | OS scheduling is independent of the app for accepted requests. |
| App quit and relaunched | The pending request survived, read back as pending, and fired on time. | Restart reconciliation can rely on pending readback as evidence. |
| Cancel | `removePending` before the deadline: neither pending nor delivered afterwards. | |

Presentation with authorization granted and notification clicks are
recorded in `docs/decisions/0001-macos-feasibility.md` once verified.

## Time contract (v1)

Relative (`--in`) and absolute (`--at`, RFC 3339 with explicit offset) inputs
resolve once to a fixed UTC deadline. Native triggers use full UTC calendar
components derived from that stored instant, never local hour/minute alone,
and are never recomputed from the original relative text.

## M2 end-to-end fault injection

`scripts/fault-notifications.sh` drives the installed app against the real
UserNotifications center, one isolated data directory per scenario, killing
the app at `--fault-injection` points (0005). Run 2026-09-30 on macOS 27.0
(26A428), MacBook Pro Mac15,6, authorization `denied` for Rallo (so an
accepted request reports `unavailable/permission_denied`, as specified):

| Scenario | Result |
|---|---|
| CLI `remind` while the app runs | accepted and read back ≈2 s after the CLI returned; one pending request |
| Crash after the durable attempt mark, before `add()` | nothing submitted; status `pending/submitting`; relaunch scheduled exactly one request |
| Crash after macOS accepted, before bookkeeping | request pending in macOS; relaunch resolved it from readback evidence with **no second `add()`** |
| Crash during cancellation (after removal) | request gone; cancellation `pending`; applied on relaunch |
| Attempt interrupted, deadline passes while down | `unavailable/delivery_unconfirmed`; never replayed, no late alert |
| App could not launch before the deadline | CLI warning; `unavailable/deadline_elapsed_unattempted`; no late alert |
| Fires with no Rallo process | listed as delivered right after the deadline; relaunch reported `delivered/observed_in_notification_center` |
| Two data directories at once | each store's requests untouched by the other's cleanup |

Further observations on this machine:

- With authorization `denied`, `add()` still succeeds and the request reads
  back as pending (it is simply not presented).
- A plain quit and relaunch keeps pending requests. Rebuilding and
  reinstalling the ad-hoc-signed development app did remove them (and
  delivered entries); the drainer re-added future ones via
  `missing_from_readback`. Whether a Developer ID-signed update behaves the
  same is unverified.
- Presentation with authorization granted and notification clicks/actions
  remain unverified (authorization was never granted here).
