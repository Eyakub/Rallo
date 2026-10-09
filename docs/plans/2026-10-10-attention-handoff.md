# Handoff: reminder attention, eye breaks, update badge

> Generated: 2026-10-10 (Asia/Dhaka)
> Project: Rallo (`git@github.com:Eyakub/Rallo.git`), branch `feat/attention-breaks`
> Session summary: designed three features with the user, built and verified
> the update badge, wrote and accepted two specs, wrote two implementation
> plans. Plan execution has not started.

## Goal

Ship one release from `feat/attention-breaks` containing:

1. **Update badge + default-on update check** (0020). Done.
2. **Reminder attention** (0021): when a note reminder or an agent long-wait
   alert fires, the pet comes to the middle of the screen with a bubble
   (Done / Snooze / Open), a chosen chime plays and the banner sticks, the
   alert repeats until handled (capped), and screen edges can glow. Built by
   plan 1.
3. **Eye breaks** (0022): the 20-20-20 rule. Every 20 min of screen time a
   10 s warning pill, then every display goes black for 20 s with the pet,
   a countdown and a tip. Configurable in a new Settings › Breaks tab and
   from the menu bar. Off by default. Built by plan 2, after plan 1.

Release (version bump, notes, `scripts/release.sh`) happens only when the
user says so.

## Current State

Branch `feat/attention-breaks` (pushed to origin), off `master` at `0b5e74f`:

| Commit | What |
|---|---|
| `2d4d0e1` | feat(menu): update badge on the menu bar paw + daily check on by default (fast-forwarded in from `feat/update-badge`) |
| `77a6c9c` | docs: specs 0021 + 0022 and mockups |
| `1439996` | docs: accept 0021 and 0022 |
| `f70f7cd` | docs(0021): re-alert after snooze, seed due IDs at launch and wake |
| `d92ff58` | docs(plans): plan 1 (alerts) and plan 2 (eye breaks) |
| (this file) | docs(plans): handoff |

**Working (verified on the first Mac):**
- Update badge: Swift tests 358 passed, 0 failed at `2d4d0e1`
  (`xcodebuild … -configuration Release -derivedDataPath build/DerivedData.noindex test`).
  Badge seen in the real menu bar in Dark and Light (scratch instance with
  `RALLO_PREVIEW_UPDATE=9.9.9`), next to the installed app's plain paw; the
  "Update to Rallo 9.9.9…" item sits at the top of the menu.
- Specs 0021 and 0022 are **accepted** by the user.

**Not done:**
- Plans 1 and 2: no task executed. Their code has never been compiled.
- The user has **not yet chosen the execution method** (see Next Steps 3).
- A light menu bar was never seen: the first Mac's display has a notch and
  its terminal runs full screen, so the menu bar stays black in both modes.

## Files in Play

| File | Why it matters |
|---|---|
| `docs/decisions/0020-update-badge-and-default-check.md` | Badge + default-on check decision (amends 0011). Done. |
| `docs/decisions/0011-update-check.md` | Gained "Amended by 0020". |
| `docs/decisions/0021-reminder-attention.md` | Spec for plan 1. Accepted. Read it whole. |
| `docs/decisions/0022-eye-breaks.md` | Spec for plan 2. Accepted. Read it whole. |
| `docs/mockups/reminder-attention.html` | Approved mockup: summon, sticky banner + chime, nag timeline, edge glow, Settings › Alerts. Open in a browser; images load from `assets/pet/rallo/`. |
| `docs/mockups/eye-break.html` | Approved mockup: cycle, warning pill, the three black-screen styles (B "With Rallo" chosen), multi-display, toast, menu, Settings › Breaks. |
| `docs/plans/2026-10-10-attention-1-alerts.md` | Plan 1, 16 tasks (3,481 lines). Task 1 = spikes S1–S5. Contains "API this plan produces for plan 2". |
| `docs/plans/2026-10-10-attention-2-eye-breaks.md` | Plan 2, 13 tasks (3,209 lines). Task 1 = compile check of plan 1's API; Task 2 = spike S6. |
| `docs/plans/README.md` | Plans index; status table for both plans at the end. |
| `apps/macos/Rallo/App/StatusMenuController.swift` | Badge: `pawImage(updateAvailable:)`, `setUpdateBadge(_:)`, tooltip merge. Plan 2 adds eye-break menu items here. |
| `apps/macos/Rallo/App/UpdateChecker.swift` | `isEnabled` defaults on; `RALLO_PREVIEW_UPDATE` scratch-only override; injectable `UserDefaults`. |
| `apps/macos/Rallo/App/AppCoordinator.swift` | Badge wiring; both plans wire their coordinators here. |
| `apps/macos/RalloTests/UpdateCheckerDefaultsTests.swift`, `StatusMenuBadgeTests.swift` | Badge tests. |
| `private/rallo-macos-build-plan.md` | **Gitignored.** The authoritative product spec; 0021 overrides its line "No sound by default, … screen roaming …" for alerts only. See Key Constraints about copying `private/`. |
| `private/docs/progress.md` | **Gitignored.** Progress log; the last section ("Update badge + attention/eye-break design, 2026-10-10") summarises this session. |

## What Has Been Tried (and Why It Failed)

### Menu item icon on "Update to Rallo X…"
- **What:** `NSMenuItem.image = NSImage(systemSymbolName: "arrow.down.circle")`.
- **Why it failed:** It didn't render in the status menu on macOS 27. The
  gear on "Settings…" is drawn by the system, not by Rallo. Dropped;
  recorded in 0020.

### `#if DEBUG` overrides for manual checks
- **What:** a debug-only fake for "update available".
- **Why it failed:** Swift tests and scratch builds use the **Release**
  configuration (README test command), so `DEBUG` is never set. The pattern
  is a scratch-only env var honoured only when the instance is not on the
  default data dir (`UpdateChecker.allowed == false`). Plan 2 uses the same
  pattern for `RALLO_EYE_BREAK_SECONDS`.

### Capturing the menu bar
- **What:** `CGWindowListCopyWindowInfo` for the status item, and
  `screencapture -R` of the top strip.
- **Why it failed:** status items aren't windows the app owns, and a
  full-screen app hides the menu bar (the capture came out black). What
  worked: launch the scratch build with `--demo-appearance dark|light
  --demo-open menu` (opens the status menu, which reveals the bar), then
  `screencapture -x` and crop.

### `onDueBoundary` as the reminder trigger (caught in review, never built)
- **Why wrong:** `PetStateDriver` fires it only when the due count goes from
  zero to some, so a reminder coming due while an older one is still due
  would be missed. 0021 §2 now says: diff due IDs on every recompute,
  remove IDs that leave the list (so snooze-then-due re-alerts), seed all
  due IDs at launch and wake.

### `CGEventType.null` for idle time (caught in review, never built)
- **Why wrong:** "any input" is `kCGAnyInputEventType`, in Swift
  `CGEventType(rawValue: ~0)!`. Fixed in 0022 §2.

### Headless Chrome Light-mode render of `docs/mockups/`
- **What:** `--headless=new --screenshot`.
- **Why it failed:** it followed the system's Dark Mode, so the "light" shot
  was dark. Untested suggestion: `--blink-settings=preferredColorScheme=1`
  (which value means Light is unverified). The user approved the designs from
  the live companion, so this is cosmetic only.

## Current Best Theory

The plans are complete and argue from the accepted specs. The risky unknowns
are isolated as spikes with written fallbacks:

- Plan 1 Task 1, S1–S5:
  - S1: `INFocusStatusCenter` in the self-signed build. S1b: does re-adding a
    delivered request's identifier alert again?
  - S2: `NSUserNotificationAlertStyle` default.
  - S3: bundled `.caf` with `UNNotificationSound(named:)`.
  - S4: CoreAudio and CoreMediaIO "running somewhere" without a prompt.
  - S5: the System Settings deep link.
- Plan 2 Task 2, S6: a `.screenSaver`-level overlay over full-screen Spaces,
  Esc after `NSApp.activate`, focus restore, and ⌥⌘Esc reachable.

Each spike-dependent piece sits behind one seam, so a failed spike changes
one "Only if S# failed" task. The plan writers flagged compile risks:
- plan 1: `AlertSound.none` vs `Optional.none`; the plan pins
  `AlertSound.none` in comparisons.
- plan 2: `_ =` discards in closures, the `NSAnimationContext` completion's
  sendability, and ICU's `\u{202F}` before "PM" in a test, which is
  normalised already.

## Next Steps

1. **On the new PC:**
   ```bash
   git clone git@github.com:Eyakub/Rallo.git   # or: git fetch origin
   cd Rallo && git checkout feat/attention-breaks && git pull
   export PATH=/opt/homebrew/opt/rustup/bin:$PATH
   cargo test --workspace
   (cd apps/macos && xcodegen generate)
   xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release \
     -derivedDataPath build/DerivedData.noindex test
   ```
   Expect Swift 358/0 (Rust count unchanged from master). If `xcodegen` or
   `rustup` is missing, install them first (see `README.md`, "Build").
2. **Make sure `private/` exists** on the new PC (copy it from the first Mac;
   it's gitignored). Without it the agent loses the authoritative build plan
   and `private/docs/progress.md`. Everything this work needs from it is
   summarised in this file and in 0021's Context, so work can proceed if
   it's missing, but the repo's CLAUDE.md expects it.
3. **Ask the user for the execution method**, unless their first message
   says it:
   - **Subagent-driven** (recommended: 29 tasks, plan 2 depends on plan 1's
     API, a wrong pet or focus change is costly to ship). Use
     `superpowers:subagent-driven-development`.
   - **Native.** Use `superpowers:executing-plans`.
4. Execute **plan 1** from Task 1. Spike results go into 0021 under
   "## Verified" before any feature task. Run every "Only if S# failed" task
   whose spike failed. Its Needs-a-human list goes to the user: approve the
   three chimes by ear, the Focus permission prompt, Reduce Motion, and the
   Light/Dark screenshots.
5. Execute **plan 2** from Task 1 (compile check of plan 1's API; if it
   fails, stop and report rather than renaming).
6. Update the status table at the end of `docs/plans/README.md` and
   `private/docs/progress.md` after each plan.
7. **Release:** only when the user says so. Write
   `docs/releases/<version>.md` (current release is 0.13.0; the user picks the
   next number), then `scripts/release.sh X.Y.Z` (dry run), then `--publish`.

## Key Constraints

- **Repo rules (`CLAUDE.md`):**
  - Never hand-edit `apps/macos/Rallo/Generated/` or `apps/macos/Rallo.xcodeproj`.
  - Tests and manual checks use `RALLO_DATA_DIR` / `--data-dir`, never the
    real data dir.
  - Build into `build/DerivedData*.noindex`. Run `lsregister -u` on scratch
    builds.
  - Never `--install` over `~/Applications/Rallo.app`.
  - Pet window level and collection behaviour are fixed by 0002; the summon
    only moves its origin.
  - UI changes: click through them and screenshot **both Dark and Light**.
- **Commits:** conventional, author `eyakubsorkar@gmail.com`, **no AI
  attribution and no Co-Authored-By trailer** (repo rule overrides tool
  defaults). Stage named paths only. Never `git add -A`.
- **Untracked, not ours:** `assets/pet/rallo/launch-kit/` (5.3 MB) and
  `marketing/` (4.1 MB) on the first Mac belong to the user. They are not
  committed and not pushed. Ask before touching them.
- **User decisions, 2026-10-10** (already in the specs; don't re-ask):
  - On by default after the update: summon, chime, sticky banner, nag (every
    2 min, up to 5). Edge glow off. Eye breaks off but visible in the menu.
  - A Focus pauses summon, glow, and nag (via `INFocusStatusCenter`).
    Fallback if S1 fails: only the sound obeys Focus.
  - In a call (camera or mic in use, ignoring Rallo's own voice typing):
    the bubble shows "Reminder" without the note text, the glow runs, and
    nag rounds are silent.
  - A hidden pet still appears for the summon, then hides again.
  - Eye breaks: style "With Rallo"; keep the camera/mic hold; strict mode
    exists but holding Esc for 3 s always ends a break; eye breaks ignore
    Focus; a pause lives in memory only.
  - Update check on by default; the badge is option A (template arrow at
    the paw's bottom-right, menu bar colour).
  - Both features and the badge ship in **one release**.
- **Plan-writer choices the user hasn't confirmed** (raise them if they
  matter):
  - The pet keeps its current pose during a summon; the mockup showed a wave.
  - Done in the bubble marks the note done.
  - The Focus prompt is skipped on `--background` launches.
  - In strict mode the pill hides +5 min and Skip.
- **Delegation policy (user's global CLAUDE.md):** the orchestrator plans
  and reviews. **Explore** (Haiku) does searches, **worker** (Sonnet) does
  decided implementation, and **hard** (Fable) only for the single hardest
  sub-problem.
- The user reads in a terminal and prefers short replies. For UI choices,
  show rendered visuals (the brainstorm companion worked well).

## Memory Pointers

- claude-mem and Claude's file memory are local to the first Mac. On a new
  PC they hold nothing from this session unless claude-mem cloud sync is set
  up. This file is the complete briefing.
- Searches worth re-running, if the memory is available:
  `reminder attention summon`, `eye break 20-20-20`, `update badge paw`.
