# Eye Breaks (20-20-20) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every 20 minutes of screen time (configurable), Rallo warns for 10 s with a pill, then blacks out every display for 20 s with the pet, a countdown and a tip, then hands focus back. A camera or mic in use, or a reminder bubble on screen, holds it. It is controlled from a new Settings › Breaks tab and from the menu bar, as pinned by `docs/decisions/0022-eye-breaks.md`.

**Architecture:**
- **Stored settings.** One preference, `eye_breaks.settings`, in the Rust store (same route as `pet.visibility`). It reaches the app through UniFFI and `CoreClient`.
- **Pure logic, unit tested.** All timing and decisions live in two Foundation-only files that are also compiled into `RalloTests`:
  - `EyeBreakPlanner` is the state machine.
  - `EyeBreakEffects` maps a phase change to a list of effects. It also holds the menu text, the pause end times and the choice of main screen.
- **AppKit side, thin and click-tested.** `EyeBreakController` feeds the planner the clock, idle time, quiet signals and system events, and performs the effects. The views are `EyeBreakOverlay` and `EyeBreakPill` (which also holds the toast).

**Tech Stack:**
- Rust (`rallo-core`, `rallo-ffi` with UniFFI)
- Swift 5 mode, AppKit + SwiftUI, macOS 14 target
- XcodeGen, XCTest

**Spec:** `docs/decisions/0022-eye-breaks.md`. Also 0021 §8–§10: the quiet signals, the preference pattern, and the collisions with reminder alerts.

**Depends on plan 1 (`docs/plans/2026-10-10-attention-1-alerts.md`) being merged on `feat/attention-breaks`.** Task 1 checks that the plan-1 API below compiles and behaves as described. If it doesn't:
- stop and report the exact mismatch to the orchestrator;
- do not rename anything in later tasks to compensate.

The assumed API is the frozen cross-plan contract, copied verbatim:

## Cross-plan contract (frozen 2026-10-10; plan 1 produces, plan 2 consumes)

Copy this block verbatim into plan 1 as "API this plan produces for plan 2"
and into plan 2 as the API its Task 1 compile-checks. Do not rename anything.

### Rust core (`crates/rallo-core/src/preferences/mod.rs`)

Plan 1:
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AlertSound { #[default] RalloChime, BambooKnock, GentleBell, System, None }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
impl Default for AlertSettings { /* the values in the comments */ }

impl Store {
    pub fn alert_settings(&self) -> CoreResult<AlertSettings>;
    /// Ok(true) if the stored value changed. Rejects a value outside the
    /// listed choices with the existing validation error. A `sound` change
    /// queues a same-deadline schedule intent for every active reminder with
    /// a future deadline, in the same transaction (0021 §6).
    pub fn set_alert_settings(&mut self, settings: AlertSettings) -> CoreResult<bool>;
}
```

Plan 2:
```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct EyeBreakSettings {
    pub enabled: bool,          // false
    pub interval_minutes: u8,   // 20; one of 10, 15, 20, 30, 45, 60
    pub length_seconds: u8,     // 20; one of 10, 20, 30, 60
    pub warn_seconds: u8,       // 10; one of 0, 5, 10, 30 (0 = off)
    pub allow_skip: bool,       // true
    pub hold_on_call: bool,     // true
}
impl Store {
    pub fn eye_break_settings(&self) -> CoreResult<EyeBreakSettings>;
    pub fn set_eye_break_settings(&mut self, settings: EyeBreakSettings) -> CoreResult<bool>;
}
```

### FFI (`crates/rallo-ffi`)

UniFFI mirrors with the same type names (`AlertSound` enum, `AlertSettings`
record; plan 2: `EyeBreakSettings` record), converted with `From`/`Into`
the way `PetVisibility` is (`crates/rallo-ffi/src/types.rs`). Methods on the
store object (`crates/rallo-ffi/src/lib.rs`, next to `set_pet_visibility`):
```rust
pub fn alert_settings(&self) -> Result<AlertSettings, RalloError>;
pub fn set_alert_settings(&self, settings: AlertSettings) -> Result<bool, RalloError>;
// plan 2
pub fn eye_break_settings(&self) -> Result<EyeBreakSettings, RalloError>;
pub fn set_eye_break_settings(&self, settings: EyeBreakSettings) -> Result<bool, RalloError>;
```
Generated Swift: `AlertSettings(summon:sound:nag:nagIntervalMinutes:nagMaxRounds:glow:agents:)`,
`enum AlertSound { case ralloChime, bambooKnock, gentleBell, system, none }`,
`EyeBreakSettings(enabled:intervalMinutes:lengthSeconds:warnSeconds:allowSkip:holdOnCall:)`.

### CoreClient (`apps/macos/Rallo/Core/CoreClient.swift`)

```swift
func alertSettings() async throws -> AlertSettings
@discardableResult func setAlertSettings(_ settings: AlertSettings) async throws -> Bool
// plan 2
func eyeBreakSettings() async throws -> EyeBreakSettings
@discardableResult func setEyeBreakSettings(_ settings: EyeBreakSettings) async throws -> Bool
```

### Swift, plan 1: `apps/macos/Rallo/Attention/QuietSignals.swift`

```swift
/// "Should Rallo hold back right now?" (0021 §9, 0022 §6).
@MainActor final class QuietSignals {
    /// Rallo's own voice typing; its mic use doesn't count.
    var isVoiceTypingListening: () -> Bool = { false }
    /// Asks once for Focus status. A no-op where unavailable (spike S1).
    func requestFocusAuthorization()
    /// True only when authorised and a Focus is on.
    var focusOn: Bool { get }
    /// A camera, or an input device, running in any process, ignoring
    /// Rallo's own voice typing. False if detection is unavailable (S4).
    var cameraOrMicInUse: Bool { get }
    /// Seconds since the last keyboard or mouse event (kCGAnyInputEventType).
    static func idleSeconds() -> TimeInterval
}
```

### Swift, plan 1: the eye-break seam on `apps/macos/Rallo/Attention/AttentionCoordinator.swift`

```swift
@MainActor final class AttentionCoordinator {
    /// Set by plan 2. While it returns true, rounds wait (0021 §8).
    var eyeBreakActive: () -> Bool = { false }
    /// Plan 2 calls this when a break ends; a waiting round runs then.
    func eyeBreakEnded()
    /// True while the summon bubble is on screen.
    private(set) var isBubbleVisible: Bool
    /// Fires on every change of `isBubbleVisible`; plan 2 holds a break while true.
    var onBubbleVisibilityChanged: (Bool) -> Void = { _ in }
}
```

### Ownership

- `AppCoordinator` owns `let quietSignals: QuietSignals` and `let attention: AttentionCoordinator` (plan 1). Plan 2 adds `eyeBreaks: EyeBreakController` and wires the seam above.
- `SettingsModel`: plan 1 adds `@Published var alertSettings: AlertSettings` and `var setAlertSettings: (AlertSettings) -> Void`; plan 2 adds `@Published var eyeBreakSettings: EyeBreakSettings`, `var setEyeBreakSettings: (EyeBreakSettings) -> Void`, and `SettingsTab.breaks` between `.notifications` and `.agents`.
- `StatusMenuController` eye-break items: plan 2 only.
- `apps/macos/project.yml`: each plan adds its own files to the `RalloTests` shared sources, then `(cd apps/macos && xcodegen generate)`.
- `QuietSignals` is created by plan 1 even if a spike fails; a failed spike makes the matching property return `false`, never removes it.

## Global Constraints

**Build and tools**
- The Swift/SwiftUI app is generated by XcodeGen: macOS 14 target, Swift 5 mode.
- Never hand-edit `apps/macos/Rallo/Generated/` (gitignored, regenerated by the build) or `apps/macos/Rallo.xcodeproj` (generated).
- New files go through `apps/macos/project.yml`, then `(cd apps/macos && xcodegen generate)`. The build scripts also run it.
  - The `Rallo` target picks up everything under `Rallo/` automatically.
  - The `RalloTests` target lists its shared sources by hand.
- Rust is Homebrew `rustup`, which is keg-only. Run `export PATH=/opt/homebrew/opt/rustup/bin:$PATH` in every shell that builds.
- Build into a `*.noindex` folder (`build/DerivedData.noindex`, as `scripts/build-macos.sh` does) so Spotlight never offers a build copy as "Rallo".
- The Swift test command for every task: `xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test` (README).

**Data and installs**
- Tests and manual checks use a temp data dir (`--data-dir` / `RALLO_DATA_DIR`), never the real one.
- Scratch builds registered with LaunchServices get `lsregister -u` afterwards.
- Never install over `~/Applications/Rallo.app`: no `--install` anywhere in this plan.

**UI checks**
- For every UI change: build, launch the scratch build on a temp data dir, and click through every new behaviour.
- Screenshot **both Light and Dark Mode** before calling a task done (repo CLAUDE.md). The harness below does this per window.

**Commits**
- Conventional commits (`feat(app): …`, `feat(core): …`, `test(app): …`, `docs: …`).
- Author `eyakubsorkar@gmail.com` (already `git config user.email`).
- NO AI attribution and no Co-Authored-By trailer. The repo rule overrides any tool default.
- Stage only the named paths. Untracked `assets/pet/rallo/launch-kit/` and `marketing/` are not ours: never `git add -A` or `git add .`.

**Out of this plan**
- No release, version bump, README, `docs/images` or release-notes change. The release does those.

**Spec values, verbatim**
- Preference key `eye_breaks.settings`. Eye breaks are off by default.
- Choices:
  - interval 10/15/20/30/45/60 min (default 20);
  - length 10/20/30/60 s (default 20);
  - warning off/5/10/30 s (default 10; `0` = off);
  - Allow skipping on;
  - Hold while camera or mic is in use on.
- Idle for 5 min or more is a natural break.
- Lock, display sleep or system sleep pause the count; unlock or wake starts a fresh cycle.
- Changing the interval starts a fresh cycle.
- +5 min brings the warning back in 5 min.
- Skip counts as a break taken.
- Strict mode: no buttons, and a short Esc does nothing. **Holding Esc for 3 s always ends a break.** The countdown end always closes the overlay.
- Overlay: one borderless window per screen at `.screenSaver` level (until S6 says otherwise), `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
- The screen under the mouse shows the pet's `content` pose, dimmed, plus the countdown and one tip. Tips rotate in this order: "Look at something far away", "Blink slowly", "Look out the window".
- Buttons **Skip · esc** and **+5 min**.
- VoiceOver announces "Eye break, 20 seconds".
- Pill copy is "Eye break in 8 s", with buttons **Start now**, **+5 min**, **Skip**. The pet shows `nudge` during the warning.
- Toast "Eyes rested · next in 20 min" for 3 s, with the `happy` pose.
- Menu items:
  - a status line: "Eye break in 12:34", or "Eye breaks paused until 5:30 PM";
  - **Turn On Eye Breaks** while they are off;
  - **Take a Break Now**;
  - **Pause Eye Breaks ▸** For 30 Minutes / For 1 Hour / Until Tomorrow (local midnight).
- The pause lives in memory only.
- Settings tab **Breaks** (symbol `eye`), with these rows:
  - "Remind me to rest my eyes"
  - "Every"
  - "Break length"
  - "Warn before"
  - "Allow skipping" ("Off = strict mode")
  - "Hold while camera or mic is in use"

## Spec notes (where 0022 is silent, this plan decides)

1. **Strict mode and the pill.** Strict mode also hides **+5 min** and **Skip** on the pill. **Start now** stays. Both buttons avoid the break, which is what "Allow skipping" is about.
2. **Esc outside strict mode** skips on key-down. Key repeats are ignored.
3. **Status line while held.** A due break held by a call or a bubble shows "Eye break when you’re free".
4. **Take a Break Now** works while counting, held, warned or paused, because the user asked. It does nothing while off or away.
5. **Skip from the pill** counts as a break taken but shows no toast, because no break happened. Only a break that leaves the screen (completed, Skip, held Esc) shows the toast. +5 min and lock/sleep don't.
6. **Clock changes.** A warning or break never lasts longer than its setting, even if the clock jumps back. A late tick never shortens a warning and never shows an already-expired break.
7. **Bad stored values.** A stored value that parses but is outside the choices reads as the defaults, like an unreadable one.
8. **Disabled rows.** The Settings rows below the switch are disabled while eye breaks are off.
9. **Manual-check override.** `RALLO_EYE_BREAK_SECONDS` replaces the interval in a **scratch instance only**: a non-default `--data-dir`, the same rule as `RALLO_PREVIEW_UPDATE` and the agent long-wait override. Values below 15 s are ignored. Manual checks then see a warning and a break within a minute instead of 10–60 minutes.
10. **Restoring focus.**
    - The app that was frontmost when the break began is re-activated whenever the break ends, however it ends.
    - If Rallo itself was frontmost (the panel or notes window open), nothing is re-activated and Rallo stays active.
    - If Rallo never became active, re-activating the recorded app is harmless: it is still in front.

## Review Focus

1. **The overlay always closes and focus always comes back.**
   - The countdown end closes the overlay in strict mode, during a call, with a reminder bubble up, and when the timer fires late.
   - Every exit from a break restores focus, even if `NSApp.activate()` failed and Esc never arrived.
   - Tests: `EyeBreakPlannerTests.testTheCountdownAlwaysEndsTheBreak` (Task 5) and `EyeBreakEffectsTests.testEveryExitFromABreakClosesTheOverlayRestoresFocusAndResumesAlerts` (Task 6). Check: Task 9 click-through steps 4 and 6.
2. **Collisions with reminder alerts.**
   - A reminder bubble on screen delays a due break, and the break starts once the bubble closes.
   - A bubble appearing mid-break neither ends nor extends it.
   - A reminder that fires during a break waits: `attention.eyeBreakActive` is true and `eyeBreakEnded()` runs when the break ends.
   - Tests: `EyeBreakPlannerTests.testABubbleOnScreenHoldsTheBreakUntilItCloses` and `testABubbleAppearingMidBreakNeitherEndsNorExtendsIt` (Task 5); `.resumeAlerts` in the Task 6 exit test. Check: Task 9 click-through step 9.
3. **Sleep or lock mid-warning or mid-break.**
   - The pill or overlay goes away and focus is restored, with no toast.
   - Unlock or wake starts a full fresh cycle, never an instant break.
   - Tests: `EyeBreakPlannerTests.testLockOrSleepPausesAndUnlockStartsAFreshCycle` (Task 5) and `EyeBreakEffectsTests.testGoingAwayMidBreakClosesWithoutAToast` (Task 6). Check: Task 9 click-through step 7.
4. **Screens added or removed during a break.**
   - Every display goes black, the countdown sits on the screen under the mouse (the first screen if the mouse is off every screen), and a display connected mid-break goes black too.
   - Test: `EyeBreakEffectsTests.testTheCountdownGoesToTheScreenUnderTheMouse` (Task 6). Check: Task 9 click-through step 8; needs a human without a second display.
5. **Late ticks and clock jumps.**
   - A Mac that wakes without `didWake`, App Nap, or a clock change can deliver the timer minutes late or move the clock back.
   - The warning still gets its full length, an expired break is never shown, and a clock moved back never stretches a warning or break past its setting.
   - Test: `EyeBreakPlannerTests.testALateTickNeverShortensTheWarningOrShowsAnExpiredBreak` (Task 5).

## Needs a human

- **Reduce Motion:** the overlay cuts in and out with no fades. A terminal can't toggle it (`com.apple.universalaccess` is TCC-protected).
- **Second display:** connect or disconnect one mid-break, if the executing Mac has only one.
- **Light/Dark screenshot review:** the pill, toast, Breaks tab and menu items. The user reviews the PNGs from Tasks 9, 11 and 12.
- **Strict-mode feel:** does holding Esc for 3 s feel discoverable and safe? Is 3 s right?
- **VoiceOver:** listen for "Eye break, 20 seconds".
- **Force Quit:** check ⌥⌘Esc above the overlay (S6) if no agent can drive the keyboard.
- **Synthetic keys:** Esc and hold-Esc in Task 9, if the terminal has no Accessibility permission for synthetic keys.

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `apps/macos/RalloTests/AttentionContractTests.swift` | create | Task 1: plan 1's FFI and `CoreClient` behaviour as plan 2 relies on it |
| `docs/decisions/0022-eye-breaks.md` | modify | Task 2: `## Verified` (S6 results) |
| `crates/rallo-core/src/preferences/mod.rs` | modify | `EyeBreakSettings`, validation, `eye_break_settings` / `set_eye_break_settings` |
| `crates/rallo-core/tests/eye_break_settings.rs` | create | Rust round trip, defaults, rejections, revision |
| `crates/rallo-ffi/src/types.rs`, `crates/rallo-ffi/src/lib.rs` | modify | the UniFFI record and the two store methods |
| `apps/macos/Rallo/Core/CoreClient.swift` | modify | `eyeBreakSettings()` / `setEyeBreakSettings(_:)` |
| `apps/macos/RalloTests/EyeBreakSettingsFFITests.swift` | create | the bridge and `CoreClient` round trips |
| `apps/macos/Rallo/EyeBreak/EyeBreakPlanner.swift` | create | the pure state machine, `Settings` from the preference, the scratch override |
| `apps/macos/Rallo/EyeBreak/EyeBreakEffects.swift` | create | pure: effects of a phase change, menu/pill/toast text, pause end times, main-screen choice |
| `apps/macos/RalloTests/EyeBreakPlannerTests.swift`, `EyeBreakEffectsTests.swift` | create | Tasks 6–7 tests |
| `apps/macos/project.yml` | modify | `RalloTests` sources: the two pure files |
| `apps/macos/Rallo/EyeBreak/EyeBreakOverlay.swift` | create | per-screen black windows, the main screen's SwiftUI content, Esc / hold-Esc |
| `apps/macos/Rallo/EyeBreak/EyeBreakPill.swift` | create | the warning pill panel and the "Eyes rested" toast panel |
| `apps/macos/Rallo/Pet/PetRenderer.swift`, `Pet/PetPanel.swift` | modify | `hold(_:)`: a pose held over the reducer's |
| `apps/macos/Rallo/EyeBreak/EyeBreakController.swift` | create | timer, system observers, quiet signals, performs effects, records/restores the frontmost app |
| `apps/macos/Rallo/App/AppCoordinator.swift` | modify | create/start the controller, load settings, wire the plan-1 seam, menu and Settings closures |
| `apps/macos/Rallo/App/StatusMenuController.swift` | modify | status line, Take a Break Now, Pause submenu, Turn On Eye Breaks |
| `apps/macos/RalloTests/StatusMenuEyeBreakTests.swift` | create | menu items and actions |
| `apps/macos/Rallo/Settings/SettingsView.swift`, `SettingsModel.swift` | modify | `SettingsTab.breaks` and `BreaksTab` |

## Scratch click-through harness (used by Tasks 9, 11, 12, 13)

Nothing here lives in the repo. The harness:
- builds the Release app into `build/DerivedData.noindex` (never installs);
- seeds a throwaway data dir through the scratch build's own embedded CLI, with eye breaks and the pet turned on;
- launches the scratch binary directly, so that `RALLO_EYE_BREAK_SECONDS` reaches it, in a chosen appearance (`--demo-appearance` and `--demo-open` are honoured only for scratch instances);
- screenshots every window of that instance.

Run it from the repo root.

- [ ] **Harness step 1: write the window lister and the harness**

```bash
mkdir -p /tmp/rallo-eye-breaks/shots
cat > /tmp/rallo-eye-breaks/windows.swift <<'SWIFT'
import CoreGraphics
// One line per on-screen window of a pid: id, layer, name.
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    print(window[kCGWindowNumber as String] ?? 0, window[kCGWindowLayer as String] ?? 0, window[kCGWindowName as String] as? String ?? "-")
}
SWIFT
swiftc -O -o /tmp/rallo-eye-breaks/windows /tmp/rallo-eye-breaks/windows.swift

cat > /tmp/rallo-eye-breaks/harness.sh <<'EOF'
# source from the repo root:  source /tmp/rallo-eye-breaks/harness.sh
export H_DIR=/tmp/rallo-eye-breaks
export H_APP="$PWD/build/DerivedData.noindex/Build/Products/Release/Rallo.app"
export H_CLI="$H_APP/Contents/Helpers/rallo"
export RALLO_DATA_DIR="$H_DIR/data"

h_kill() {
  pkill -f -- "--data-dir $H_DIR/data" 2>/dev/null || return 0
  sleep 1
  pkill -9 -f -- "--data-dir $H_DIR/data" 2>/dev/null || true
}
# Unregister the scratch build so notification clicks never reach it (repo CLAUDE.md).
h_stop() {
  h_kill
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$H_APP" 2>/dev/null || true
}

# h_seed [strict] : fresh data dir, pet visible, eye breaks on (strict: allow_skip false)
h_seed() {
  h_stop; rm -rf "$H_DIR/data"; mkdir -p "$H_DIR/data"
  "$H_CLI" note "Eye-break harness" >/dev/null
  h_kill
  local skip=true; [ "${1:-}" = strict ] && skip=false
  sqlite3 "$H_DIR/data/rallo.sqlite3" "INSERT OR REPLACE INTO preferences (key, value, revision, updated_at_ms) VALUES
    ('pet.visibility', '\"visible\"', 1, 0),
    ('eye_breaks.settings', '{\"enabled\":true,\"interval_minutes\":20,\"length_seconds\":20,\"warn_seconds\":10,\"allow_skip\":$skip,\"hold_on_call\":true}', 1, 0);"
}

# h_launch light|dark [demo-open] : the warning comes ${H_SECONDS:-40}-10 s after launch
h_launch() {
  h_stop
  RALLO_EYE_BREAK_SECONDS="${H_SECONDS:-40}" nohup "$H_APP/Contents/MacOS/Rallo" --background \
    --data-dir "$H_DIR/data" --demo-appearance "$1" ${2:+--demo-open "$2"} >"$H_DIR/app.log" 2>&1 &
  sleep 5
}

# h_shot name : one PNG per on-screen window of the instance (pill, overlay, toast, menu, Settings)
h_shot() {
  local pid; pid="$(pgrep -f -- "--data-dir $H_DIR/data" | head -1)"
  [ -n "$pid" ] || { echo "no scratch instance running" >&2; return 1; }
  "$H_DIR/windows" "$pid" | while read -r id layer name; do
    screencapture -x -l "$id" "$H_DIR/shots/$1-$id.png"
    echo "$H_DIR/shots/$1-$id.png  (window '$name', layer $layer)"
  done
}

# h_front : the frontmost app's name (no permission needed)
h_front() { lsappinfo info -only name "$(lsappinfo front)"; }

# h_events : the instance's diagnostics, newest last
h_events() { tail -n "${1:-20}" "$H_DIR/data/diagnostics/events.jsonl"; }

h_clean() { h_stop; rm -rf "$H_DIR"; }
EOF
```

`h_seed` writes the database file directly: `rallo.sqlite3` is `DATABASE_FILE` in `crates/rallo-core/src/storage/database.rs:13`.

- [ ] **Harness step 2: how a UI task uses it**

```bash
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
scripts/build-macos.sh                 # builds into build/DerivedData.noindex; NO --install
source /tmp/rallo-eye-breaks/harness.sh
h_seed && h_launch dark                # warning at ~30 s, break at ~40 s, back at ~60 s
sleep 32; h_shot dark-pill
sleep 10; h_shot dark-overlay
h_stop; h_seed; h_launch light; sleep 32; h_shot light-pill
h_clean
```

`screencapture -l` needs Screen Recording permission for the terminal running it. View every PNG with the Read tool.

---

### Task 1: Pin the plan-1 API this plan consumes (compile and behaviour check)

**Files:**
- Create: `apps/macos/RalloTests/AttentionContractTests.swift`
- Throwaway (never committed): `apps/macos/Rallo/EyeBreak/ContractProbe.swift`

**Interfaces:**
- Consumes: the contract above (plan 1's part).
- Produces: nothing in production code.
- A failure here means plan 1 differs from the contract. Later tasks must not proceed.

- [ ] **Step 1: Write the contract test**

```swift
import XCTest

/// Plan 1's API (0021 §10, the cross-plan contract) as plan 2 relies on it.
/// This file creates no production code.
final class AttentionContractTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-attention-contract-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testAlertSettingsRecordAndDefaults() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let defaults = try store.alertSettings()
        XCTAssertEqual(defaults, AlertSettings(summon: true, sound: .ralloChime, nag: true, nagIntervalMinutes: 2,
                                               nagMaxRounds: 5, glow: false, agents: true))
        _ = [AlertSound.ralloChime, .bambooKnock, .gentleBell, .system, .none]
    }

    func testAlertSettingsRoundTripAndOnlyReportChanges() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        var settings = try store.alertSettings()
        settings.glow = true
        XCTAssertTrue(try store.setAlertSettings(settings: settings))
        XCTAssertFalse(try store.setAlertSettings(settings: settings))
        XCTAssertEqual(try RalloStore.open(dataDir: dataDir.path).alertSettings().glow, true)
    }

    func testAlertSettingsRejectAValueOutsideTheChoices() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        var settings = try store.alertSettings()
        settings.nagIntervalMinutes = 3
        XCTAssertThrowsError(try store.setAlertSettings(settings: settings)) { error in
            guard case RalloError.InvalidInput = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testCoreClientWrappers() async throws {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        var settings = try await core.alertSettings()
        settings.summon = false
        let changed = try await core.setAlertSettings(settings)
        XCTAssertTrue(changed)
        let reread = try await core.alertSettings()
        XCTAssertFalse(reread.summon)
    }
}
```

- [ ] **Step 2: Write the throwaway compile probe for the AppKit side**

`QuietSignals` and `AttentionCoordinator` may not be in the test target, so the app target checks them.

```swift
// apps/macos/Rallo/EyeBreak/ContractProbe.swift — THROWAWAY (plan 2, Task 1). Delete before committing.
import AppKit

@MainActor
private func eyeBreakContractProbe(_ quiet: QuietSignals, _ attention: AttentionCoordinator) {
    quiet.isVoiceTypingListening = { false }
    quiet.requestFocusAuthorization()
    let _: Bool = quiet.focusOn
    let _: Bool = quiet.cameraOrMicInUse
    let _: TimeInterval = QuietSignals.idleSeconds()
    attention.eyeBreakActive = { false }
    attention.eyeBreakEnded()
    let _: Bool = attention.isBubbleVisible
    attention.onBubbleVisibilityChanged = { (_: Bool) in }
}
```

- [ ] **Step 3: Build the app, run the test, check the owned properties**

Run:
```bash
cd /Users/eyakub/Desktop/Rallo && export PATH=/opt/homebrew/opt/rustup/bin:$PATH
scripts/build-macos.sh
(cd apps/macos && xcodegen generate --quiet) && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex -only-testing:RalloTests/AttentionContractTests test -quiet
grep -nE "let quietSignals(: QuietSignals)? *=|let quietSignals: QuietSignals|let attention(: AttentionCoordinator)? *=|let attention: AttentionCoordinator" apps/macos/Rallo/App/AppCoordinator.swift
```

Expected:
- the build succeeds;
- 4 tests pass;
- `grep` prints one line for `quietSignals` and one for `attention`.

If anything fails, STOP. Report the exact compiler error, assertion or missing property to the orchestrator.

- [ ] **Step 4: Delete the probe and commit the test**

```bash
rm apps/macos/Rallo/EyeBreak/ContractProbe.swift
rmdir apps/macos/Rallo/EyeBreak 2>/dev/null || true
git add apps/macos/RalloTests/AttentionContractTests.swift
git commit -m "test(app): pin the plan-1 attention API eye breaks consume"
```

---

### Task 2: Spike S6 (overlay level, Esc, focus restore, Force Quit)

**Files:**
- Throwaway (never committed): `/tmp/rallo-s6/` (a tiny `.app`)
- Modify: `docs/decisions/0022-eye-breaks.md`: append `## Verified`

**Interfaces:**
- Produces: the S6 verdict that Task 10 reads ("Only if S6 failed"). Passing means `EyeBreakOverlay.windowLevel = .screenSaver` stays.

S6 has four questions, recorded as yes/no:
1. Does a `.screenSaver`-level window cover another app's full-screen Space and the menu bar?
2. Does Esc reach the key overlay after `NSApp.activate()`?
3. Does re-activating the recorded app restore focus?
4. Is ⌥⌘Esc (Force Quit) still reachable?

A bundled accessory app is used, because activation rules differ for a bare executable.

- [ ] **Step 1: Write and build the probe app**

```bash
mkdir -p /tmp/rallo-s6/Probe.app/Contents/MacOS
cat > /tmp/rallo-s6/probe.swift <<'SWIFT'
// THROWAWAY — 0022 spike S6. Logs to /tmp/rallo-s6/probe.log.
import AppKit

let logURL = URL(fileURLWithPath: "/tmp/rallo-s6/probe.log")
func log(_ line: String) {
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
    else { try? data.write(to: logURL) }
}

final class Overlay: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { log("keyDown \(event.keyCode) repeat=\(event.isARepeat)") }
    override func keyUp(with event: NSEvent) { log("keyUp \(event.keyCode)") }
}

let arguments = CommandLine.arguments.dropFirst()
let level = NSWindow.Level(rawValue: arguments.first.flatMap(Int.init) ?? NSWindow.Level.screenSaver.rawValue)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let recorded = NSWorkspace.shared.frontmostApplication
log("level=\(level.rawValue) recorded=\(recorded?.bundleIdentifier ?? "nil")")
var windows: [Overlay] = []
for screen in NSScreen.screens {
    let window = Overlay(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = level
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.backgroundColor = .black
    window.isOpaque = true
    window.isReleasedWhenClosed = false
    window.setFrame(screen.frame, display: true)
    window.orderFrontRegardless()
    windows.append(window)
}
app.activate()
windows.first?.makeKeyAndOrderFront(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    log("active=\(app.isActive) key=\(windows.first?.isKeyWindow ?? false) screens=\(NSScreen.screens.count)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    windows.forEach { $0.orderOut(nil) }
    log("restore \(recorded?.bundleIdentifier ?? "nil"): \(recorded?.activate() ?? false)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        log("frontmost after: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        exit(0)
    }
}
app.run()
SWIFT
swiftc -O -o /tmp/rallo-s6/Probe.app/Contents/MacOS/probe /tmp/rallo-s6/probe.swift
cat > /tmp/rallo-s6/Probe.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.razlio.rallo.s6probe</string>
  <key>CFBundleExecutable</key><string>probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
```

Expected: `swiftc` exits 0.

- [ ] **Step 2: Run it over a full-screen app**

1. Open TextEdit with a new document. Type a word. Make it full screen with ⌃⌘F, so it gets its own Space.
2. In a Terminal on another Space, run:
   ```bash
   rm -f /tmp/rallo-s6/probe.log; sleep 10; open -n /tmp/rallo-s6/Probe.app
   ```
   Then switch to TextEdit's full-screen Space within 10 s.
3. While it's black (20 s), do these in order:
   - Move the pointer to the top edge. Does the menu bar appear **above** the black? It should not.
   - Run `screencapture -x /tmp/rallo-s6/over-fullscreen.png` from a second Terminal tab: `sleep 12; screencapture -x /tmp/rallo-s6/over-fullscreen.png`, started before step 2.
   - Press Esc once, then hold Esc about 1 s.
   - Press ⌥⌘Esc. Is the Force Quit window visible above the black? Press Esc to close it.
4. After it clears, type a letter. Does it land in TextEdit?
5. Run `cat /tmp/rallo-s6/probe.log`.

Expected log:
- `active=true key=true`;
- `keyDown 53` lines, including `repeat=true` while held;
- `restore com.apple.TextEdit: true`;
- `frontmost after: com.apple.TextEdit`.

Also check that `over-fullscreen.png` (open it with the Read tool) is all black.

If the agent can't switch Spaces or press keys, do this step together with the user.

- [ ] **Step 3: Only if a check failed, retry at the next level down**

```bash
rm -f /tmp/rallo-s6/probe.log; sleep 10; open -n /tmp/rallo-s6/Probe.app --args 101   # NSWindow.Level.popUpMenu
```

Repeat Step 2's checks. Keep the highest level at which the menu bar is covered and Force Quit is visible.

- [ ] **Step 4: Record the result in 0022**

Append to `docs/decisions/0022-eye-breaks.md`. Fill in what you observed, and write `no` honestly:

```markdown

## Verified

- **S6 (YYYY-MM-DD, macOS <`sw_vers -productVersion`>, <N> display(s)):**
  - A `.screenSaver` (1000) borderless window with `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` covered TextEdit's full-screen Space: yes/no.
  - It covered the menu bar: yes/no.
  - Esc reached the key overlay after `NSApp.activate()`: yes/no (`active=…`, `key=…` in the probe log).
  - Re-activating the recorded app restored focus, and a typed letter landed in TextEdit: yes/no.
  - ⌥⌘Esc showed Force Quit above the overlay: yes/no.
  - Level kept: `.screenSaver` (or `.popUpMenu`, 101, if Step 3 ran).
```

Replace every `<…>` and `yes/no`. If Step 3 ran, add one line with its results.

- [ ] **Step 5: Clean up and commit**

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /tmp/rallo-s6/Probe.app
rm -rf /tmp/rallo-s6
git add docs/decisions/0022-eye-breaks.md
git commit -m "docs(0022): record spike S6"
```

---

### Task 3: `EyeBreakSettings` in the Rust store

**Files:**
- Modify: `crates/rallo-core/src/preferences/mod.rs` (constants at :9-14, imports at :3-7, the `impl Store` block ending :120)
- Create: `crates/rallo-core/tests/eye_break_settings.rs`

**Interfaces:**
- Consumes: `Store::read_preference` / `write_preference` (`preferences/mod.rs:31-63`), `CoreError::invalid` (`shared/errors.rs:146`), `ErrorCode::InvalidInput`.
- Produces: `rallo_core::preferences::EyeBreakSettings` with `Default`, plus `Store::eye_break_settings(&self) -> CoreResult<EyeBreakSettings>` and `Store::set_eye_break_settings(&mut self, EyeBreakSettings) -> CoreResult<bool>`, exactly as the contract says.

Plan 1's `AlertSettings` follows the same pattern:
- a `const` key;
- a `#[serde(default)]` struct with a hand-written `Default`;
- a private `validate()`;
- a getter that falls back to `Default` when the value is unset, unreadable or out of range;
- a setter that validates, then calls `write_preference`.

If plan 1 already added `CoreError`/`ErrorCode` to the imports, leave them.

- [ ] **Step 1: Write the failing tests**

```rust
//! `eye_breaks.settings` (0022 §9): defaults, round trip, rejections, revision.

mod support;

use rallo_core::ErrorCode;
use rallo_core::preferences::EyeBreakSettings;

#[test]
fn unset_means_the_defaults_and_eye_breaks_are_off() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let settings = store.eye_break_settings().unwrap();
    assert_eq!(settings, EyeBreakSettings::default());
    assert_eq!(
        settings,
        EyeBreakSettings {
            enabled: false,
            interval_minutes: 20,
            length_seconds: 20,
            warn_seconds: 10,
            allow_skip: true,
            hold_on_call: true,
        }
    );
}

#[test]
fn settings_round_trip_and_survive_reopen() {
    let temp = tempfile::tempdir().unwrap();
    let wanted = EyeBreakSettings {
        enabled: true,
        interval_minutes: 45,
        length_seconds: 60,
        warn_seconds: 0,
        allow_skip: false,
        hold_on_call: false,
    };
    {
        let mut store = support::open(temp.path());
        assert!(store.set_eye_break_settings(wanted.clone()).unwrap());
    }
    assert_eq!(support::open(temp.path()).eye_break_settings().unwrap(), wanted);
}

#[test]
fn an_identical_save_does_not_bump_the_revision() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let on = EyeBreakSettings { enabled: true, ..EyeBreakSettings::default() };
    assert!(store.set_eye_break_settings(on.clone()).unwrap());
    let revision = store.change_revision().unwrap();
    assert!(!store.set_eye_break_settings(on).unwrap());
    assert_eq!(store.change_revision().unwrap(), revision);
}

#[test]
fn values_outside_the_choices_are_rejected_and_nothing_is_saved() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let base = EyeBreakSettings { enabled: true, ..EyeBreakSettings::default() };
    let bad = [
        EyeBreakSettings { interval_minutes: 25, ..base.clone() },
        EyeBreakSettings { interval_minutes: 0, ..base.clone() },
        EyeBreakSettings { length_seconds: 15, ..base.clone() },
        EyeBreakSettings { warn_seconds: 3, ..base.clone() },
    ];
    for settings in bad {
        let error = store.set_eye_break_settings(settings.clone()).unwrap_err();
        assert_eq!(error.code(), ErrorCode::InvalidInput, "{settings:?}");
    }
    assert_eq!(store.eye_break_settings().unwrap(), EyeBreakSettings::default());
    assert_eq!(store.change_revision().unwrap(), 0);
}

#[test]
fn an_unreadable_partial_or_out_of_range_stored_value_reads_safely() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let write = |raw: &str| {
        support::raw_connection(temp.path())
            .execute(
                "INSERT OR REPLACE INTO preferences (key, value, revision, updated_at_ms)
                 VALUES ('eye_breaks.settings', ?1, 1, 0)",
                [raw],
            )
            .unwrap();
    };
    write("not json");
    assert_eq!(store.eye_break_settings().unwrap(), EyeBreakSettings::default());
    write(r#"{"enabled":true,"interval_minutes":7}"#);
    assert_eq!(store.eye_break_settings().unwrap(), EyeBreakSettings::default());
    // A field this build doesn't know, and fields it lacks, both read through serde's defaults.
    write(r#"{"enabled":true,"future_field":1}"#);
    assert_eq!(
        store.eye_break_settings().unwrap(),
        EyeBreakSettings { enabled: true, ..EyeBreakSettings::default() }
    );
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `export PATH=/opt/homebrew/opt/rustup/bin:$PATH && cargo test -p rallo-core --test eye_break_settings`
Expected: FAIL to compile with "unresolved import `rallo_core::preferences::EyeBreakSettings`".

- [ ] **Step 3: Implement**

In `crates/rallo-core/src/preferences/mod.rs`, change the errors import at :6 to:
```rust
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
```

Add after `AGENTS_NOTIFY_LONG_WAIT` (:14):
```rust
const EYE_BREAKS_SETTINGS: &str = "eye_breaks.settings";
```

Add after `PetPlacement` (:28):
```rust
/// 20-20-20 eye breaks (0022 §9). Off by default.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct EyeBreakSettings {
    pub enabled: bool,
    pub interval_minutes: u8,
    pub length_seconds: u8,
    /// 0 means no warning: the break starts at once.
    pub warn_seconds: u8,
    pub allow_skip: bool,
    pub hold_on_call: bool,
}

impl Default for EyeBreakSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            interval_minutes: 20,
            length_seconds: 20,
            warn_seconds: 10,
            allow_skip: true,
            hold_on_call: true,
        }
    }
}

impl EyeBreakSettings {
    pub const INTERVAL_MINUTES: [u8; 6] = [10, 15, 20, 30, 45, 60];
    pub const LENGTH_SECONDS: [u8; 4] = [10, 20, 30, 60];
    pub const WARN_SECONDS: [u8; 4] = [0, 5, 10, 30];

    fn validate(&self) -> CoreResult<()> {
        let check = |value: u8, allowed: &[u8], what: &str| {
            if allowed.contains(&value) {
                Ok(())
            } else {
                Err(CoreError::invalid(ErrorCode::InvalidInput, format!("eye break {what} must be one of {allowed:?}")))
            }
        };
        check(self.interval_minutes, &Self::INTERVAL_MINUTES, "interval (minutes)")?;
        check(self.length_seconds, &Self::LENGTH_SECONDS, "length (seconds)")?;
        check(self.warn_seconds, &Self::WARN_SECONDS, "warning (seconds)")
    }
}
```

Add at the end of `impl Store` (after `set_agents_notify_long_wait`, :120):
```rust
    /// 0022 §9. Unset, unreadable or out-of-range stored values read as the defaults.
    pub fn eye_break_settings(&self) -> CoreResult<EyeBreakSettings> {
        Ok(self
            .read_preference::<EyeBreakSettings>(EYE_BREAKS_SETTINGS)?
            .filter(|settings| settings.validate().is_ok())
            .unwrap_or_default())
    }

    /// Rejects a value outside the listed choices (the FFI is a trust boundary).
    pub fn set_eye_break_settings(&mut self, settings: EyeBreakSettings) -> CoreResult<bool> {
        settings.validate()?;
        self.write_preference(EYE_BREAKS_SETTINGS, Some(&settings))
    }
```

- [ ] **Step 4: Run the tests to see them pass, then the whole workspace**

Run: `cargo test -p rallo-core --test eye_break_settings && cargo test --workspace`
Expected: 5 passed, then the workspace passes with no failures.

- [ ] **Step 5: Commit**

```bash
git add crates/rallo-core/src/preferences/mod.rs crates/rallo-core/tests/eye_break_settings.rs
git commit -m "feat(core): eye-break settings preference"
```

---

### Task 4: FFI record, store methods and `CoreClient` wrappers

**Files:**
- Modify: `crates/rallo-ffi/src/types.rs` (after `PetPlacement`'s `From` impls, :314-322)
- Modify: `crates/rallo-ffi/src/lib.rs` (after `set_pet_placement`, around :580)
- Modify: `apps/macos/Rallo/Core/CoreClient.swift` (after `setPetVisibility`, :228-231)
- Create: `apps/macos/RalloTests/EyeBreakSettingsFFITests.swift`

**Interfaces:**
- Consumes: Task 3.
- Produces:
  - Swift `EyeBreakSettings(enabled:intervalMinutes:lengthSeconds:warnSeconds:allowSkip:holdOnCall:)`, with `UInt8` fields and `var` properties;
  - `RalloStore.eyeBreakSettings()` and `RalloStore.setEyeBreakSettings(settings:)`;
  - `CoreClient.eyeBreakSettings() async throws -> EyeBreakSettings`;
  - `@discardableResult CoreClient.setEyeBreakSettings(_:) async throws -> Bool`.

- [ ] **Step 1: Write the failing Swift test**

```swift
import XCTest

/// `eye_breaks.settings` through UniFFI and `CoreClient` (0022 §9), on a temp store.
final class EyeBreakSettingsFFITests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-eye-breaks-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testDefaultsRoundTripAndChangeReporting() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        XCTAssertEqual(try store.eyeBreakSettings(),
                       EyeBreakSettings(enabled: false, intervalMinutes: 20, lengthSeconds: 20, warnSeconds: 10,
                                        allowSkip: true, holdOnCall: true))
        var settings = try store.eyeBreakSettings()
        settings.enabled = true
        settings.warnSeconds = 0
        XCTAssertTrue(try store.setEyeBreakSettings(settings: settings))
        XCTAssertFalse(try store.setEyeBreakSettings(settings: settings))
        XCTAssertEqual(try RalloStore.open(dataDir: dataDir.path).eyeBreakSettings(), settings)
    }

    func testAValueOutsideTheChoicesIsInvalidInput() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        var settings = try store.eyeBreakSettings()
        settings.intervalMinutes = 25
        XCTAssertThrowsError(try store.setEyeBreakSettings(settings: settings)) { error in
            guard case let RalloError.InvalidInput(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "INVALID_INPUT")
        }
    }

    func testCoreClientWrappers() async throws {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        var settings = try await core.eyeBreakSettings()
        settings.enabled = true
        let changed = try await core.setEyeBreakSettings(settings)
        XCTAssertTrue(changed)
        let reread = try await core.eyeBreakSettings()
        XCTAssertTrue(reread.enabled)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run:
```bash
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
(cd apps/macos && xcodegen generate --quiet) && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex -only-testing:RalloTests/EyeBreakSettingsFFITests test -quiet
```
Expected: build FAILS with "cannot find 'EyeBreakSettings' in scope".

- [ ] **Step 3: Implement the FFI record and methods**

In `crates/rallo-ffi/src/types.rs`, after `impl From<PetPlacement> for preferences::PetPlacement`:
```rust
/// 0022 §9, mirrored for Swift.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EyeBreakSettings {
    pub enabled: bool,
    pub interval_minutes: u8,
    pub length_seconds: u8,
    pub warn_seconds: u8,
    pub allow_skip: bool,
    pub hold_on_call: bool,
}

impl From<preferences::EyeBreakSettings> for EyeBreakSettings {
    fn from(value: preferences::EyeBreakSettings) -> Self {
        Self {
            enabled: value.enabled,
            interval_minutes: value.interval_minutes,
            length_seconds: value.length_seconds,
            warn_seconds: value.warn_seconds,
            allow_skip: value.allow_skip,
            hold_on_call: value.hold_on_call,
        }
    }
}

impl From<EyeBreakSettings> for preferences::EyeBreakSettings {
    fn from(value: EyeBreakSettings) -> Self {
        Self {
            enabled: value.enabled,
            interval_minutes: value.interval_minutes,
            length_seconds: value.length_seconds,
            warn_seconds: value.warn_seconds,
            allow_skip: value.allow_skip,
            hold_on_call: value.hold_on_call,
        }
    }
}
```

In `crates/rallo-ffi/src/lib.rs`, after `set_pet_placement`, in the same exported `impl`:
```rust
    pub fn eye_break_settings(&self) -> Result<EyeBreakSettings, RalloError> {
        Ok(self.store().eye_break_settings()?.into())
    }

    pub fn set_eye_break_settings(&self, settings: EyeBreakSettings) -> Result<bool, RalloError> {
        Ok(self.store().set_eye_break_settings(settings.into())?)
    }
```

In `apps/macos/Rallo/Core/CoreClient.swift`, after `setPetVisibility(_:)`:
```swift
    func eyeBreakSettings() async throws -> EyeBreakSettings {
        try await worker.perform { try $0.eyeBreakSettings() }
    }

    @discardableResult
    func setEyeBreakSettings(_ settings: EyeBreakSettings) async throws -> Bool {
        try await worker.perform { try $0.setEyeBreakSettings(settings: settings) }
    }
```

- [ ] **Step 4: Run the test and the Rust workspace**

Run the Step 2 command, then `cargo test --workspace`.
Expected: 3 tests pass; Rust has no failures.

- [ ] **Step 5: Commit**

```bash
git add crates/rallo-ffi/src/types.rs crates/rallo-ffi/src/lib.rs apps/macos/Rallo/Core/CoreClient.swift apps/macos/RalloTests/EyeBreakSettingsFFITests.swift
git commit -m "feat(ffi): eye-break settings for the app"
```

---

### Task 5: `EyeBreakPlanner`, the pure state machine

**Files:**
- Create: `apps/macos/Rallo/EyeBreak/EyeBreakPlanner.swift`
- Create: `apps/macos/RalloTests/EyeBreakPlannerTests.swift`
- Modify: `apps/macos/project.yml` (RalloTests `sources`: add `- path: Rallo/EyeBreak/EyeBreakPlanner.swift` after `Rallo/App/StatusMenuController.swift`)

**Interfaces:**
- Consumes: `EyeBreakSettings` (Task 4).
- Produces (all used by Tasks 6, 8, 9, 11, 12):

```swift
struct EyeBreakPlanner: Equatable {
    struct Settings: Equatable { var enabled, interval, length, warning, allowSkip, holdOnCall }   // seconds
    enum Phase: Equatable { case off, counting, away, paused(until: Date), held, warning(until: Date), breaking(until: Date) }
    struct Hold: Equatable { var callActive = false; var bubbleVisible = false }
    enum MenuStatus: Equatable { case off, due(in: TimeInterval), paused(until: Date), waiting }
    static let naturalBreak, postponement, escHold, tickCap: TimeInterval   // 300, 300, 3, 60
    static let tips: [String]
    private(set) var settings: Settings, phase: Phase, cycleStart: Date, postponedDue: Date?, awaitingReturn: Bool, breaksTaken: Int
    init(settings: Settings, now: Date)
    var tip: String { get }
    var breakDue: Date { get }
    mutating func apply(_ new: Settings, now: Date)
    mutating func setScreenAvailable(_ available: Bool, now: Date)
    mutating func tick(now: Date, idle: TimeInterval, hold: Hold)
    mutating func startNow(_ now: Date)
    @discardableResult mutating func postpone(_ now: Date) -> Bool
    @discardableResult mutating func skip(_ now: Date) -> Bool
    mutating func escHeld(_ now: Date)
    mutating func pause(until: Date, now: Date)
    func nextCheck(now: Date) -> Date?
    func menuStatus(now: Date) -> MenuStatus
}
extension EyeBreakPlanner.Settings {
    init(_ stored: EyeBreakSettings, intervalOverride: TimeInterval? = nil)
    static func intervalOverride(environment: [String: String], isScratch: Bool) -> TimeInterval?
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

/// The 20-20-20 cycle (0022 §2-§7) as a pure value, on an injected clock.
final class EyeBreakPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let free = EyeBreakPlanner.Hold()
    private let onCall = EyeBreakPlanner.Hold(callActive: true)
    private let bubble = EyeBreakPlanner.Hold(bubbleVisible: true)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Enabled, 20 min / 20 s / 10 s warning, skipping allowed, hold on call.
    private func planner(_ edit: (inout EyeBreakPlanner.Settings) -> Void = { _ in }) -> EyeBreakPlanner {
        var settings = EyeBreakPlanner.Settings(enabled: true, interval: 1200, length: 20, warning: 10,
                                                allowSkip: true, holdOnCall: true)
        edit(&settings)
        return EyeBreakPlanner(settings: settings, now: t0)
    }

    // MARK: Counting

    func testOffByDefaultNothingHappens() {
        var p = EyeBreakPlanner(settings: .init(), now: t0)
        XCTAssertEqual(p.phase, .off)
        XCTAssertNil(p.nextCheck(now: t0))
        p.tick(now: at(5000), idle: 0, hold: free)
        p.startNow(at(5000))
        XCTAssertEqual(p.phase, .off)
    }

    func testCountingReachesTheWarningThenTheBreakThenANewCycle() {
        var p = planner()
        XCTAssertEqual(p.nextCheck(now: t0), at(60), "never more than a minute between ticks")
        XCTAssertEqual(p.nextCheck(now: at(1170)), at(1190))
        p.tick(now: at(1189), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        p.tick(now: at(1190), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1200)))
        XCTAssertEqual(p.nextCheck(now: at(1190)), at(1200))
        p.tick(now: at(1200), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .breaking(until: at(1220)))
        p.tick(now: at(1220), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.cycleStart, at(1220))
        XCTAssertEqual(p.breaksTaken, 1)
        XCTAssertEqual(p.tip, "Blink slowly", "the tip rotates each break")
    }

    func testIdleFiveMinutesRestartsTheCycleWhenTheUserIsBack() {
        var p = planner()
        p.tick(now: at(600), idle: 300, hold: free)
        XCTAssertTrue(p.awaitingReturn)
        p.tick(now: at(1190), idle: 890, hold: free)
        XCTAssertEqual(p.phase, .counting, "no warning while the user is away from the keyboard")
        p.tick(now: at(1250), idle: 20, hold: free)
        XCTAssertFalse(p.awaitingReturn)
        XCTAssertEqual(p.cycleStart, at(1230), "the cycle starts when input came back")
        XCTAssertEqual(p.breakDue, at(2430))
    }

    func testIdleUnderFiveMinutesDoesNotRestart() {
        var p = planner()
        p.tick(now: at(600), idle: 299, hold: free)
        XCTAssertFalse(p.awaitingReturn)
        p.tick(now: at(1190), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1200)))
    }

    func testLockOrSleepPausesAndUnlockStartsAFreshCycle() {
        let counting = planner()
        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: free)
        var breaking = planner()
        breaking.startNow(at(1190))
        for (name, start) in [("counting", counting), ("warning", warning), ("breaking", breaking)] {
            var p = start
            p.setScreenAvailable(false, now: at(1195))
            XCTAssertEqual(p.phase, .away, name)
            XCTAssertNil(p.nextCheck(now: at(1195)), name)
            p.tick(now: at(6000), idle: 0, hold: free)
            XCTAssertEqual(p.phase, .away, name)
            p.setScreenAvailable(true, now: at(6000))
            XCTAssertEqual(p.phase, .counting, name)
            XCTAssertEqual(p.breakDue, at(7200), "\(name): a full fresh cycle, never an instant break")
        }
    }

    func testWarningOffGoesStraightToTheBreak() {
        var p = planner { $0.warning = 0 }
        p.tick(now: at(1200), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .breaking(until: at(1220)))
    }

    // MARK: User actions

    func testStartNowBeginsTheBreakAtOnce() {
        var counting = planner()
        counting.startNow(at(100))
        XCTAssertEqual(counting.phase, .breaking(until: at(120)))

        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: free)
        warning.startNow(at(1192))
        XCTAssertEqual(warning.phase, .breaking(until: at(1212)))

        var paused = planner()
        paused.pause(until: at(3600), now: at(100))
        paused.startNow(at(200))
        XCTAssertEqual(paused.phase, .breaking(until: at(220)))

        var away = planner()
        away.setScreenAvailable(false, now: at(10))
        away.startNow(at(20))
        XCTAssertEqual(away.phase, .away)
    }

    func testPostponeBringsTheWarningBackInFiveMinutes() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: free)
        XCTAssertTrue(p.postpone(at(1195)))
        XCTAssertEqual(p.phase, .counting)
        p.tick(now: at(1494), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        p.tick(now: at(1495), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1505)))

        var breaking = planner()
        breaking.startNow(at(100))
        XCTAssertTrue(breaking.postpone(at(105)))
        XCTAssertEqual(breaking.phase, .counting)
        XCTAssertEqual(breaking.breakDue, at(415))
        XCTAssertEqual(breaking.breaksTaken, 0)
    }

    func testSkipCountsAsABreakTaken() {
        var p = planner()
        p.startNow(at(100))
        XCTAssertTrue(p.skip(at(103)))
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.breaksTaken, 1)
        XCTAssertEqual(p.breakDue, at(1303), "next in a full cycle")
    }

    func testStrictModeIgnoresSkipAndPostponeButAHeldEscEndsTheBreak() {
        var p = planner { $0.allowSkip = false }
        p.startNow(at(100))
        XCTAssertFalse(p.skip(at(101)), "a short Esc does nothing in strict mode")
        XCTAssertFalse(p.postpone(at(101)))
        XCTAssertEqual(p.phase, .breaking(until: at(120)))
        p.escHeld(at(104))
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.breaksTaken, 1)
    }

    func testTheCountdownAlwaysEndsTheBreak() {
        for hold in [free, onCall, bubble, EyeBreakPlanner.Hold(callActive: true, bubbleVisible: true)] {
            var p = planner { $0.allowSkip = false }
            p.startNow(at(100))
            p.tick(now: at(110), idle: 400, hold: hold)
            XCTAssertEqual(p.phase, .breaking(until: at(120)), "\(hold)")
            p.tick(now: at(120), idle: 400, hold: hold)
            XCTAssertEqual(p.phase, .counting, "\(hold)")
        }
    }

    // MARK: Holds

    func testACallHoldsTheBreakUntilItEnds() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .held)
        XCTAssertEqual(p.nextCheck(now: at(1190)), at(1250))
        p.tick(now: at(1250), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .held)
        p.tick(now: at(1310), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1320)), "the warning starts once the call is over")
    }

    func testACallStartingDuringTheWarningCancelsIt() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: free)
        p.tick(now: at(1195), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .held)
    }

    func testHoldOnCallOffIgnoresTheCall() {
        var p = planner { $0.holdOnCall = false }
        p.tick(now: at(1190), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .warning(until: at(1200)))
    }

    func testABubbleOnScreenHoldsTheBreakUntilItCloses() {
        var p = planner { $0.holdOnCall = false }
        p.tick(now: at(1190), idle: 0, hold: bubble)
        XCTAssertEqual(p.phase, .held)
        p.tick(now: at(1215), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1225)))
    }

    func testABubbleAppearingMidBreakNeitherEndsNorExtendsIt() {
        var p = planner()
        p.startNow(at(100))
        p.tick(now: at(110), idle: 0, hold: bubble)
        XCTAssertEqual(p.phase, .breaking(until: at(120)))
        XCTAssertEqual(p.nextCheck(now: at(110)), at(120))
    }

    func testIdleWhileHeldIsANaturalBreak() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: onCall)
        p.tick(now: at(1550), idle: 330, hold: onCall)
        XCTAssertEqual(p.phase, .counting)
        XCTAssertTrue(p.awaitingReturn)
    }

    // MARK: Pause, settings, clock

    func testPauseUntilATimeThenAFreshCycle() {
        var p = planner()
        p.pause(until: at(1800), now: at(100))
        XCTAssertEqual(p.phase, .paused(until: at(1800)))
        XCTAssertEqual(p.nextCheck(now: at(1790)), at(1800))
        p.tick(now: at(1799), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .paused(until: at(1800)))
        p.tick(now: at(1800), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.breakDue, at(3000))
    }

    func testChangingTheIntervalRestartsTheCycleAndOtherChangesDoNot() {
        var p = planner()
        var settings = p.settings
        settings.length = 60
        p.apply(settings, now: at(600))
        XCTAssertEqual(p.cycleStart, t0, "a new length doesn't restart the cycle")
        settings.interval = 1800
        p.apply(settings, now: at(700))
        XCTAssertEqual(p.cycleStart, at(700))
        XCTAssertEqual(p.breakDue, at(2500))
    }

    func testTurningOffEndsEverythingAndTurningOnStartsFresh() {
        var p = planner()
        p.startNow(at(100))
        var settings = p.settings
        settings.enabled = false
        p.apply(settings, now: at(105))
        XCTAssertEqual(p.phase, .off)
        settings.enabled = true
        p.apply(settings, now: at(500))
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.breakDue, at(1700))
    }

    func testALateTickNeverShortensTheWarningOrShowsAnExpiredBreak() {
        var late = planner()
        late.tick(now: at(1800), idle: 0, hold: free)      // timer 10 min late
        XCTAssertEqual(late.phase, .warning(until: at(1810)), "the full warning, not an instant break")
        late.tick(now: at(2400), idle: 0, hold: free)      // late again
        XCTAssertEqual(late.phase, .breaking(until: at(2420)), "a full break, never one that already ended")
        late.tick(now: at(9000), idle: 0, hold: free)
        XCTAssertEqual(late.phase, .counting)

        // The clock moved back by an hour mid-break: the break still lasts at most its length.
        var back = planner()
        back.startNow(at(5000))
        back.tick(now: at(1400), idle: 0, hold: free)
        XCTAssertEqual(back.phase, .counting)
        XCTAssertEqual(back.cycleStart, at(1400))
    }

    // MARK: Menu status, settings from the preference

    func testMenuStatus() {
        var p = planner()
        XCTAssertEqual(p.menuStatus(now: at(446)), .due(in: 754))
        p.tick(now: at(1190), idle: 0, hold: onCall)
        XCTAssertEqual(p.menuStatus(now: at(1190)), .waiting)
        p.pause(until: at(4000), now: at(1200))
        XCTAssertEqual(p.menuStatus(now: at(1200)), .paused(until: at(4000)))
        XCTAssertEqual(EyeBreakPlanner(settings: .init(), now: t0).menuStatus(now: t0), .off)
    }

    func testSettingsFromThePreferenceAndTheScratchOnlyOverride() {
        let stored = EyeBreakSettings(enabled: true, intervalMinutes: 30, lengthSeconds: 60, warnSeconds: 0,
                                      allowSkip: false, holdOnCall: false)
        XCTAssertEqual(EyeBreakPlanner.Settings(stored),
                       .init(enabled: true, interval: 1800, length: 60, warning: 0, allowSkip: false, holdOnCall: false))
        XCTAssertEqual(EyeBreakPlanner.Settings(stored, intervalOverride: 40).interval, 40)

        let env = ["RALLO_EYE_BREAK_SECONDS": "40"]
        XCTAssertEqual(EyeBreakPlanner.Settings.intervalOverride(environment: env, isScratch: true), 40)
        XCTAssertNil(EyeBreakPlanner.Settings.intervalOverride(environment: env, isScratch: false), "the installed app can't be sped up")
        XCTAssertNil(EyeBreakPlanner.Settings.intervalOverride(environment: ["RALLO_EYE_BREAK_SECONDS": "5"], isScratch: true))
        XCTAssertNil(EyeBreakPlanner.Settings.intervalOverride(environment: [:], isScratch: true))
    }
}
```

- [ ] **Step 2: Add the file to the test target and run to see it fail**

Add `- path: Rallo/EyeBreak/EyeBreakPlanner.swift` to the `RalloTests` sources in `apps/macos/project.yml`. Create the empty file `apps/macos/Rallo/EyeBreak/EyeBreakPlanner.swift` first (`touch` it), because XcodeGen needs the path. Then run:
```bash
(cd apps/macos && xcodegen generate --quiet) && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex -only-testing:RalloTests/EyeBreakPlannerTests test -quiet
```
Expected: build FAILS with "cannot find 'EyeBreakPlanner' in scope".

- [ ] **Step 3: Implement**

`apps/macos/Rallo/EyeBreak/EyeBreakPlanner.swift`:
```swift
import Foundation

/// The 20-20-20 eye-break cycle (0022) as a pure value: no timers, windows
/// or system calls. `EyeBreakController` feeds it the clock, idle time and
/// events, shows what `phase` says, and calls `tick` again at `nextCheck`.
struct EyeBreakPlanner: Equatable {
    /// In seconds; from the stored preference by `init(_:intervalOverride:)`.
    struct Settings: Equatable {
        var enabled = false
        var interval: TimeInterval = 20 * 60
        var length: TimeInterval = 20
        /// 0: no warning, the break starts at once (§3).
        var warning: TimeInterval = 10
        var allowSkip = true
        var holdOnCall = true
    }

    enum Phase: Equatable {
        case off
        /// Screen time counts toward the next break.
        case counting
        /// Locked, or the displays or the Mac asleep: nothing counts (§2).
        case away
        /// The menu's Pause Eye Breaks (§7).
        case paused(until: Date)
        /// Due, but a call or a reminder bubble holds it (§6).
        case held
        case warning(until: Date)
        case breaking(until: Date)
    }

    /// What can hold a due break (§6), read at every tick.
    struct Hold: Equatable {
        var callActive = false
        var bubbleVisible = false
    }

    /// The menu's status line (§7).
    enum MenuStatus: Equatable {
        case off
        case due(in: TimeInterval)
        case paused(until: Date)
        /// Held by a call or a reminder bubble.
        case waiting
    }

    static let naturalBreak: TimeInterval = 5 * 60
    static let postponement: TimeInterval = 5 * 60
    static let escHold: TimeInterval = 3
    /// The longest gap between ticks: idle time and calls are read once a minute (§2, §6).
    static let tickCap: TimeInterval = 60
    static let tips = ["Look at something far away", "Blink slowly", "Look out the window"]

    private(set) var settings: Settings
    private(set) var phase: Phase
    /// Where the current stretch of screen time started.
    private(set) var cycleStart: Date
    /// After +5 min (§4): the break is due here, not a full cycle after `cycleStart`.
    private(set) var postponedDue: Date?
    /// Idle for `naturalBreak` was seen; the cycle restarts when the user is back.
    private(set) var awaitingReturn = false
    private(set) var breaksTaken = 0

    init(settings: Settings, now: Date) {
        self.settings = settings
        phase = settings.enabled ? .counting : .off
        cycleStart = now
    }

    /// The tip for the current or next break; it rotates each break (§4).
    var tip: String { Self.tips[breaksTaken % Self.tips.count] }

    var breakDue: Date { postponedDue ?? cycleStart.addingTimeInterval(settings.interval) }

    /// Turning on or off, or a new interval, starts a fresh cycle (§2); other changes apply as they are.
    mutating func apply(_ new: Settings, now: Date) {
        let restart = new.enabled != settings.enabled || new.interval != settings.interval
        settings = new
        guard restart else { return }
        restartCycle(now)
        if !new.enabled {
            phase = .off
        } else if phase == .off || isActive {
            phase = .counting
        }
    }

    /// Lock, display sleep or system sleep (false), and the way back (true) (§2).
    mutating func setScreenAvailable(_ available: Bool, now: Date) {
        guard settings.enabled else { return }
        if !available {
            if case .paused = phase { return }
            phase = .away
        } else if phase == .away {
            restartCycle(now)
            phase = .counting
        }
    }

    /// The timer fired, at `nextCheck` or late. `idle` is seconds since the last input.
    mutating func tick(now: Date, idle: TimeInterval, hold: Hold) {
        if now < cycleStart { restartCycle(now) }  // the clock went back
        switch phase {
        case .off, .away:
            return
        case let .paused(until):
            guard now >= until else { return }
            restartCycle(now)
            phase = .counting
        case .counting, .held:
            if idle >= Self.naturalBreak {
                awaitingReturn = true
                phase = .counting
                return
            }
            if awaitingReturn {
                restartCycle(now.addingTimeInterval(-idle))
                return
            }
            guard phase == .held || now >= breakDue.addingTimeInterval(-settings.warning) else { return }
            if isHeld(hold) {
                phase = .held
            } else {
                beginWarning(now)
            }
        case let .warning(until):
            if isHeld(hold) {
                phase = .held
            } else if now >= until || until.timeIntervalSince(now) > settings.warning {
                beginBreak(now)
            }
        case let .breaking(until):
            if now >= until || until.timeIntervalSince(now) > settings.length { finishBreak(now) }
        }
    }

    /// Start now (pill) or Take a Break Now (menu): the break at once, no warning.
    mutating func startNow(_ now: Date) {
        switch phase {
        case .off, .away, .breaking: return
        default: beginBreak(now)
        }
    }

    /// +5 min (§4): the warning comes back in 5 minutes. False in strict mode.
    @discardableResult
    mutating func postpone(_ now: Date) -> Bool {
        guard settings.allowSkip, isWarningOrBreaking else { return false }
        postponedDue = now.addingTimeInterval(Self.postponement + settings.warning)
        phase = .counting
        return true
    }

    /// Skip (§4): counts as a break taken. False in strict mode.
    @discardableResult
    mutating func skip(_ now: Date) -> Bool {
        guard settings.allowSkip, isWarningOrBreaking else { return false }
        finishBreak(now)
        return true
    }

    /// Esc held for `escHold` seconds: always ends a break, in strict mode too (§4).
    mutating func escHeld(_ now: Date) {
        if case .breaking = phase { finishBreak(now) }
    }

    /// Pause Eye Breaks ▸ (§7). In memory only.
    mutating func pause(until: Date, now: Date) {
        guard settings.enabled, until > now else { return }
        phase = .paused(until: until)
    }

    /// When the controller must call `tick` next; nil while nothing changes by itself.
    func nextCheck(now: Date) -> Date? {
        let cap = now.addingTimeInterval(Self.tickCap)
        switch phase {
        case .off, .away:
            return nil
        case let .paused(until):
            return min(until, cap)
        case .held:
            return cap
        case .counting:
            if awaitingReturn { return cap }
            return min(max(breakDue.addingTimeInterval(-settings.warning), now), cap)
        case let .warning(until), let .breaking(until):
            return until
        }
    }

    func menuStatus(now: Date) -> MenuStatus {
        switch phase {
        case .off: return .off
        case let .paused(until): return .paused(until: until)
        case .held: return .waiting
        case .away: return .due(in: settings.interval)
        case .counting where awaitingReturn: return .due(in: settings.interval)
        case .counting: return .due(in: max(0, breakDue.timeIntervalSince(now)))
        case let .warning(until): return .due(in: max(0, until.timeIntervalSince(now)))
        case .breaking: return .due(in: 0)
        }
    }

    private var isActive: Bool {
        switch phase {
        case .counting, .held, .warning, .breaking: return true
        case .off, .away, .paused: return false
        }
    }

    private var isWarningOrBreaking: Bool {
        switch phase {
        case .warning, .breaking: return true
        default: return false
        }
    }

    private func isHeld(_ hold: Hold) -> Bool {
        (settings.holdOnCall && hold.callActive) || hold.bubbleVisible
    }

    private mutating func beginWarning(_ now: Date) {
        if settings.warning > 0 {
            phase = .warning(until: now.addingTimeInterval(settings.warning))
        } else {
            beginBreak(now)
        }
    }

    private mutating func beginBreak(_ now: Date) {
        phase = .breaking(until: now.addingTimeInterval(settings.length))
    }

    private mutating func finishBreak(_ now: Date) {
        breaksTaken += 1
        restartCycle(now)
        phase = .counting
    }

    private mutating func restartCycle(_ start: Date) {
        cycleStart = start
        postponedDue = nil
        awaitingReturn = false
    }
}

extension EyeBreakPlanner.Settings {
    /// From the stored preference (0022 §9). `intervalOverride` is the scratch-only testing hook.
    init(_ stored: EyeBreakSettings, intervalOverride: TimeInterval? = nil) {
        self.init(enabled: stored.enabled,
                  interval: intervalOverride ?? TimeInterval(stored.intervalMinutes) * 60,
                  length: TimeInterval(stored.lengthSeconds),
                  warning: TimeInterval(stored.warnSeconds),
                  allowSkip: stored.allowSkip,
                  holdOnCall: stored.holdOnCall)
    }

    /// `RALLO_EYE_BREAK_SECONDS`, honoured only by a scratch instance (manual checks),
    /// like `RALLO_PREVIEW_UPDATE`. Under 15 s is ignored: the warning needs room.
    static func intervalOverride(environment: [String: String], isScratch: Bool) -> TimeInterval? {
        guard isScratch, let raw = environment["RALLO_EYE_BREAK_SECONDS"], let seconds = TimeInterval(raw),
              seconds >= 15 else { return nil }
        return seconds
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run the Step 2 command.
Expected: all `EyeBreakPlannerTests` pass (23 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Rallo/EyeBreak/EyeBreakPlanner.swift apps/macos/RalloTests/EyeBreakPlannerTests.swift apps/macos/project.yml
git commit -m "feat(app): eye-break planner"
```

---

### Task 6: `EyeBreakEffects`: effects of a phase change, text, pause times, main screen

**Files:**
- Create: `apps/macos/Rallo/EyeBreak/EyeBreakEffects.swift`
- Create: `apps/macos/RalloTests/EyeBreakEffectsTests.swift`
- Modify: `apps/macos/project.yml` (RalloTests: `- path: Rallo/EyeBreak/EyeBreakEffects.swift` after the planner)

**Interfaces:**
- Consumes: `EyeBreakPlanner` (Task 5).
- Produces (used by Tasks 8, 9, 11):

```swift
enum EyeBreakEffect: Equatable {
    case showPill(until: Date), hidePill, nudgePet(Bool)
    case showOverlay(until: Date), closeOverlay, restoreFocus
    case toast(nextIn: TimeInterval), resumeAlerts
}
enum EyeBreakEffects { static func between(_ old: EyeBreakPlanner, _ new: EyeBreakPlanner) -> [EyeBreakEffect] }
enum EyeBreakText {
    static func clock(_ seconds: TimeInterval) -> String                  // "12:34"
    static func pill(_ seconds: TimeInterval) -> String                   // "Eye break in 8 s"
    static func statusLine(_ status: EyeBreakPlanner.MenuStatus, locale: Locale = .current, timeZone: TimeZone = .current) -> String?
    static func toast(nextIn seconds: TimeInterval) -> String             // "Eyes rested · next in 20 min"
    static func announcement(length: TimeInterval) -> String              // "Eye break, 20 seconds"
}
enum EyeBreakPause: Int, CaseIterable { case thirtyMinutes, oneHour, untilTomorrow
    var title: String; func until(now: Date, calendar: Calendar = .current) -> Date }
enum EyeBreakLayout { static func mainIndex(screens: [CGRect], mouse: CGPoint) -> Int }
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

/// What the controller does on each change of phase, and the eye-break copy (0022 §3-§7).
final class EyeBreakEffectsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func planner(allowSkip: Bool = true) -> EyeBreakPlanner {
        EyeBreakPlanner(settings: .init(enabled: true, interval: 1200, length: 20, warning: 10,
                                        allowSkip: allowSkip, holdOnCall: true), now: t0)
    }

    private func breaking() -> EyeBreakPlanner {
        var p = planner(allowSkip: false)
        p.startNow(at(100))
        return p
    }

    // MARK: Effects

    func testTheWarningShowsThePillAndNudgesThePetThenTheBreakReplacesIt() {
        let counting = planner()
        var warning = counting
        warning.tick(now: at(1190), idle: 0, hold: .init())
        XCTAssertEqual(EyeBreakEffects.between(counting, warning), [.nudgePet(true), .showPill(until: at(1200))])
        var breaking = warning
        breaking.tick(now: at(1200), idle: 0, hold: .init())
        XCTAssertEqual(EyeBreakEffects.between(warning, breaking),
                       [.hidePill, .nudgePet(false), .showOverlay(until: at(1220))], "the pill goes before the overlay comes")
    }

    func testEveryExitFromABreakClosesTheOverlayRestoresFocusAndResumesAlerts() {
        let start = breaking()
        var completed = start
        completed.tick(now: at(120), idle: 0, hold: .init())
        var escaped = start
        escaped.escHeld(at(104))
        var away = start
        away.setScreenAvailable(false, now: at(105))
        var off = start
        var settings = off.settings
        settings.enabled = false
        off.apply(settings, now: at(106))
        var postponed = planner()
        postponed.startNow(at(100))
        let postponedStart = postponed
        postponed.postpone(at(101))

        for (old, new) in [(start, completed), (start, escaped), (start, away), (start, off), (postponedStart, postponed)] {
            let effects = EyeBreakEffects.between(old, new)
            XCTAssertTrue(effects.contains(.closeOverlay), "\(new.phase)")
            XCTAssertTrue(effects.contains(.restoreFocus), "\(new.phase): focus comes back even if activation failed")
            XCTAssertTrue(effects.contains(.resumeAlerts), "\(new.phase): a waiting reminder round runs")
            XCTAssertLessThan(effects.firstIndex(of: .closeOverlay)!, effects.firstIndex(of: .restoreFocus)!)
        }
    }

    func testOnlyABreakThatEndsShowsTheToast() {
        let start = breaking()
        var completed = start
        completed.tick(now: at(120), idle: 0, hold: .init())
        XCTAssertTrue(EyeBreakEffects.between(start, completed).contains(.toast(nextIn: 1200)))
        var escaped = start
        escaped.escHeld(at(104))
        XCTAssertTrue(EyeBreakEffects.between(start, escaped).contains(.toast(nextIn: 1200)))

        var postponed = planner()
        postponed.startNow(at(100))
        let before = postponed
        postponed.postpone(at(101))
        XCTAssertFalse(EyeBreakEffects.between(before, postponed).contains { if case .toast = $0 { true } else { false } })

        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: .init())
        var skipped = warning
        skipped.skip(at(1192))
        XCTAssertEqual(EyeBreakEffects.between(warning, skipped), [.hidePill, .nudgePet(false)], "no toast: no break happened")
    }

    func testGoingAwayMidBreakClosesWithoutAToast() {
        let start = breaking()
        var away = start
        away.setScreenAvailable(false, now: at(105))
        XCTAssertEqual(EyeBreakEffects.between(start, away), [.closeOverlay, .restoreFocus, .resumeAlerts])

        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: .init())
        var awayFromWarning = warning
        awayFromWarning.setScreenAvailable(false, now: at(1192))
        XCTAssertEqual(EyeBreakEffects.between(warning, awayFromWarning), [.hidePill, .nudgePet(false)])
    }

    func testNoChangeNoEffects() {
        let p = planner()
        XCTAssertEqual(EyeBreakEffects.between(p, p), [])
    }

    // MARK: Text

    func testClockAndPillRoundUpSoTheyNeverShowZeroEarly() {
        XCTAssertEqual(EyeBreakText.clock(754), "12:34")
        XCTAssertEqual(EyeBreakText.clock(11.2), "0:12")
        XCTAssertEqual(EyeBreakText.clock(-3), "0:00")
        XCTAssertEqual(EyeBreakText.pill(7.4), "Eye break in 8 s")
    }

    func testStatusLines() {
        let utc = TimeZone(identifier: "UTC")!
        let enUS = Locale(identifier: "en_US")
        XCTAssertNil(EyeBreakText.statusLine(.off))
        XCTAssertEqual(EyeBreakText.statusLine(.due(in: 754)), "Eye break in 12:34")
        XCTAssertEqual(EyeBreakText.statusLine(.waiting), "Eye break when you’re free")
        let fiveThirty = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000 % 86_400 + 17 * 3600 + 30 * 60)
        let paused = EyeBreakText.statusLine(.paused(until: fiveThirty), locale: enUS, timeZone: utc)
        XCTAssertEqual(paused?.replacingOccurrences(of: "\u{202F}", with: " "), "Eye breaks paused until 5:30 PM")
    }

    func testToastAndAnnouncement() {
        XCTAssertEqual(EyeBreakText.toast(nextIn: 1200), "Eyes rested · next in 20 min")
        XCTAssertEqual(EyeBreakText.toast(nextIn: 40), "Eyes rested · next in 40 s")
        XCTAssertEqual(EyeBreakText.announcement(length: 20), "Eye break, 20 seconds")
    }

    // MARK: Pause times, main screen

    func testPauseEndTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 10:00 local is the spring-forward day: that day has 23 hours.
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 10))!
        XCTAssertEqual(EyeBreakPause.thirtyMinutes.until(now: now, calendar: calendar), now.addingTimeInterval(1800))
        XCTAssertEqual(EyeBreakPause.oneHour.until(now: now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(EyeBreakPause.untilTomorrow.until(now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0)))
        XCTAssertEqual(EyeBreakPause.allCases.map(\.title), ["For 30 Minutes", "For 1 Hour", "Until Tomorrow"])
    }

    func testTheCountdownGoesToTheScreenUnderTheMouse() {
        let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: 1728, y: 0, width: 2560, height: 1440)]
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: screens, mouse: CGPoint(x: 2000, y: 500)), 1)
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: screens, mouse: CGPoint(x: 100, y: 100)), 0)
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: screens, mouse: CGPoint(x: -500, y: 9000)), 0, "off every screen: the first")
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: [screens[1]], mouse: CGPoint(x: 100, y: 100)), 0, "a display unplugged mid-break")
    }
}
```

- [ ] **Step 2: Add to the test target, run to see it fail**

`touch apps/macos/Rallo/EyeBreak/EyeBreakEffects.swift`, then add `- path: Rallo/EyeBreak/EyeBreakEffects.swift` to the `RalloTests` sources. Run:
```bash
(cd apps/macos && xcodegen generate --quiet) && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex -only-testing:RalloTests/EyeBreakEffectsTests test -quiet
```
Expected: build FAILS with "cannot find 'EyeBreakEffects' in scope".

- [ ] **Step 3: Implement**

`apps/macos/Rallo/EyeBreak/EyeBreakEffects.swift`:
```swift
import CoreGraphics
import Foundation

/// What `EyeBreakController` does when the planner's phase changes (0022 §3-§5).
enum EyeBreakEffect: Equatable {
    case showPill(until: Date)
    case hidePill
    /// The pet's `nudge` pose for the warning (§3), and back.
    case nudgePet(Bool)
    /// Records the frontmost app, shows a window per screen, activates Rallo.
    case showOverlay(until: Date)
    case closeOverlay
    /// Re-activates the app recorded by `showOverlay`, whether or not Rallo ever became active.
    case restoreFocus
    case toast(nextIn: TimeInterval)
    /// 0021 §8: a reminder round waiting for the break runs now.
    case resumeAlerts
}

enum EyeBreakEffects {
    static func between(_ old: EyeBreakPlanner, _ new: EyeBreakPlanner) -> [EyeBreakEffect] {
        var effects: [EyeBreakEffect] = []
        let oldWarning = old.phase.warningUntil, newWarning = new.phase.warningUntil
        let oldBreak = old.phase.breakingUntil, newBreak = new.phase.breakingUntil
        if oldWarning != nil, newWarning == nil { effects += [.hidePill, .nudgePet(false)] }
        if let until = newWarning, until != oldWarning {
            if oldWarning == nil { effects.append(.nudgePet(true)) }
            effects.append(.showPill(until: until))
        }
        if oldBreak != nil, newBreak == nil {
            effects += [.closeOverlay, .restoreFocus]
            // Completed, skipped or held Esc; not +5 min, a lock, or turning off (§5).
            if new.breaksTaken > old.breaksTaken { effects.append(.toast(nextIn: new.settings.interval)) }
            effects.append(.resumeAlerts)
        }
        if let until = newBreak, until != oldBreak { effects.append(.showOverlay(until: until)) }
        return effects
    }
}

private extension EyeBreakPlanner.Phase {
    var warningUntil: Date? {
        if case let .warning(until) = self { return until }
        return nil
    }

    var breakingUntil: Date? {
        if case let .breaking(until) = self { return until }
        return nil
    }
}

/// Eye-break copy (0022 §3-§7).
enum EyeBreakText {
    /// "12:34", "0:08"; rounded up so it never shows 0:00 early.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func pill(_ seconds: TimeInterval) -> String {
        "Eye break in \(max(0, Int(seconds.rounded(.up)))) s"
    }

    static func statusLine(_ status: EyeBreakPlanner.MenuStatus, locale: Locale = .current,
                           timeZone: TimeZone = .current) -> String? {
        switch status {
        case .off:
            return nil
        case let .due(seconds):
            return "Eye break in \(clock(seconds))"
        case let .paused(until):
            let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
            return "Eye breaks paused until \(time)"
        case .waiting:
            return "Eye break when you’re free"
        }
    }

    static func toast(nextIn seconds: TimeInterval) -> String {
        seconds >= 60
            ? "Eyes rested · next in \(Int((seconds / 60).rounded())) min"
            : "Eyes rested · next in \(Int(seconds)) s"
    }

    static func announcement(length: TimeInterval) -> String { "Eye break, \(Int(length)) seconds" }
}

/// Pause Eye Breaks ▸ (§7). The raw value is the menu item's tag.
enum EyeBreakPause: Int, CaseIterable {
    case thirtyMinutes, oneHour, untilTomorrow

    var title: String {
        switch self {
        case .thirtyMinutes: "For 30 Minutes"
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        }
    }

    /// Until Tomorrow is the next local midnight.
    func until(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(24 * 60 * 60)
        }
    }
}

enum EyeBreakLayout {
    /// The screen under the mouse gets the countdown (§4); off every screen, the first.
    static func mainIndex(screens: [CGRect], mouse: CGPoint) -> Int {
        screens.firstIndex { $0.contains(mouse) } ?? 0
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run the Step 2 command.
Expected: all `EyeBreakEffectsTests` pass (10 tests).

If `testStatusLines` fails only on the space before "PM", the system's ICU uses a different space character. Normalise that character in the test, the way `\u{202F}` already is. Do not change the production format.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Rallo/EyeBreak/EyeBreakEffects.swift apps/macos/RalloTests/EyeBreakEffectsTests.swift apps/macos/project.yml
git commit -m "feat(app): eye-break effects, copy and pause times"
```

---

### Task 7: The pet holds a pose

**Files:**
- Modify: `apps/macos/Rallo/Pet/PetRenderer.swift` (`restPose` at :80; add `hold(_:)` next to `setListening(_:)`, :263-281)
- Modify: `apps/macos/Rallo/Pet/PetPanel.swift` (next to `setListening`, :55-57)

**Interfaces:**
- Produces: `PetController.hold(_ pose: PetView.Pose?)`. It holds `pose` over the reducer's pose until `hold(nil)`. Task 9 uses `.nudge` for the warning and `.happy` with the toast.

If plan 1 already added a pose override on `PetController` with the same meaning, use it in Task 9 instead. Skip this task, and note it in the Task 9 commit message.

- [ ] **Step 1: Implement**

In `PetRenderer.swift`, replace `private var restPose: Pose { listening ? .listening : steadyPose }` (:80) with:
```swift
    /// A pose held over the reducer's (0022: `nudge` for the eye-break warning,
    /// `happy` with its toast); nil lets go.
    private var heldPose: Pose?
    private var restPose: Pose { heldPose ?? (listening ? .listening : steadyPose) }
```

After `setListening(_:)`:
```swift
    /// Holds `pose` (or lets go with nil) until told otherwise; a moment in
    /// progress finishes first and then lands on it by itself.
    func hold(_ pose: Pose?) {
        guard pose != heldPose else { return }
        heldPose = pose
        endPlay()
        if !momentActive { show(restPose, fade: motionAllowed && canAnimate) }
    }
```

In `PetPanel.swift`, after `func heard()`:
```swift
    /// Eye breaks (0022 §3, §5): a pose over the reducer's until `hold(nil)`.
    func hold(_ pose: PetView.Pose?) { petView.hold(pose) }
```

- [ ] **Step 2: Build and run the whole Swift suite**

Run: `scripts/build-macos.sh && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test -quiet`
Expected: build succeeds; all tests pass. No behaviour changes until Task 9 calls `hold`.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Rallo/Pet/PetRenderer.swift apps/macos/Rallo/Pet/PetPanel.swift
git commit -m "feat(pet): hold a pose over the reducer's"
```

---

### Task 8: The overlay, the pill and the toast

**Files:**
- Create: `apps/macos/Rallo/EyeBreak/EyeBreakOverlay.swift`
- Create: `apps/macos/Rallo/EyeBreak/EyeBreakPill.swift`

**Interfaces:**
- Consumes: `EyeBreakText`, `EyeBreakLayout`, `EyeBreakPlanner.escHold`, `PetView.Pose`, `Theme`.
- Produces (used by Task 9):

```swift
@MainActor final class EyeBreakOverlay {
    static let windowLevel: NSWindow.Level                     // .screenSaver, unless Task 10 changes it
    var onSkip: () -> Void; var onPostpone: () -> Void; var onEscHeld: () -> Void
    var isVisible: Bool { get }
    func show(until: Date, tip: String, allowSkip: Bool, animate: Bool)
    func rebuild()                                             // screens changed mid-break
    func makeMainKey()
    func close(animate: Bool)
}
@MainActor final class EyeBreakPill {
    var onStartNow: () -> Void; var onPostpone: () -> Void; var onSkip: () -> Void
    func show(until: Date, total: TimeInterval, allowSkip: Bool, on screen: NSScreen?)
    func hide()
}
@MainActor final class EyeBreakToast {
    func show(_ text: String, near petFrame: NSRect?)          // hides itself after 3 s
}
```

These are views. Task 9 checks them in the running app, where they get their click-through and screenshots.

- [ ] **Step 1: Write `EyeBreakOverlay.swift`**

```swift
import AppKit
import SwiftUI

/// The break (0022 §4): one black window per screen. The screen under the
/// mouse shows the pet, the countdown, a tip and (unless strict) the buttons.
@MainActor
final class EyeBreakOverlay {
    /// Spike S6 picked it (0022 "Verified"); one constant, so a fallback is one line.
    static let windowLevel = NSWindow.Level.screenSaver

    var onSkip: () -> Void = {}
    var onPostpone: () -> Void = {}
    /// Esc held for `EyeBreakPlanner.escHold` seconds: strict mode's way out.
    var onEscHeld: () -> Void = {}

    private var windows: [OverlayWindow] = []
    private var shown: (until: Date, tip: String, allowSkip: Bool)?
    private var escHold: DispatchWorkItem?

    var isVisible: Bool { !windows.isEmpty }

    func show(until: Date, tip: String, allowSkip: Bool, animate: Bool) {
        shown = (until, tip, allowSkip)
        build(animate: animate)
    }

    /// Screens came or went mid-break: one window per screen again.
    func rebuild() {
        guard isVisible else { return }
        build(animate: false)
        makeMainKey()
    }

    func makeMainKey() {
        windows.first(where: \.holdsCountdown)?.makeKeyAndOrderFront(nil)
    }

    func close(animate: Bool) {
        escHold?.cancel()
        escHold = nil
        shown = nil
        let closing = windows
        windows = []
        guard animate else {
            closing.forEach { $0.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 1
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated { closing.forEach { $0.orderOut(nil) } }
        })
    }

    private func build(animate: Bool) {
        guard let shown else { return }
        windows.forEach { $0.orderOut(nil) }
        let screens = NSScreen.screens
        let main = EyeBreakLayout.mainIndex(screens: screens.map(\.frame), mouse: NSEvent.mouseLocation)
        windows = screens.enumerated().map { index, screen in
            let window = OverlayWindow(screen: screen, holdsCountdown: index == main)
            window.contentView = NSHostingView(rootView: BreakView(
                until: shown.until, tip: shown.tip, allowSkip: shown.allowSkip, holdsCountdown: index == main,
                onSkip: { [weak self] in self?.onSkip() }, onPostpone: { [weak self] in self?.onPostpone() }))
            window.onEsc = { [weak self] down in self?.esc(down: down, allowSkip: shown.allowSkip) }
            window.alphaValue = animate ? 0 : 1
            window.orderFrontRegardless()
            return window
        }
        guard animate else { return }
        let opening = windows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            opening.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// Esc skips at once; in strict mode only a 3 s hold ends the break (§4).
    private func esc(down: Bool, allowSkip: Bool) {
        guard down else {
            escHold?.cancel()
            escHold = nil
            return
        }
        if allowSkip {
            onSkip()
            return
        }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onEscHeld() } }
        escHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EyeBreakPlanner.escHold, execute: work)
    }
}

/// Black, above full-screen apps, the menu bar and the Dock. Only the
/// countdown's window becomes key, so Esc reaches it and typing goes nowhere.
private final class OverlayWindow: NSWindow {
    let holdsCountdown: Bool
    var onEsc: (Bool) -> Void = { _ in }

    init(screen: NSScreen, holdsCountdown: Bool) {
        self.holdsCountdown = holdsCountdown
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = EyeBreakOverlay.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { holdsCountdown }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !event.isARepeat { onEsc(true) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 53 { onEsc(false) }
    }

    /// ⌘-shortcuts go nowhere during a break either.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}

private struct BreakView: View {
    let until: Date
    let tip: String
    let allowSkip: Bool
    let holdsCountdown: Bool
    let onSkip: () -> Void
    let onPostpone: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if holdsCountdown {
                VStack(spacing: 12) {
                    if let pet = Bundle.main.image(forResource: PetView.Pose.content.rawValue) {
                        Image(nsImage: pet)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 110)
                            .brightness(-0.12)
                            .opacity(0.9)
                            .accessibilityHidden(true)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = until.timeIntervalSince(context.date)
                        Text(EyeBreakText.clock(remaining))
                            .font(.system(size: 56, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(white: 0.93))
                            .accessibilityLabel("\(max(0, Int(remaining.rounded(.up)))) seconds left")
                    }
                    Text(tip)
                        .font(Theme.rounded(17, .medium))
                        .foregroundStyle(Color(white: 0.78))
                }
                if allowSkip {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Button("+5 min", action: onPostpone).accessibilityLabel("Postpone the eye break 5 minutes")
                            Button("Skip · esc", action: onSkip).accessibilityLabel("Skip the eye break")
                        }
                        .buttonStyle(DimButtonStyle())
                        .padding(.bottom, 36)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Dim on black, so the buttons don't pull the eyes back to the screen.
private struct DimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(13))
            .foregroundStyle(Color(white: configuration.isPressed ? 0.85 : 0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(white: 0.22)))
            .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Write `EyeBreakPill.swift` (the pill and the toast)**

```swift
import AppKit
import SwiftUI

/// Never key, never main: the pill and the toast must not take focus (0022 §3, §5).
private final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Same level and collection behaviour as the pet and the voice bubble (0002).
@MainActor
private func makePanel(clickable: Bool) -> NSPanel {
    let panel = QuietPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = !clickable
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    return panel
}

@MainActor
private final class PillModel: ObservableObject {
    @Published var until = Date()
    @Published var total: TimeInterval = 10
    @Published var allowSkip = true
}

private struct PillView: View {
    @ObservedObject var model: PillModel
    let onStartNow: () -> Void
    let onPostpone: () -> Void
    let onSkip: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, model.until.timeIntervalSince(context.date))
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Theme.onToast.opacity(0.2), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: model.total > 0 ? remaining / model.total : 0)
                        .stroke(Theme.toastAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                Text(EyeBreakText.pill(remaining)).font(Theme.rounded(13, .semibold))
                Button("Start now", action: onStartNow)
                // Strict mode keeps only Start now (plan spec note 1).
                if model.allowSkip {
                    Button("+5 min", action: onPostpone)
                    Button("Skip", action: onSkip)
                }
            }
            .buttonStyle(PillButtonStyle())
            .foregroundStyle(Theme.onToast)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Theme.toast, in: Capsule())
            .fixedSize()
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(12, .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.onToast.opacity(configuration.isPressed ? 0.24 : 0.12), in: Capsule())
            .contentShape(Capsule())
    }
}

/// The warning before a break (0022 §3), top centre of the screen under the mouse.
@MainActor
final class EyeBreakPill {
    var onStartNow: () -> Void = {}
    var onPostpone: () -> Void = {}
    var onSkip: () -> Void = {}

    private let model = PillModel()
    private let panel = makePanel(clickable: true)
    private lazy var host = NSHostingView(rootView: PillView(
        model: model,
        onStartNow: { [weak self] in self?.onStartNow() },
        onPostpone: { [weak self] in self?.onPostpone() },
        onSkip: { [weak self] in self?.onSkip() }))

    func show(until: Date, total: TimeInterval, allowSkip: Bool, on screen: NSScreen?) {
        model.until = until
        model.total = total
        model.allowSkip = allowSkip
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 8))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            if let pet = Bundle.main.image(forResource: PetView.Pose.happy.rawValue) {
                Image(nsImage: pet).resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
            }
            Text(text).font(Theme.rounded(12.5, .semibold))
        }
        .foregroundStyle(Theme.onToast)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.toast, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }
}

/// "Eyes rested · next in 20 min" (0022 §5), above the pet, for 3 s.
@MainActor
final class EyeBreakToast {
    private let panel = makePanel(clickable: false)
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, near petFrame: NSRect?) {
        let host = NSHostingView(rootView: ToastView(text: text))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, petFrame: petFrame))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.orderOut(nil) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Above the pet like the voice bubble, else the top-right corner.
    private func origin(for size: NSSize, petFrame: NSRect?) -> NSPoint {
        if let pet = petFrame {
            let screen = NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main
            var p = NSPoint(x: pet.midX - size.width / 2, y: pet.maxY + 6)
            if let v = screen?.visibleFrame {
                p.x = min(max(p.x, v.minX + 4), v.maxX - size.width - 4)
                p.y = min(p.y, v.maxY - size.height - 4)
            }
            return p
        }
        let v = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16)
    }
}
```

- [ ] **Step 3: Build**

Run: `scripts/build-macos.sh`
Expected: build succeeds. Nothing calls these yet.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Rallo/EyeBreak/EyeBreakOverlay.swift apps/macos/Rallo/EyeBreak/EyeBreakPill.swift
git commit -m "feat(app): eye-break overlay, warning pill and toast"
```

---

### Task 9: `EyeBreakController` and the coordinator wiring

**Files:**
- Create: `apps/macos/Rallo/EyeBreak/EyeBreakController.swift`
- Modify: `apps/macos/Rallo/App/AppCoordinator.swift`:
  - properties (:20-50);
  - `start()` (:102-200);
  - `observeSystemEvents` is untouched, because the controller observes for itself;
  - `reloadFromCore()` (:310-345).

**Interfaces:**
- Consumes:
  - Tasks 5, 6, 7, 8;
  - the plan-1 contract: `QuietSignals.cameraOrMicInUse`, `QuietSignals.idleSeconds()`, `AttentionCoordinator.eyeBreakActive`, `eyeBreakEnded()`, `onBubbleVisibilityChanged`;
  - `CoreClient.eyeBreakSettings()`.
- Produces (used by Tasks 11 and 12):

```swift
@MainActor final class EyeBreakController {
    init(quiet: QuietSignals, pet: PetController, log: DiagnosticsLog, intervalOverride: TimeInterval?)
    var animationsPaused: () -> Bool
    var onBreakEnded: () -> Void
    var isBreaking: Bool { get }
    func start()
    func apply(_ stored: EyeBreakSettings)
    func setBubbleVisible(_ visible: Bool)
    func startNow()
    func pause(until: Date)
    func menuStatus() -> EyeBreakPlanner.MenuStatus
}
```

- [ ] **Step 1: Write the controller**

```swift
import AppKit

/// Runs the eye-break cycle (0022): feeds `EyeBreakPlanner` the clock, idle
/// time, quiet signals and system events, and performs what each change of
/// phase asks for (`EyeBreakEffects`).
@MainActor
final class EyeBreakController {
    private var planner = EyeBreakPlanner(settings: .init(), now: Date())
    private let quiet: QuietSignals
    private let pet: PetController
    private let log: DiagnosticsLog
    private let intervalOverride: TimeInterval?
    private let overlay = EyeBreakOverlay()
    private let pill = EyeBreakPill()
    private let toast = EyeBreakToast()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var locked = false
    private var displaysAsleep = false
    private var systemAsleep = false
    private var bubbleVisible = false
    /// The app that was frontmost when the break began; it gets focus back (§4, §5).
    private var recordedApp: NSRunningApplication?

    /// The menu's Pause Animations, wired by the coordinator.
    var animationsPaused: () -> Bool = { false }
    /// A break ended, however it ended: a reminder round waiting for it runs (0021 §8).
    var onBreakEnded: () -> Void = {}

    init(quiet: QuietSignals, pet: PetController, log: DiagnosticsLog, intervalOverride: TimeInterval?) {
        self.quiet = quiet
        self.pet = pet
        self.log = log
        self.intervalOverride = intervalOverride
        overlay.onSkip = { [weak self] in self?.change { _ = $0.skip(Date()) } }
        overlay.onPostpone = { [weak self] in self?.change { _ = $0.postpone(Date()) } }
        overlay.onEscHeld = { [weak self] in self?.change { $0.escHeld(Date()) } }
        pill.onStartNow = { [weak self] in self?.startNow() }
        pill.onPostpone = { [weak self] in self?.change { _ = $0.postpone(Date()) } }
        pill.onSkip = { [weak self] in self?.change { _ = $0.skip(Date()) } }
    }

    var isBreaking: Bool {
        if case .breaking = planner.phase { return true }
        return false
    }

    func start() {
        observe()
        arm()
    }

    func apply(_ stored: EyeBreakSettings) {
        let settings = EyeBreakPlanner.Settings(stored, intervalOverride: intervalOverride)
        guard settings != planner.settings else { return }
        change { $0.apply(settings, now: Date()) }
    }

    /// The reminder bubble opened or closed (0021): a due break waits for it.
    func setBubbleVisible(_ visible: Bool) {
        bubbleVisible = visible
        tick()
    }

    func startNow() { change { $0.startNow(Date()) } }

    func pause(until: Date) { change { $0.pause(until: until, now: Date()) } }

    func menuStatus() -> EyeBreakPlanner.MenuStatus { planner.menuStatus(now: Date()) }

    // MARK: Driving the planner

    private func tick() {
        let hold = EyeBreakPlanner.Hold(
            callActive: planner.settings.holdOnCall && quiet.cameraOrMicInUse, bubbleVisible: bubbleVisible)
        let idle = QuietSignals.idleSeconds()
        change { $0.tick(now: Date(), idle: idle, hold: hold) }
    }

    private func change(_ body: (inout EyeBreakPlanner) -> Void) {
        let before = planner
        var after = planner
        body(&after)
        planner = after
        for effect in EyeBreakEffects.between(before, after) { perform(effect) }
        if before.phase != after.phase { log.record("eye_break_phase", ["phase": "\(after.phase)"]) }
        arm()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard let next = planner.nextCheck(now: Date()) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !animationsPaused()
    }

    private func perform(_ effect: EyeBreakEffect) {
        switch effect {
        case let .showPill(until):
            pill.show(until: until, total: planner.settings.warning, allowSkip: planner.settings.allowSkip,
                      on: Self.screenUnderMouse())
        case .hidePill:
            pill.hide()
        case let .nudgePet(on):
            pet.hold(on ? .nudge : nil)
        case let .showOverlay(until):
            if !overlay.isVisible {
                let front = NSWorkspace.shared.frontmostApplication
                // Rallo frontmost (panel or notes window open): it simply stays active.
                recordedApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            }
            overlay.show(until: until, tip: planner.tip, allowSkip: planner.settings.allowSkip, animate: motionAllowed)
            NSApp.activate()
            overlay.makeMainKey()
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: EyeBreakText.announcement(length: planner.settings.length),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        case .closeOverlay:
            overlay.close(animate: motionAllowed)
        case .restoreFocus:
            // Even if Rallo never became active: the recorded app is then still in front.
            recordedApp?.activate()
            recordedApp = nil
        case let .toast(nextIn):
            toast.show(EyeBreakText.toast(nextIn: nextIn), near: pet.isVisible ? pet.frame : nil)
            pet.hold(.happy)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.pet.hold(nil) }
            }
        case .resumeAlerts:
            onBreakEnded()
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: System events (§2)

    private func observe() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = true; self?.screenAvailabilityChanged() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = false; self?.screenAvailabilityChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, @MainActor (EyeBreakController) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.displaysAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.displaysAsleep = false }),
            (NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.systemAsleep = false }),
        ]
        for (name, update) in pairs {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    update(self)
                    screenAvailabilityChanged()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.rebuild() }
        })
        // A clock change can land a warning or break in the past or the future: re-check now.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
    }

    private func screenAvailabilityChanged() {
        let available = !locked && !displaysAsleep && !systemAsleep
        change { $0.setScreenAvailable(available, now: Date()) }
    }
}
```

`postpone` and `skip` return `Bool`; the `_ =` discards it. Strict mode makes them no-ops (Task 5), so a short Esc does nothing. `EyeBreakOverlay.esc` never calls `onSkip` in strict mode anyway.

- [ ] **Step 2: Wire it in `AppCoordinator`**

Add with the other properties (after `private var statusMenu: StatusMenuController?`, :33):
```swift
    /// 0022. Lazy: it needs `quietSignals` and `pet`, which exist once `init` is done.
    private lazy var eyeBreaks = EyeBreakController(
        quiet: quietSignals, pet: pet, log: log,
        intervalOverride: EyeBreakPlanner.Settings.intervalOverride(
            environment: ProcessInfo.processInfo.environment, isScratch: isScratch))
    private var eyeBreakSettings: EyeBreakSettings?
```

In `start()`, after the plan-1 wiring of `attention` (or right after `configureSettings()` if plan 1 wires it later in `start()`; it only needs to come before `observer.start()`):
```swift
        eyeBreaks.animationsPaused = { [weak self] in self?.animationsPaused ?? false }
        eyeBreaks.onBreakEnded = { [weak self] in self?.attention.eyeBreakEnded() }
        attention.eyeBreakActive = { [weak self] in self?.eyeBreaks.isBreaking ?? false }
        attention.onBubbleVisibilityChanged = { [weak self] visible in self?.eyeBreaks.setBubbleVisible(visible) }
```

In `start()`, right after `observer.start()` (:197):
```swift
        eyeBreaks.start()
```

In `reloadFromCore()`, before `petState.refresh()` (:342):
```swift
        if let stored = try? await core.eyeBreakSettings() {
            eyeBreakSettings = stored
            eyeBreaks.apply(stored)
        }
```

Check plan 1's `start()` first:

```bash
grep -n "onBubbleVisibilityChanged" apps/macos/Rallo/App/AppCoordinator.swift
```

- **If plan 1 already assigns `onBubbleVisibilityChanged` to something:** keep its body and add `self?.eyeBreaks.setBubbleVisible(visible)` inside it, instead of replacing it.
- **If the grep prints nothing:** use the assignment above as written.

- [ ] **Step 3: Build and run the whole suite**

Run: `scripts/build-macos.sh && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test -quiet`
Expected: build succeeds; all tests pass.

- [ ] **Step 4: Click-through, Dark (harness above; `H_SECONDS=40`: warning ~30 s after launch, break ~40 s, back ~60 s)**

If 0022's S6 line records a failure, do Task 10 now, then come back to this step.

1. Open TextEdit with a document and click into it, so TextEdit is frontmost.
2. Run `source /tmp/rallo-eye-breaks/harness.sh && h_seed && h_launch dark`, then click back into TextEdit.
3. **Pill.** At about 30 s: `h_shot dark-pill`. Expected:
   - the pill is at the top centre of the screen under the mouse;
   - the ring is counting down and reads "Eye break in N s", with Start now / +5 min / Skip;
   - the pet shows `nudge`;
   - typing in TextEdit still works while the pill is up: type a letter.
4. **Overlay.** At about 40 s: `h_shot dark-overlay` and `h_front`. Expected:
   - all black with the dimmed pet, `0:1x` counting down, "Look at something far away", and "+5 min" / "Skip · esc";
   - `h_front` prints `Rallo`.
5. **Ending.** At about 60 s: `h_front` prints `TextEdit`, the toast "Eyes rested · next in 40 s" shows above the pet (`h_shot dark-toast`), and the pet looks `happy` for 3 s. `h_events 10` shows `eye_break_phase` lines for warning, breaking and counting.
6. **Esc.** `h_launch dark`, wait for the overlay, then press Esc: `osascript -e 'tell application "System Events" to key code 53'` (needs Accessibility for the terminal; else ask the user to press it). Expected:
   - the overlay closes at once;
   - `h_front` prints `TextEdit`.
7. **Lock mid-break.** `h_launch dark`, wait for the overlay, then run `pmset displaysleepnow`. Wake the display with a key press. Expected:
   - the overlay is gone, with no toast;
   - `h_events` shows `away`, then `counting`;
   - the next warning comes a full 40 s after waking, not at once.
8. **Second display, if one is connected.** During a break, the countdown is on the screen under the mouse, the other screen is plain black, and `h_shot` lists one overlay window per screen. Unplug or plug a display mid-break: every display is still black. Without a second display, this check goes to the user ("Needs a human").
9. **Reminder collision (Review Focus 2).** `h_seed && h_launch dark`, then at once run `"$H_CLI" remind "Collision check" --at "$(date -v+33S '+%Y-%m-%dT%H:%M:%S%z' | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/')"`. The reminder comes due during the warning. Expected:
   - plan 1's bubble appears, so `held`: the pill goes away and no break starts while the bubble is up;
   - after you press Snooze or Done in the bubble (or after its 60 s timeout), the warning comes back within a few seconds, then the break;
   - `h_events` shows the phases in that order.

   Then, with a fresh seed, make a reminder due ~45 s after launch, inside the break. Expected: no bubble appears over the black, and the bubble round runs right after the break ends.
10. **Camera hold.** Open Photo Booth before the warning is due. Expected:
    - no pill appears;
    - `h_events` shows `held`;
    - after you quit Photo Booth, the pill appears within about 60 s.

    If plan 1's S4 failed, `cameraOrMicInUse` is always false. Then record "camera hold unavailable (S4)" and move on.
11. **Strict mode.** `h_seed strict && h_launch dark`, wait for the overlay. Expected: no buttons on the pill except Start now, and none on the overlay. A short Esc does nothing (osascript `key code 53`).

    Hold Esc for 3 s. This needs a key down and up with a delay, which `osascript` can't do. Use:
    ```bash
    cat > /tmp/rallo-eye-breaks/hold-esc.swift <<'SWIFT'
    import CoreGraphics
    import Foundation
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)!
    down.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 3.3); up.post(tap: .cghidEventTap)
    SWIFT
    swift /tmp/rallo-eye-breaks/hold-esc.swift
    ```
    Expected: the break ends about 3 s into the hold, and focus comes back. This needs Accessibility; otherwise the user holds Esc.
12. **Light Mode.** `h_stop; h_seed; h_launch light`, then `h_shot light-pill` and `h_shot light-toast` at the same moments. View every PNG with the Read tool.
13. Run `h_clean`.

Fix anything that differs, re-run the suite, and repeat the failing check.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Rallo/EyeBreak/EyeBreakController.swift apps/macos/Rallo/App/AppCoordinator.swift
git commit -m "feat(app): eye breaks run, hold for calls and reminders, and give focus back"
```

---

### Task 10: Only if S6 failed: the overlay level and focus restore

Skip this task if 0022's `## Verified` S6 line (Task 2) says yes to every check at `.screenSaver`.

**Files:**
- Modify: `apps/macos/Rallo/EyeBreak/EyeBreakOverlay.swift` (`windowLevel`)
- Modify: `docs/decisions/0022-eye-breaks.md` (§4 and §11 text)

- [ ] **Step 1: Only if the menu bar or Force Quit failed at `.screenSaver` and passed at 101**

Change the constant:
```swift
    /// Spike S6 (0022 "Verified"): `.screenSaver` hid Force Quit, so the
    /// highest level that keeps it reachable and still covers the menu bar.
    static let windowLevel = NSWindow.Level.popUpMenu
```

In 0022 §4, change "at `.screenSaver` level" to "at `.popUpMenu` level (S6)". In §11's fallback cell, add "Applied: `.popUpMenu`."

- [ ] **Step 2: Only if focus did not come back to the recorded app**

In `EyeBreakController.perform(_:)` (Task 9), `case .restoreFocus`, use the macOS 14 cooperative call in place of `activate()`:
```swift
        case .restoreFocus:
            if let app = recordedApp { _ = app.activate(from: NSRunningApplication.current, options: []) }
            recordedApp = nil
```

Note it in 0022 `## Verified` as "focus restore uses `activate(from:options:)`".

- [ ] **Step 3: Only if Esc never reached the overlay**

There is no code fallback that doesn't need Accessibility permission. Record in 0022 §4: "Esc does not reach the overlay on this macOS. Skip and +5 min are buttons, and the countdown always ends the break." Add the same line to the plan's handover notes for the user.

- [ ] **Step 4: Build, test, commit**

```bash
scripts/build-macos.sh && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test -quiet
git add apps/macos/Rallo/EyeBreak/EyeBreakOverlay.swift docs/decisions/0022-eye-breaks.md
git commit -m "fix(app): eye-break overlay level from spike S6"
```

---

### Task 11: Menu bar items

**Files:**
- Modify: `apps/macos/Rallo/App/StatusMenuController.swift` (properties at :23-31; `populate(_:)` at :137-152; the `@objc` actions at :197-208)
- Modify: `apps/macos/Rallo/App/AppCoordinator.swift` (`start()`, next to `menu.updateAvailable = …`, :117)
- Create: `apps/macos/RalloTests/StatusMenuEyeBreakTests.swift`

**Interfaces:**
- Consumes: `EyeBreakPlanner.MenuStatus`, `EyeBreakText.statusLine`, `EyeBreakPause` (Task 6), `EyeBreakController` (Task 9).
- Produces: `StatusMenuController.EyeBreakActions { turnOn, takeBreakNow, pause(Date) }`, `var eyeBreakStatus: () -> EyeBreakPlanner.MenuStatus`, `var eyeBreakActions: EyeBreakActions`.

`StatusMenuController.swift` is already in the `RalloTests` sources (the update-badge commit added it). Its new references, `EyeBreakPlanner.swift` and `EyeBreakEffects.swift`, are there since Tasks 5–6.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import XCTest

/// The menu's eye-break section (0022 §7), shared by the paw and the pet's context menu.
@MainActor
final class StatusMenuEyeBreakTests: XCTestCase {
    private func controller() -> StatusMenuController {
        StatusMenuController(
            actions: .init(togglePet: {}, toggleAnimations: {}, openNotes: {}, openNotesWindow: {},
                           jumpToWaitingAgent: {}, selectAgentSession: { _ in }, openSettings: {},
                           openUpdate: {}, quit: {}),
            petVisible: { true })
    }

    private func choose(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action!, with: item)
    }

    func testWhileOffOnlyTurnOnShows() {
        var turnedOn = false
        let menu = controller()
        menu.eyeBreakActions.turnOn = { turnedOn = true }
        let items = menu.makeMenu().items
        XCTAssertFalse(items.map(\.title).contains("Take a Break Now"))
        choose(items.first { $0.title == "Turn On Eye Breaks" }!)
        XCTAssertTrue(turnedOn)
    }

    func testWhileOnTheStatusLineTakeABreakAndPauseSitBetweenThePetItemsAndSettings() {
        let menu = controller()
        menu.eyeBreakStatus = { .due(in: 754) }
        let items = menu.makeMenu().items
        let titles = items.map(\.title)
        let line = titles.firstIndex(of: "Eye break in 12:34")!
        XCTAssertFalse(items[line].isEnabled)
        XCTAssertEqual(titles[line + 1], "Take a Break Now")
        XCTAssertEqual(titles[line + 2], "Pause Eye Breaks")
        XCTAssertEqual(items[line + 2].submenu?.items.map(\.title), ["For 30 Minutes", "For 1 Hour", "Until Tomorrow"])
        XCTAssertGreaterThan(line, titles.firstIndex(of: "Pause Animations")!)
        XCTAssertLessThan(line, titles.firstIndex(of: "Settings…")!)
    }

    func testTakeABreakNowAndAPauseReachTheirActions() {
        var tookBreak = false
        var pausedUntil: Date?
        let menu = controller()
        menu.eyeBreakStatus = { .paused(until: Date().addingTimeInterval(600)) }
        menu.eyeBreakActions.takeBreakNow = { tookBreak = true }
        menu.eyeBreakActions.pause = { pausedUntil = $0 }
        let items = menu.makeMenu().items
        XCTAssertTrue(items.contains { $0.title.hasPrefix("Eye breaks paused until ") })
        choose(items.first { $0.title == "Take a Break Now" }!)
        XCTAssertTrue(tookBreak)
        let before = Date()
        choose(items.first { $0.title == "Pause Eye Breaks" }!.submenu!.items[1])
        XCTAssertEqual(pausedUntil!.timeIntervalSince(before), 3600, accuracy: 2)
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex -only-testing:RalloTests/StatusMenuEyeBreakTests test -quiet`
Expected: build FAILS with "value of type 'StatusMenuController' has no member 'eyeBreakActions'".

- [ ] **Step 3: Implement**

In `StatusMenuController`, after `var updateAvailable: () -> String? = { nil }` (:31):
```swift
    /// Eye breaks (0022 §7), wired by the coordinator.
    struct EyeBreakActions {
        var turnOn: () -> Void = {}
        var takeBreakNow: () -> Void = {}
        var pause: (Date) -> Void = { _ in }
    }

    var eyeBreakStatus: () -> EyeBreakPlanner.MenuStatus = { .off }
    var eyeBreakActions = EyeBreakActions()
```

In `populate(_:)`, replace the separator line right after `menu.addItem(pause)`:
```swift
        menu.addItem(.separator())
```
with:
```swift
        menu.addItem(.separator())
        populateEyeBreaks(menu)
        menu.addItem(.separator())
```

Add after `populateAgentsSection(_:)`:
```swift
    /// The status line, Take a Break Now and the Pause submenu; only Turn On
    /// Eye Breaks while they're off (0022 §7). The line is the time when the
    /// menu opens; it doesn't tick.
    private func populateEyeBreaks(_ menu: NSMenu) {
        guard let line = EyeBreakText.statusLine(eyeBreakStatus()) else {
            menu.addItem(item("Turn On Eye Breaks", #selector(turnOnEyeBreaks)))
            return
        }
        let status = NSMenuItem(title: line, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(item("Take a Break Now", #selector(takeBreakNow)))
        let pause = NSMenuItem(title: "Pause Eye Breaks", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for choice in EyeBreakPause.allCases {
            let row = item(choice.title, #selector(pauseEyeBreaks(_:)))
            row.tag = choice.rawValue
            choices.addItem(row)
        }
        pause.submenu = choices
        menu.addItem(pause)
    }
```

Add with the other `@objc` actions:
```swift
    @objc private func turnOnEyeBreaks() { eyeBreakActions.turnOn() }
    @objc private func takeBreakNow() { eyeBreakActions.takeBreakNow() }
    @objc private func pauseEyeBreaks(_ sender: NSMenuItem) {
        guard let choice = EyeBreakPause(rawValue: sender.tag) else { return }
        eyeBreakActions.pause(choice.until(now: Date()))
    }
```

In `AppCoordinator.start()`, after `menu.updateAvailable = …` (:117):
```swift
        menu.eyeBreakStatus = { [weak self] in self?.eyeBreaks.menuStatus() ?? .off }
        menu.eyeBreakActions = .init(
            turnOn: { [weak self] in Task { await self?.setEyeBreaksEnabled(true) } },
            takeBreakNow: { [weak self] in self?.eyeBreaks.startNow() },
            pause: { [weak self] until in self?.eyeBreaks.pause(until: until) })
```

Add to `AppCoordinator` (next to `togglePet()`):
```swift
    /// Settings › Breaks and the menu's Turn On Eye Breaks (0022 §7, §8).
    private func saveEyeBreakSettings(_ settings: EyeBreakSettings) async {
        do {
            try await core.setEyeBreakSettings(settings)
            try await reloadFromCore()
        } catch {
            log.record("eye_break_settings_failed", ["error": "\(error)"])
            settingsModel.refresh()
        }
    }

    private func setEyeBreaksEnabled(_ enabled: Bool) async {
        guard var settings = eyeBreakSettings else { return }
        settings.enabled = enabled
        await saveEyeBreakSettings(settings)
    }
```

- [ ] **Step 4: Run the tests, then the whole suite**

Run the Step 2 command, then the full `xcodebuild … test -quiet`.
Expected: 3 new tests pass; everything else still passes.

- [ ] **Step 5: Click-through and screenshots, Dark and Light**

1. `source /tmp/rallo-eye-breaks/harness.sh && h_seed && H_SECONDS=600 h_launch dark menu && h_shot dark-menu`.
   Expected: "Eye break in 9:5x" (disabled), "Take a Break Now", "Pause Eye Breaks ▸", placed between "Pause Animations" and "Settings…".
2. Choose **Take a Break Now** by hand. Expected: the overlay at once, with no warning.
3. Choose **Pause Eye Breaks ▸ For 30 Minutes**, then reopen the menu. Expected: "Eye breaks paused until <time>".
4. Turn eye breaks off in the data: `sqlite3 "$H_DIR/data/rallo.sqlite3" "DELETE FROM preferences WHERE key='eye_breaks.settings';"`, then `h_launch dark menu`. Expected: only "Turn On Eye Breaks". Choose it; reopen. Expected: the status line is back.
5. Right-click the pet. Expected: the same section.
6. Repeat 1 with `light` (`h_shot light-menu`). View the PNGs. Then `h_clean`.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Rallo/App/StatusMenuController.swift apps/macos/Rallo/App/AppCoordinator.swift apps/macos/RalloTests/StatusMenuEyeBreakTests.swift
git commit -m "feat(menu): eye-break status, take a break now and pause"
```

---

### Task 12: Settings › Breaks

**Files:**
- Modify: `apps/macos/Rallo/Settings/SettingsView.swift` (`SettingsTab` :8-52; a new `BreaksTab` after `NotificationsTab`, :143)
- Modify: `apps/macos/Rallo/Settings/SettingsModel.swift` (snapshot fields :15-31; the `tab` comment :42; actions :56-71)
- Modify: `apps/macos/Rallo/App/AppCoordinator.swift` (`configureSettings()` :508-575)

**Interfaces:**
- Consumes: `saveEyeBreakSettings(_:)` and `eyeBreakSettings` (Tasks 9, 11).
- Produces: `SettingsTab.breaks` (raw value `"breaks"`, so `--demo-open settings:breaks` works), `SettingsModel.eyeBreakSettings`, and `SettingsModel.setEyeBreakSettings`, as the contract names them.

- [ ] **Step 1: Implement the model**

In `SettingsModel`, after `@Published var screenshotShortcutTaken = false`:
```swift
    /// 0022 §8; the stored defaults until the coordinator's first snapshot.
    @Published var eyeBreakSettings = EyeBreakSettings(enabled: false, intervalMinutes: 20, lengthSeconds: 20,
                                                       warnSeconds: 10, allowSkip: true, holdOnCall: true)
```

Change the `tab` comment to `/// The selected tab's tag: general, notifications, breaks, agents, voice, clickup, data, about.`

After `var setScreenshotHotkey: (Bool) -> Void = { _ in }`:
```swift
    var setEyeBreakSettings: (EyeBreakSettings) -> Void = { _ in }
```

- [ ] **Step 2: Implement the tab**

In `SettingsTab`:
- the cases become `case general, notifications, breaks, agents, voice, clickup, data, about`;
- `title` gets `case .breaks: "Breaks"`;
- `symbol` gets `case .breaks: "eye"`;
- `view(_:)` gets `case .breaks: BreaksTab(model: model)`.

After the `NotificationsTab` struct:
```swift
// MARK: Breaks

private struct BreaksTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Page {
            Toggle("Remind me to rest my eyes", isOn: binding(\.enabled))
            caption("The 20-20-20 rule: every 20 minutes, look at something 20 feet (6 m) away for 20 seconds. Rallo blacks out the screen and counts down.")
            Group {
                Picker("Every", selection: binding(\.intervalMinutes)) {
                    ForEach([10, 15, 20, 30, 45, 60] as [UInt8], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Break length", selection: binding(\.lengthSeconds)) {
                    ForEach([10, 20, 30, 60] as [UInt8], id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Warn before", selection: binding(\.warnSeconds)) {
                    ForEach([0, 5, 10, 30] as [UInt8], id: \.self) { Text($0 == 0 ? "Off" : "\($0) s").tag($0) }
                }
                Toggle("Allow skipping", isOn: binding(\.allowSkip))
                caption("Off = strict mode: no Skip or +5 min. Holding Esc for 3 seconds always ends a break.")
                Toggle("Hold while camera or mic is in use", isOn: binding(\.holdOnCall))
                caption("Doesn’t black out a video call; the break runs after the call.")
            }
            .disabled(!model.eyeBreakSettings.enabled)
        }
    }

    /// Edits one field and saves the whole record; the core rejects anything off the menus.
    private func binding<Value>(_ keyPath: WritableKeyPath<EyeBreakSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.eyeBreakSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.eyeBreakSettings
                settings[keyPath: keyPath] = value
                model.eyeBreakSettings = settings
                model.setEyeBreakSettings(settings)
            })
    }
}
```

- [ ] **Step 3: Wire it in `configureSettings()`**

In `model.refreshSnapshot`, after `model.screenshotShortcutTaken = …`:
```swift
            if let eyeBreakSettings { model.eyeBreakSettings = eyeBreakSettings }
```

After `model.setScreenshotHotkey = …`'s closure:
```swift
        model.setEyeBreakSettings = { [weak self] settings in
            Task { await self?.saveEyeBreakSettings(settings) }
        }
```

- [ ] **Step 4: Build and run the whole suite**

Run: `scripts/build-macos.sh && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test -quiet`
Expected: everything passes.

- [ ] **Step 5: Click-through and screenshots, Dark and Light**

1. `source /tmp/rallo-eye-breaks/harness.sh && h_seed && sqlite3 "$H_DIR/data/rallo.sqlite3" "DELETE FROM preferences WHERE key='eye_breaks.settings';" && h_launch dark settings:breaks && h_shot dark-breaks`.
   Expected:
   - the Breaks tab sits between Notifications and Agents, with the eye icon;
   - the switch is off and the rows below are disabled;
   - nothing is clipped at 540×400.
2. Turn the switch on. Pick Every 10 min, Break length 30 s, Warn before Off, and Allow skipping off. Then quit with `h_stop` and run `h_launch dark settings:breaks`.
   Expected: every choice survived the relaunch.
3. Run `sqlite3 "$H_DIR/data/rallo.sqlite3" "SELECT value FROM preferences WHERE key='eye_breaks.settings';"`.
   Expected: `{"enabled":true,"interval_minutes":10,"length_seconds":30,"warn_seconds":0,"allow_skip":false,"hold_on_call":true}`.
4. Change "Every" while counting.
   Expected: `h_events` shows the cycle restarting. The menu status line shows the new full interval.
5. Run `h_launch light settings:breaks && h_shot light-breaks`. View both PNGs, then run `h_clean`.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Rallo/Settings/SettingsView.swift apps/macos/Rallo/Settings/SettingsModel.swift apps/macos/Rallo/App/AppCoordinator.swift
git commit -m "feat(settings): Breaks tab for eye breaks"
```

---

### Task 13: Whole-feature pass

**Files:**
- No new code. Fix anything this pass finds, in the file that owns it.

- [ ] **Step 1: Run every suite**

```bash
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
cargo test --workspace
xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test
```
Expected: Rust and Swift both have 0 failures. Record the counts in the commit message, or in the handover if there is no commit.

- [ ] **Step 2: Default-off check on a fresh data dir**

`source /tmp/rallo-eye-breaks/harness.sh`, then build a fresh data dir *without* `h_seed`'s eye-break row:
```bash
h_stop; rm -rf "$H_DIR/data"; mkdir -p "$H_DIR/data"; "$H_CLI" note "x" >/dev/null; h_kill
H_SECONDS=20 h_launch dark menu; sleep 40; h_events 30
```
Expected:
- no `eye_break_phase` line at all;
- the menu shows "Turn On Eye Breaks";
- nothing ever blacks out.

- [ ] **Step 3: The installed app ignores the override**

```bash
grep -n "RALLO_EYE_BREAK_SECONDS" -r apps/macos/Rallo
```
Expected: only `EyeBreakPlanner.swift`, where it is gated on `isScratch`. Its test is `testSettingsFromThePreferenceAndTheScratchOnlyOverride`.

- [ ] **Step 4: Hand the "Needs a human" list to the user**

Report the screenshots taken in Tasks 9, 11 and 12, which items in "Needs a human" are still open, and the S6 result. Run `h_clean`.

- [ ] **Step 5: Commit any fixes**

Stage only the files you changed by name. Commit as `fix(app): <what>` with the counts from Step 1. If nothing changed, there is no commit.
