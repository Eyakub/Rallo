# 0022 — Eye breaks

- **Status:** accepted (user, 2026-10-10)
- **Date:** 2026-10-10
- **Mockup:** `docs/mockups/eye-break.html` (open it in a browser; it
  follows the system's Light or Dark Mode)
- **Related:** 0021 (reminder attention: quiet signals §9, preference
  pattern §10, collisions §8), 0002 (pet window, unchanged)

## Context

The 20-20-20 rule: every 20 minutes of screen time, look at something about
20 feet (6 m) away for 20 seconds. The user wants Rallo to enforce it: the
screen goes black, a 20 s countdown runs, then work resumes. Everything is
configurable from Settings, which opens from the menu bar.

Rallo has no full-screen overlay, idle detection, or screen-lock observer
today. Its highest window level is `.statusBar` (pet, voice bubble). The
build plan forbids continuous screen or process polling; a once-a-minute
check is the cadence used below.

## Decision

### 1. Off by default

Eye breaks are **off** until the user turns them on, in Settings › Breaks or
with the menu's "Turn On Eye Breaks" item (§7). Blacking out screens that
nobody asked to black out would be hostile.

### 2. Counting screen time

- The cycle is **20 min** (setting) of screen time since the last break.
- Screen time runs only while the display is awake and the session is
  unlocked.
- Once a minute, Rallo reads the seconds since the last keyboard or mouse
  event: `CGEventSource.secondsSinceLastEventType(.combinedSessionState,
  eventType: CGEventType(rawValue: ~0)!)` (`kCGAnyInputEventType`; no
  permission needed). **Idle for 5 min or more** counts as a natural break: the
  cycle restarts at the next minute the user is active again.
- Screen lock (`com.apple.screenIsLocked` / `…screenIsUnlocked` on
  `DistributedNotificationCenter`), display sleep (`screensDidSleep` /
  `screensDidWake`), and system sleep (`willSleep` / `didWake`) pause the
  count. Unlock or wake starts a fresh cycle.
- Changing the interval in Settings starts a fresh cycle.

### 3. Warning

- **10 s** (setting: off, 5, 10, 30) before the break, a pill appears at the
  top centre of the display under the mouse pointer: a countdown ring, "Eye
  break in 8 s", and **Start now**, **+5 min**, **Skip**.
- The pill is a `.nonactivatingPanel` that takes clicks and never becomes
  key, so typing goes on uninterrupted.
- The pet shows its `nudge` pose for the warning.
- With the warning set to off, the break starts with no pill.

### 4. The break

- Every display fades to black over about 0.5 s. One borderless window per
  screen at `.popUpMenu` level (S6), `[.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary, .ignoresCycle]`, so it covers
  full-screen apps, the menu bar, and the Dock.
- The display under the mouse pointer shows style "With Rallo": the pet in
  its `content` pose, dimmed, a **20 s** (setting: 10, 20, 30, 60)
  countdown, and one tip, rotating each break from: "Look at something far
  away", "Blink slowly", "Look out the window". Other displays are plain
  black.
- **Skip · esc** and **+5 min** sit at the bottom, dim.
- Rallo activates (`NSApp.activate`) and makes the main overlay key, so Esc
  works and keystrokes can't land in the user's document. macOS grants a
  running background app activation a few seconds late (up to ~4 s
  measured), so keys typed in that gap still reach the app behind; an Esc
  held through the gap still skips, as the first repeat the overlay sees
  starts a 3 s hold. A non-activating panel would take no keys at all, Esc included,
  so it isn't used (Verified). It records
  `NSWorkspace.shared.frontmostApplication` first and re-activates that app
  when the break ends.
- Clicks and typing are swallowed. Rallo doesn't pause media.
- **Skip** counts as a break taken (next in a full cycle). **+5 min** closes
  the overlay and shows the warning again in 5 min.
- **Strict mode** ("Allow skipping" off): no buttons, and **Esc does
  nothing, pressed or held** (user, 2026-10-10). Only the countdown ending
  closes the overlay, whatever else happens; Force Quit (⌥⌘Esc) shows above
  it (Verified) and quitting Rallo removes it, the way out of a stuck
  overlay. Strict mode
  changes only the black screen: the warning pill keeps **Start now**,
  **+5 min** and **Skip** (user, 2026-10-10).
- VoiceOver: an announcement "Eye break, 20 seconds" when it starts, and
  the buttons are labelled.

### 5. After

- The black fades out over about 1 s, and focus returns to the recorded
  app.
- A toast near the pet, "Eyes rested · next in 20 min", shows for 3 s with
  the pet's `happy` pose.

### 6. Hold rules

| Situation | Effect |
|---|---|
| Camera or mic in use (0021 §9; setting, on by default) | No warning. Checked every minute; the warning starts once both are free. A call that starts during the warning cancels it. |
| A reminder bubble is on screen (0021) | The break waits until the bubble closes. A reminder that fires during a break waits until the break ends (0021 §8). |
| A Focus is on | Ignored: the user turned eye breaks on, and the camera/mic hold covers calls. |
| Paused from the menu (§7) | No warning or break until the pause ends; then a fresh cycle. |
| Reduce Motion, or Pause Animations | No fades: the overlay cuts in and out; the countdown is numbers only. |

### 7. Menu bar

Added to the status menu (`App/StatusMenuController.swift`), between the
pet items and Settings…:

- A disabled status line, one of: "Eye break in 12:34" (the time when the
  menu opens; it doesn't tick while open), "Eye breaks paused until
  5:30 PM", or, when off, the item **Turn On Eye Breaks**.
- **Take a Break Now**: starts the break at once, with no warning.
- **Pause Eye Breaks ▸** For 30 Minutes / For 1 Hour / Until Tomorrow
  (until local midnight).

Shortcut: the pause lives in memory only, so relaunching Rallo ends it.
Upgrade if users report it: store `paused_until_ms` in the preference.

### 8. Settings

A new **Breaks** tab (`SettingsTab.breaks`, between Notifications and
Agents):

| Row | Control | Default |
|---|---|---|
| Remind me to rest my eyes | switch | off |
| Every | popup 10 / 15 / 20 / 30 / 45 / 60 min | 20 min |
| Break length | popup 10 / 20 / 30 / 60 s | 20 s |
| Warn before | popup off / 5 / 10 / 30 s | 10 s |
| Allow skipping | switch ("Off = strict mode") | on |
| Hold while camera or mic is in use | switch | on |

There is one style ("With Rallo"); no style picker.

### 9. Preferences

Same pattern as 0021 §10:

```rust
const EYE_BREAKS_SETTINGS: &str = "eye_breaks.settings";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct EyeBreakSettings {
    pub enabled: bool,          // false
    pub interval_minutes: u8,   // 20; one of 10, 15, 20, 30, 45, 60
    pub length_seconds: u8,     // 20; one of 10, 20, 30, 60
    pub warn_seconds: u8,       // 10; one of 0, 5, 10, 30 (0 = off)
    pub allow_skip: bool,       // true
    pub hold_on_call: bool,     // true
}
```

FFI `eye_break_settings()` / `set_eye_break_settings(_)`, `CoreClient`
wrappers; out-of-range values rejected; not exported, not in the CLI.

### 10. Components

New folder `apps/macos/Rallo/EyeBreak/`:

| File | Job |
|---|---|
| `EyeBreakPlanner.swift` | Pure state machine, no AppKit: `counting → warning → breaking → counting`, plus `held` and `paused`. Inputs: settings, ticks with idle seconds, lock/sleep/wake events, quiet signals, bubble-on-screen, user actions (start now, +5 min, skip, held Esc, pause until). Output: the state and the next time it needs a tick. |
| `EyeBreakController.swift` | Owns the timer (armed to the planner's next time, at most a minute away), the `QuietSignals` (0021 §9) and system observers, and the windows below. Records and restores the frontmost app. |
| `EyeBreakOverlay.swift` | The per-screen black windows and the main screen's SwiftUI content (pet, countdown, tip, buttons); Esc and hold-Esc handling. |
| `EyeBreakPill.swift` | The warning pill panel. |

Changes elsewhere: `StatusMenuController` (§7), `SettingsView` /
`SettingsModel` (§8), `AppCoordinator` (create and wire the controller; tell
it when a reminder bubble opens and closes), `apps/macos/project.yml` (test
target sources).

### 11. Spike, before feature code

| # | Question | Fallback |
|---|---|---|
| S6 | Does a `.screenSaver`-level window cover another app's full-screen Space and the menu bar; does Esc reach it after `NSApp.activate`; does re-activating the recorded app restore focus; is ⌥⌘Esc (Force Quit) still reachable? | Use the highest level that keeps Force Quit reachable; record the surfaces it can't cover, as 0002 does. Applied: `.popUpMenu`. |

S4 (camera/mic, 0021 §12) also gates the hold rule. Results go into this
record under "Verified" before the feature tasks start.

### 12. Out of scope

Statistics or streaks; break reminders other than 20-20-20 (posture,
water); pausing media; per-display settings; a CLI for breaks; detecting
screen sharing or presenting other than through camera/mic.

## Testing

- **Rust:** `EyeBreakSettings` round trip, defaults, rejections, unchanged
  revision on an identical save.
- **Swift units** (`EyeBreakPlannerTests`, injected clock): counting to the
  warning; idle ≥ 5 min restarts the cycle and < 5 min doesn't; lock and
  sleep pause, unlock and wake restart; warning off; Start now, +5 min,
  Skip; strict mode ignores Esc, pressed or held; the
  countdown always ends the break; camera/mic hold and release; a call
  starting during the warning; bubble on screen delays the break; pause
  until a time; interval change restarts.
- **Manual** (scratch data dir, a short interval), screenshots in Light and
  Dark Mode: warning pill; overlay on the main and a second display (if
  available); over a full-screen app; focus returns to the previous app;
  Esc ignored in strict mode; Photo Booth running holds the break; menu status
  line and pause items; VoiceOver announcement. Reduce Motion is the user's
  manual check.

## Consequences

- Rallo can take over the whole screen for up to 60 s, only after the user
  turns eye breaks on. In strict mode only the countdown or Force Quit ends
  it.
- Rallo becomes the active app for the length of a break, then hands focus
  back.
- A once-a-minute timer runs while eye breaks are on.

## Verified

- **S6 (2026-10-10, macOS 27.0.1, 3 displays: EK240Y main, built-in, VA2209), run with the user at the keyboard:**
  - A `.screenSaver` (1000) borderless window with `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` covered TextEdit's full-screen Space: yes (main-display captures 4 s and 12 s in: all black).
  - It covered the menu bar: yes.
  - Esc reached the key overlay after `NSApp.activate()`: yes. The log read `active=false key=false` 0.5 s in, yet every Esc press arrived, and a held Esc arrived as `repeat=true` key-downs; activation is cooperative and lands a moment later. That probe was a fresh `open` launch, which macOS lets activate.
  - Re-activating the recorded app restored focus, and a typed letter landed in TextEdit: yes (`restore com.apple.TextEdit: true`, `frontmost after: com.apple.TextEdit`).
  - ⌥⌘Esc showed Force Quit above the overlay: no.
  - Level kept: `.popUpMenu` (101), from Step 3.
- **S6 Step 3, at `.popUpMenu` (101):** the menu bar stayed covered; Esc reached the overlay; ⌥⌘Esc showed Force Quit above the black (capture of the built-in display); re-activating the recorded app returned `true`.
- Surfaces the overlay can't cover, at either level: Mission Control (a hot corner opened it above the black on the main display), and the Dock when the pointer reveals it (seen once at 101). Both are the user reaching for the system, so they stay.
- **In the app (2026-10-10, Rallo already running in the background, TextEdit active, the user typing):** `NSApp.activate()` landed about 4 s after the overlay appeared (`lsappinfo` front: TextEdit, then Rallo). A letter typed in that gap landed in TextEdit; Esc after it skipped the break and focus went back to TextEdit. A non-activating `NSPanel` overlay (tried in 85a8f15, reverted) swallowed typing but got no key events at all: AppKit reported `isActive` and `isKeyWindow` true, yet a local `NSEvent` monitor saw nothing for 18 s, with or without `NSApp.activate()`, so Esc and the strict hold could never end the break. The activating window stays; closing the gap would need Input Monitoring or Accessibility permission.

