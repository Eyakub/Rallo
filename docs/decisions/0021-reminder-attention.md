# 0021 — Reminder attention

- **Status:** accepted (user, 2026-10-10)
- **Date:** 2026-10-10
- **Mockup:** `docs/mockups/reminder-attention.html` (open it in a browser;
  it follows the system's Light or Dark Mode)
- **Related:** 0005 (notification protocol, unchanged), 0002 (pet window,
  unchanged), 0008 (agent long-wait alert), 0022 (eye breaks, shares
  §9 and §10)

## Context

Users miss reminders. Today a reminder is one native banner with the
`.default` sound (`Notifications/NotificationDrainer.swift:112`):

- The banner slides away after about 5 s (macOS "Banners" style).
- While Rallo is the frontmost app, `willPresent` returns `[.banner, .list]`
  without `.sound` (`Notifications/NotificationCoordinator.swift:42-46`), so
  the reminder is silent.
- No interruption level is set, so a Focus swallows it.
- The pet switches to its `nudge` pose (`Pet/PetStateDriver.swift:77`) and
  stays in its corner.

The agent long-wait alert (0008, `Notifications/AgentWaitNotifier.swift`)
has the same reach.

The build plan says "No sound by default, cursor following, screen
roaming, guilt mechanics, or endless bouncing" (`private/rallo-macos-build-plan.md`,
pet interaction rules). The user decided on 2026-10-10 that **alerts are an
exception**: the pet may leave its corner and sound may repeat for an
alert, and these are on by default. Everything else in that rule still holds
(no cursor following, no roaming for its own sake, no endless bouncing: the
nag has a cap).

## Decision

### 1. Scope

An **alert** is one of:

- a **reminder alert**: a note's reminder reaching its deadline, and
- an **agent alert**: the 0008 long-wait notification being posted, when
  both "Notify on long waits" and "Use for agent long-waits too" (§7) are on.

ClickUp messages are not alerts (ClickUp sends its own; 0010). Time-sensitive
and critical interruption levels are out of scope (§13).

Four effects, each with its own switch in Settings (§7):

1. **Summon:** the pet comes to the middle of the screen with a bubble.
2. **Sound and sticky banner:** a chosen chime, and the Alerts banner style.
3. **Nag:** repeat until handled, with a cap.
4. **Edge glow:** a pulse around every display's edge.

### 2. Triggers

- **Reminder alert:** `PetStateDriver.recompute()` runs on every
  `ChangeObserver` reload and on its due timer, which fires at the next
  deadline (`Pet/PetStateDriver.swift:36-70, :115-127`). A new callback
  from every recompute hands the attention coordinator (§11) the moment to
  re-read `CoreClient.listItems(.due)` (open, enabled reminders with
  `deadline_ms <= now`, `items/repository.rs:348`) and diff the IDs: an ID
  it hasn't alerted is a new alert; an alerted ID that left the list is
  handled (§4). The existing `onDueBoundary` is not enough: it fires only
  when the due count goes from zero to some, so a reminder coming due while
  an older one is still due would be missed. Alerted IDs are kept in memory.
  An ID that leaves the due list is removed from the set, so a snoozed
  reminder that comes due again alerts again. The list is read with a limit
  of at least 32 (the active-reminder cap), so a short page can never look
  like a handled reminder.
- **Seeding:** at launch and on wake, every currently due ID goes into the
  alerted set first; only those that qualify below get a round.
- **On wake:** reminders that came due while the Mac slept produce **one
  grouped summon, no nag**.
- **On launch:** due reminders whose deadline is within the last 12 hours
  produce one grouped summon, no nag. Older due reminders only show the
  pet's `nudge` pose. Nothing is stored for this; a relaunch within 12 hours
  summons still-unhandled reminders again.
- **Agent alert:** `AgentWaitNotifier.post` (`:97`) also hands the session
  to the coordinator.

### 3. One alert round

At the trigger (t = 0), in this order:

1. **Banner** with the chosen chime (§6). `willPresent` adds `.sound`, so
   it rings while Rallo is frontmost too.
2. **Summon** (if on):
   - The pet moves from its corner to the middle of the display under the
     mouse pointer: a short hop along an arc, about 0.6 s.
   - That display dims to about 18% black. The dim window ignores the
     mouse, so clicks reach the app underneath.
   - The bubble sits above the pet:
     - Reminder: kind line "⏰ Reminder · 4:30 PM", the note text
       (first 160 grapheme clusters, line breaks flattened, as for banner
       previews), and **Done**, **Snooze 10 min ▾** (the panel's snooze
       presets), **Open**.
     - The bubble shows the note text although banners don't:
       `notifications.preview_text` governs native notifications only (it
       is off, with no switch in the app), and the bubble is Rallo's own
       window on an unlocked screen, like the notes panel. In a call it
       hides the text (§8).
     - Agent: "🤖 Agent waiting · 12 min", "Claude needs you in `rallo`",
       and **Jump to it**, **Later**.
   - Unanswered after **60 s**: the bubble closes, the pet returns to its
     corner, the dim lifts. The banner stays (it is sticky, §6).
3. **Glow** (if on): every display's edge pulses 3 times, about 5 s, in
   rust (`Theme.rustNS`). It ignores the mouse.

### 4. Nag

- If on: every **2 min** (choices 1, 2, 5), up to **5** rounds (choices 3,
  5, 10), the in-app chime plays and the summon and glow run again. The
  banner is not re-posted (0005 keeps one native request per reminder).
- One shared timer: several pending alerts still give one round per
  interval, with all of them in the bubble (§5).
- Each alert counts its own rounds; a round runs while any pending alert
  has rounds left.

**Handled** (stops the nag for that alert):

- the reminder stops being due, whatever the cause: Done, Snooze, or edit
  from the banner, the bubble, the panel, the notes window, or the CLI, or
  the note being deleted. `ChangeObserver` already reloads on every change;
  the coordinator re-reads `listItems(.due)` then;
- **Open** in the bubble, or a click on the banner body (the
  `onOpenItem` path, `NotificationCoordinator.swift:86-90`), which doesn't
  change the core, so the coordinator marks the alert handled itself;
- for an agent alert: the session stops waiting, **Jump to it**, or
  **Later**.

The bubble timing out is **not** handled.

### 5. Several alerts at once

Alerts that arrive while a summon is up, or in the same round, join one
bubble. It shows the newest, with a "+2 more" link that opens the notes
panel. Done or Snooze on the shown alert moves the bubble to the next one;
the bubble closes after the last.

### 6. Sound and sticky banner

- **Chimes:** Rallo Chime (default), Bamboo Knock, Gentle Bell, System
  default, None. The three Rallo sounds are 1.5–3 s `.caf` files made by a
  committed script (`scripts/make-chimes.py`, Python standard library, then
  `afconvert`); no third-party audio.
- **Banner sound:** `UNNotificationSound(named:)` with the chosen file;
  System default is `.default`; None sets no sound. The drainer reads the
  current choice when it builds a request (`NotificationDrainer.swift:103-125`).
- **Changing the sound** re-registers pending reminders, as the build plan
  asks of preference changes that affect pending notification content:
  `set_alert_settings` with a different `sound` records a same-deadline
  schedule intent for every active reminder whose deadline is still in the
  future, reusing `schedule_refresh_if_active`
  (`reminders/repository.rs:256-267`). The drainer then re-adds each
  request under its own identifier with the new sound (0005 allows re-adding
  the same identifier before the deadline).
- **Nag sound:** `NSSound` with the same file; System default plays
  `NSSound.beep()`; None plays nothing.
- **Sticky banner:** `Info.plist` gets `NSUserNotificationAlertStyle =
  alert` (`apps/macos/Rallo/Resources/Info.plist`), which makes Alerts the default
  for new installs. macOS doesn't let an app change an existing user's
  choice, so Settings has a "Keep banner on screen" row with **Open…**,
  which opens System Settings › Notifications › Rallo.

### 7. Settings

**Settings › Notifications**, new "Alerts" group:

| Row | Control | Default |
|---|---|---|
| Pet comes to the centre | switch | on |
| Alert sound | popup + ▶ preview | Rallo Chime |
| Repeat until handled | switch + "every 1/2/5 min" + "3/5/10×" | on, 2 min, 5× |
| Glow screen edges | switch | off |
| Use for agent long-waits too | switch (enabled only while "Notify on long waits" is on) | on |
| Keep banner on screen | **Open…** button | — |

These defaults apply to existing users after the update too.

### 8. When effects are held back or changed

Checked at the start of every round:

| Situation | Effect |
|---|---|
| A Focus is on (§9) | No summon, glow, or nag round. The banner goes to Notification Centre as macOS decides. When the Focus ends and the alert is still unhandled, one round runs and the nag goes on. |
| Camera or mic in use (§9) | The bubble shows only "Reminder" (or "An agent is waiting") and its buttons, no note text, repo, or time. The glow runs. Nag rounds are silent. |
| An eye break is on screen (0022) | The round waits until the break ends. |
| Reduce Motion, or the menu's Pause Animations | The pet fades out of its corner and in at the centre (and back). The glow is one steady fade in and out. |
| The pet is hidden | The pet appears for the summon and hides again after. The `pet.visibility` preference is not changed. |
| The pet window can't show (secure input, login window, a full-screen app that declines auxiliary windows; 0002) | The summon is skipped; banner, sound, and glow still run. |

### 9. Quiet signals (shared with 0022)

One `QuietSignals` object answers:

- **Focus on?** `INFocusStatusCenter` (Intents), after a one-time permission
  prompt (`NSFocusStatusUsageDescription` in `Info.plist`). This is Apple's
  API, not a home-made detector (the build plan forbids fabricating one).
  If spike S1 (§12) shows it can't work in Rallo's self-signed build, the
  fallback is: the nag's repeat sound goes through the native notification
  instead of `NSSound` (re-adding the reminder's own request identifier, so
  0005 still sees one request), which a Focus mutes; summon and glow show
  regardless; Settings says so under the Alerts group. S1 also checks that
  re-adding a delivered request's identifier alerts again; if it doesn't,
  the nag stays visual only while a Focus could be on.
  The prompt is requested at launch until the user answers it, also when
  the `rallo` CLI starts Rallo in the background (user, 2026-10-10).
- **Camera or mic in use?** CoreMediaIO
  `kCMIODevicePropertyDeviceIsRunningSomewhere` over the video devices and
  CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on input
  devices, ignoring the mic while Rallo's own voice typing is listening.
  Polled once a minute and at every round (no continuous polling).
- **Idle seconds, screen locked, display or system asleep:** for 0022.

### 10. Preferences (shared pattern with 0022)

A new preference key in the Rust store (`crates/rallo-core/src/preferences/mod.rs`),
the same route as `pet.visibility`:

```rust
const ALERTS_SETTINGS: &str = "alerts.settings";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AlertSettings {
    pub summon: bool,              // true
    pub sound: AlertSound,         // RalloChime
    pub nag: bool,                 // true
    pub nag_interval_minutes: u8,  // 2; one of 1, 2, 5
    pub nag_max_rounds: u8,        // 5; one of 3, 5, 10
    pub glow: bool,                // false
    pub agents: bool,              // true
}

#[serde(rename_all = "snake_case")]
pub enum AlertSound { RalloChime, BambooKnock, GentleBell, System, None }
```

- Unset or unreadable means the defaults, as the store already does.
- The setter rejects a value outside the listed choices with the existing
  validation error (the FFI is a trust boundary).
- FFI: `alert_settings()` and `set_alert_settings(_)`, a `uniffi::Record`
  mirror; `CoreClient` wrappers. Saving bumps the revision only when the
  value changes, so `ChangeObserver` refreshes an open Settings window.
- A `sound` change queues pending-reminder refreshes (§6).
- Not exported or imported, and not in the CLI (no preference is today).

### 11. Components

New folder `apps/macos/Rallo/Attention/`:

| File | Job |
|---|---|
| `AttentionPlanner.swift` | Pure value logic, no AppKit. In: settings, quiet signals, pending alerts with round counts, `now`. Out: which effects to run this round and when the next round is due. |
| `AttentionCoordinator.swift` | Takes triggers (§2), keeps pending alerts, asks the planner, runs effects, owns the nag timer, marks alerts handled (§4). |
| `SummonController.swift` | Moves the existing `PetPanel` to the centre and back (`setFrame` animation, or alpha fades under Reduce Motion), shows the bubble and the dim window, shows a hidden pet for the summon. |
| `SummonBubble.swift` | The bubble: a borderless `.nonactivatingPanel` at `.statusBar` level that takes clicks but never becomes key; SwiftUI content in `Theme` colours; VoiceOver labels on every button. |
| `EdgeGlowController.swift` | One borderless window per screen, `ignoresMouseEvents`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`. |
| `AlertSound.swift` | Maps `AlertSound` to banner sound and `NSSound`; plays previews for Settings. |
| `QuietSignals.swift` | §9; also used by 0022. |

Changes elsewhere:

- `NotificationDrainer.swift:112`: the request's sound comes from `AlertSound`.
- `NotificationCoordinator.swift:42-46`: `willPresent` adds `.sound`.
- `PetStateDriver` / `AppCoordinator`: forward the due boundary and the
  agent post to the coordinator.
- `Settings/SettingsView.swift`, `SettingsModel.swift`: the Alerts group.
- `apps/macos/Rallo/Resources/Info.plist`: `NSUserNotificationAlertStyle`,
  `NSFocusStatusUsageDescription`. `apps/macos/project.yml`: the chime
  resources and new sources in the test target.

The pet window's level, collection behaviour, and size stay as 0002 fixes
them; only its origin moves, as dragging already does. The pet's stored
placement is not changed by a summon.

### 12. Spikes, before feature code

Each answers one question in a scratch build, and each has a fallback:

| # | Question | Fallback |
|---|---|---|
| S1 | Does `INFocusStatusCenter` authorise and report a Focus in the self-signed build? | §9 fallback. |
| S2 | Does `NSUserNotificationAlertStyle = alert` still set the default for `UNUserNotificationCenter`? Test with a scratch bundle id that has never posted. | Keep only the **Open…** row. |
| S3 | Does `UNNotificationSound(named:)` play a `.caf` from the app bundle's Resources? | Copy the chimes to `~/Library/Sounds` on launch. |
| S4 | Do the CoreAudio and CoreMediaIO "running somewhere" properties work without a permission prompt? | Drop the camera/mic hold; Settings says so. |
| S5 | Does the deep link to System Settings › Notifications › Rallo open Rallo's page? | Open the Notifications page. |

Spike results go into this record under "Verified" before the plan's
feature tasks start.

### 13. Out of scope

Time-sensitive and critical interruption levels; ClickUp alerts; custom
quiet hours (the build plan uses Focus); per-reminder effect choices;
recurring reminders; changing 0005's one-request rule.

## Testing

- **Rust:** `AlertSettings` round trip; defaults when unset and when
  unreadable; each out-of-range value rejected; revision unchanged on an
  identical save; a sound change queues a same-deadline
  schedule intent for active future reminders only, and other changes
  queue none.
- **Swift units** (`AttentionPlannerTests`, injected clock): every row of
  §8; nag interval and cap; one shared round for several alerts; handled
  by due-list change, by Open, and by an agent leaving waiting; timeout is
  not handled; wake/launch grouping without nag.
- **Manual** (scratch data dir, `lsregister -u` after), screenshots in Light
  and Dark Mode: summon, bubble, glow, nag over 3 rounds; Done and Snooze
  from bubble, banner, and CLI each stop it; a full-screen app's Space;
  Focus on and off; Photo Booth running (camera hold); VoiceOver on the
  bubble's buttons. Reduce Motion can't be toggled from a terminal; the
  user checks it by hand.

## Consequences

- Alerts get loud by default for everyone after the update; each part can
  be turned off.
- The pet leaves its corner for alerts, an exception to the build plan's
  "no screen roaming" rule, recorded here.
- Rallo asks once for Focus status (if S1 passes).
- The banner's sticky style only applies by default to new installs.

## Verified

Spikes run 2026-10-10 on macOS 27.0.1, scratch build of `feat/attention-breaks` (plan 1, Task 1).

| # | Question | Result | Fallback task |
|---|---|---|---|
| S1 | `INFocusStatusCenter` authorises and reports a Focus | FAIL: the prompt appears and authorisation succeeds (status 3), but `isFocused` stays `false` with Do Not Disturb on and "Share Focus Status" on. A copy signed with `com.apple.developer.usernotifications.communication` doesn't launch (restricted entitlement, no provisioning profile). | 11a |
| S1b | Re-adding a delivered request's identifier alerts again | PASS (visual): the banner, gone after its few seconds, is presented again when the same identifier is re-added 20 s later. Its sound couldn't be judged: on this Mac every notification is silent, also one posted by `osascript` with a sound. | 11a uses the re-notify route |
| S2 | `NSUserNotificationAlertStyle = alert` sets Alerts for a new bundle id | FAIL: a never-seen bundle id with the key gets **Temporary**. macOS 27 names the styles "Temporary" and "Persistent". | 11b |
| S3 | `UNNotificationSound(named:)` plays a `.caf` from the bundle | NOT JUDGED: the banner showed, silent, like every notification on this Mac. The bundle is the location Apple documents, so it stays; the user checks the chime by ear on a Mac where notification sounds play. | 11c not run |
| S4 | CoreAudio/CoreMediaIO "running somewhere" without a prompt | PASS: no prompt; camera `true` while Photo Booth runs, mic `true` while `ffmpeg` records, `false` before and after. | — |
| S5 | The deep link opens Rallo's own notification page | PASS: `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.razlio.rallo` opens Rallo's page. | — |

Probe notes: a TCC prompt is attributed to the launching process, so the
probe must start through `open` (LaunchServices), not by running the binary
from a terminal. `UNUserNotificationCenter` refuses a fresh bundle id whose
app sits under `/private/tmp`.
