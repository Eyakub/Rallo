# 0001 — macOS native feasibility (M0)

- **Status:** M0 exit reached for everything listed under *Verified*; items
  under *Not yet verified* are open and tracked, none contradicts the
  architecture.
- **Date:** 2026-09-30
- **Environment:** MacBook Pro Mac15,6 (Apple M3 Pro, 18 GB), macOS 27.0
  (26A428), Xcode 26.3, Rust 1.98.1, AC power, Low Power Mode off. Displays:
  two external 1920×1080 (@1×); built-in Retina intermittently attached.
  App installed at `~/Applications/Rallo.app`, ad-hoc signed with hardened
  runtime, bundle ID `com.razlio.rallo`.

The architecture (Rust core + CLI, SQLite, UniFFI, Swift/AppKit, Core
Animation) holds. No framework change is needed.

## Verified

### Build and bridge
- Cargo workspace → static library → UniFFI Swift bindings → Xcode app via
  XcodeGen; the CLI is embedded at `Contents/Helpers/rallo`; `codesign
  --verify --deep --strict` passes.
- One typed core operation called from both sides: `create_note` from the
  CLI and from Swift (`RalloTests/CoreBridgeTests`, 6 tests: lossless text
  round trip incl. emoji/quotes/newlines, structured `RalloError` codes,
  64 KiB boundary, newer-schema refusal, preference persistence, instance
  lock exclusivity, worker-thread execution off the main thread).
- Toolchain findings (see `architecture.md`): release LTO emitted bitcode
  Xcode's LLVM could not read; Xcode's `ld` missed symbols through the Rust
  archiver's index until `xcrun ranlib` rebuilt it.

### Pet window (config in 0002)
- Nonactivating `NSPanel` at `.statusBar` (25), behaviour 337, never key,
  sized to the art (110×92 pt). Rendered on screen and captured.
- Visible over another app's **native full-screen Space** (a test app entered
  full screen on the main display; both Rallo pets remained on screen at
  layer 25).
- Multiple displays: a saved placement on the second display is honoured; an
  off-screen placement falls back to the default; a placement straddling a
  display edge is clamped fully inside; `rallo show --reset-position`
  restores the default. Crisp @1× rendering on a 1080p display.

### Launch, focus, and instances
- `rallo show` launches via `open -g -n`; the frontmost app was unchanged at
  every check (0–3 s) and `NSApp.isActive == false`.
- 10 concurrent `rallo show` → exactly one surviving process per data
  directory; surplus processes exit through the `flock` instance lock.
- **Found and fixed:** LaunchServices keeps one instance per bundle, so
  `open -a` without `-n` turned a launch for another data directory into a
  reopen of the running instance; and reopen events queued during startup
  were misread as user reopens. Now: `-n` plus a per-data-directory lock;
  reopen counts as a user request only if its sender resolves to a GUI app.
- Visibility contract: hide → quit → hidden note (app not launched) →
  background launch (stays hidden) → interactive relaunch (stays hidden) →
  `show` (visible) → note while visible and running (signal only) → note
  while visible and closed (passive background restore). All as specified.
- Signal path: pet hides/shows ≈50 ms after the CLI exits (upper bound;
  includes polling the window list). CLI `hide`/`show` themselves take 6–13 ms.

### Notifications (probe under the installed identity; see `reminder-semantics.md`)
- Pending limit **100 per app**; over it `add()` reports no error and an
  **arbitrary** request is evicted. The 32-reminder product cap is well
  inside; readback verification is mandatory.
- `nextTriggerDate` matched the intended UTC second for all requests up to
  256; sub-second deadlines round up; an **elapsed** instant fires
  immediately.
- Submit / inspect / cancel: requests read back as pending; a cancelled
  request is neither pending nor delivered after its deadline.
- **App exited:** a request accepted while Rallo was running fired at its
  deadline with no Rallo process alive.
- **Restart:** a pending request survived app quit and relaunch, still read
  back as pending, and fired on time.
- **App running hidden:** the request was delivered; the app's
  `willPresent` delegate was *not* called (re-check once authorized).
- All of the above ran with authorization `not_determined`: acceptance and
  the delivered list do not prove presentation.

### Baseline measurements (Release, ad-hoc signed)

| Scenario | Budget | Measured |
|---|---|---|
| CLI `note` (durable commit, `fullfsync`), fresh process, 100 runs | p95 ≤ 75 ms | p50 15.8 ms, **p95 22.6 ms**, max 24.5 ms |
| CLI `list` (small DB) | — | p95 3.6 ms |
| CLI `--version` | — | p95 3.9 ms |
| Hidden app, 10 min | ≤ 0.2 % of one core | **0.063 %** |
| Visible idle pet (panel closed), 10 min | ≤ 0.5 % | **0.067 %** |
| Physical footprint hidden / visible | ≤ 80 / ≤ 120 MiB | **14.0 / 14.0 MiB** (28 MiB after the notes panel had been opened) |

Method: `scripts/benchmark-cli.sh` (hyperfine, `-N`, 5 warmups) and
`scripts/measure-app.sh` (cumulative CPU time of the lock-holding process;
`footprint` physical footprint, not RSS). Results in `build/benchmarks/`.
`fullfsync=ON` meets the budget, so the durability trade-off was not needed.

## Not yet verified (open)

| Item | Blocker / plan |
|---|---|
| Notification authorization prompt, banner presentation, click → app opens the current item | Needs the user to grant permission (menu bar → Enable Notifications…) and click a banner |
| Focus while typing in another app; click and drag with real input; Mission Control; ordinary Space switch; Stage Manager | Needs Accessibility for the test driver (real events) or a manual pass |
| Display reconfiguration/sleep-wake | Needs a physical reconfiguration pass |
| Minimum OS (macOS 14) | No macOS 14 environment available |
| Intel | No Intel hardware; first release is Apple Silicon only |
| Cold-cache first launch | Needs a reboot/purge pass (reported separately from warm numbers) |
| Signing / notarization | No Developer ID credentials; distribution blocked, local work unaffected |

## Consequences
- Scheduling status must combine native acceptance (readback), authorization
  state, and deadline; `add()` success alone never means "scheduled".
- Reconciliation must never submit an elapsed deadline.
- One app process per data directory; tests always pass `--data-dir`.
