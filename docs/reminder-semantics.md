# Reminder semantics

Reminder intent, scheduling, and the native notification protocol are built in
M1–M2. This file records the contract as it is implemented and the platform
behaviour it relies on. Observations are from macOS 27.0 (26A428) on the
machine in `platform-support.md`; they are not claims about other versions.

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
