# Folders and tags: plans and their status

## Handover (2026-10-09)

| Plan | Execution |
|---|---|
| 1 core + CLI | **Done** (`8011e33..b11789f`). |
| 2 panel | **Done** (`b11789f..HEAD`). Swift 216/0, Rust 454/0. Every task had a review and a Light/Dark click-through. A final whole-branch review followed, and its fixes are applied. |
| 3 window | **Not started.** Fix the drift list below in the plan text first, then execute it the same way, when the user asks. |

Execution notes, rulings and per-task reports lived in the gitignored
`.superpowers/sdd/2026-10-08-folders-2-panel/` on the first Mac. This
section is what travels.

### Plan 2 as built: where the code differs from its plan text

These are the user's decisions after a design review against the mockup. They
win over the plan text, and spec 0019 §10 was updated to match (`c207a57`).

- **Chip menu.** It is now a custom in-panel dropdown, `Notes/FolderScopeMenu.swift`,
  matching mockup B: 214 pt wide, anchored under the chip, never crossing the
  panel edge. It has a folder icon per row and the count right-aligned. Hover and
  keyboard use the system-accent highlight. ↑/↓/Return/Space/Esc work, and a click
  outside closes it.
  - `ScopeMenuItem` is `{scope, title, count, symbol, checked}`.
  - `MenuHighlight` does the keyboard wrap.
  - `NotesViewModel.scopeMenuOpen` holds the open state.
- **New Folder….** It is now an in-panel card on a blurred, scrimmed panel, built
  from `FolderNamePrompter` (`Notes/FolderNamePrompter.swift`, an
  `ObservableObject`) and `FolderNameOverlay`.
  - `ask(title:initial:confirmTitle:validate:) async -> String?`.
  - `submit`, `cancel`, `error`, `errorCount`, `isSaving`.
  - The core's error shows under the field. The card shakes, and VoiceOver
    announces the error.
  - The NSAlert is gone: `runModal` inside a main-actor job deadlocked the
    validate task.
- **Move to.** The submenu stays native (mockup C).
  - `FolderMenus.cut(_:)` cuts names over 24 characters to 23 + "…".
  - The composer placeholder uses the same cut. Characters are graphemes, so a
    ZWJ emoji or Bangla conjunct is never split.
- **Notification click.** `NotesViewModel.reveal(_:)` switches the panel to All
  Notes when the note isn't in the current scope, then highlights the note and
  scrolls to it.
  - This is unit-tested only; a real notification click was never driven.
- **Defaults suite.** `PanelDefaults` (`Notes/PanelDefaults.swift`) picks the
  defaults suite by data-dir path. Any dir other than
  `~/Library/Application Support/Razlio/Rallo` uses `com.razlio.rallo.scratch`,
  so `RALLO_DATA_DIR` alone can't write the real app's `notesPanelScope`.
  `isScratch` still drives everything else.
- **Overlay fence.** While the dialog or dropdown is up, nothing behind it reacts:
  the content and toast are disabled and accessibility-hidden, and the swipe and
  Space→Quick Look monitors skip.
- **Theme tokens.** New: `menu`, `menuStroke`, `scrim`, `onRust`, `card`.
- **File moves (pure):**
  - `NotesViewModel`, `Toast` and `StagedImage` → `Notes/NotesViewModel.swift`.
  - `RemindPreset` and `ReminderSnapshot.deadline` → `Notes/RemindPreset.swift`.
  - `SwipeSide`, `OpenSwipe` and `SwipeMetrics` → `Notes/SwipeMetrics.swift`.
- **CoreClient.** Added `deleteFolder(_ id: String, keepNotes:)`. Only the tests
  use it so far.

### Plan 3: drift to fix before executing

Its Task 1 preflight greps fail at HEAD.

- **:198.** It greps `static func ask` in `FolderNamePrompt.swift`. Use a
  window-owned `FolderNamePrompter` + `FolderNameOverlay` instead, with
  `confirmTitle: "Rename"` for Rename.
  - **:21 and :4135** still describe the old NSAlert enum.
- **:199.** It greps `private(set) var scope` in `Notes/NotesView.swift`. That
  line is now in `Notes/NotesViewModel.swift`.
- **:21.** `Toast` is now in `NotesViewModel.swift`.
- **:200 and :3337.** They anchor on AppCoordinator's panel-model line. That line
  now uses `PanelDefaults`, so re-anchor it. The window frame (M4 + M5) should
  share the same path-based suite.
- **:351** adds `deleteFolder(_ folder: FolderSnapshot, keepNotes:)`. Reuse
  release 2's `deleteFolder(_ id: String, keepNotes:)`; don't add a second API.
- **:1853-1913** create `RemindPreset.swift`. It already exists.
- **:3983** expects `ReminderSnapshot.deadline` in `NoteRow.swift`. It is now in
  `RemindPreset.swift`.
- **Deferred from plan 2's final review, to do in plan 3:**
  - Make the overlay self-contained for the window as a
    `.folderNamePrompt(prompter)` modifier. It bundles the blur, disable,
    accessibility hiding, Esc, focus restore and toast fence.
  - Add `.onExitCommand` on the card.
  - For Rename, select all from `onChange(of: focused)`.
- **UI checks (user's rule).** Drive the behaviour once, in Light. In Dark, take
  screenshots of the changed states only. Show one validation error at most.
  - Launch scratch builds with `env -u RALLO_DATA_DIR open -n -g <app> --args
    --data-dir <dir> …`. Otherwise `open` passes the env var and the instance
    isn't scratch.
  - Send keys and clicks per pid, never through the global HID tap: typing in
    the terminal leaks into a frontmost scratch app.

### Plan 2 deferred minors

- **Tests.**
  - `createReminderWithImages` and `cancelReminder` are only pinned by
    signature.
  - The `TagTintTests` tint helper is weak.
  - No view-model test covers move or undo.
- **Chip.** The chip reads the raw scope for its icon and count before the first
  reload, so it can flicker briefly.
- **Alerts-blocked banner.** It looks only at the scoped list.
- **Reveal.** It falls back to All Notes when the note is beyond the scoped list's
  first 50 rows.
- **Cancel during a save.** Esc pressed during a save that then succeeds still
  creates the folder and switches to it.
- **Tags in a done row.** Tags stay rust while a done row fades to bark.
- **Two folders with a long shared prefix** look the same in Move to, because of
  the cut.
- **Not driven in the UI.** Text selection in a row; the harness couldn't do it.
- **Agent-row swipe.** The agent row's swipe-to-dismiss scroll monitor
  (`AgentsSection.swift`) is not fenced behind the overlays. It acts only while
  its `pointerInside` is set, so a swipe can dismiss an agent session behind the
  dialog only if the pointer was left on that row.
- **Leftover test plists.** Earlier test runs left empty
  `~/Library/Preferences/com.razlio.rallo.tests.*` and `rallo-tests-scope-*`
  plists on the first Mac. They are safe to delete by hand. New runs clean up
  after themselves, except `CloudVoiceTests`.

## Plans and their reviews

Spec: `docs/decisions/0019-folders-and-tags.md` (binding). Mockup:
`docs/mockups/folders.html`. Build order: plan 1 → 2 → 3, each its own
release.

| Plan | Fable review | Review fixes |
|---|---|---|
| `2026-10-08-folders-1-core-cli.md` | `reviews/review-1-core-cli.md` (0 blocker, 2 major, 10 minor) | Applied. Not yet re-verified: run fmt, clippy `-D warnings` and `cargo test --workspace` per task while executing. |
| `2026-10-08-folders-2-panel.md` | `reviews/review-2-panel.md` (1 blocker, 3 major, 7 minor) | Applied. Its "API this plan produces for release 3" section is the authority for plan 3, **except where "Plan 2 as built" above differs**. |
| `2026-10-08-folders-3-window.md` | `reviews/review-3-window.md` (2 blocker, 9 major, 10 minor) | Applied, per the rulings below. Not compiled: build and test per task while executing. |

## Rulings for plan 3

These override the review where they differ:

- Plan 2's names win: `moveItem(_:folderID:)`, `createNote(_:images:folderID:)`,
  `NotesScope.folderScope`, and the `CoreClient` wrappers listed in plan 2's
  "API this plan produces for release 3". Plan 3 adds only wrappers plan 2 lacks.
- Plan 3's test file/class: `RalloTests/CoreClientWindowTests.swift` /
  `CoreClientWindowTests` (plan 2 owns `CoreClientFoldersTests`).
- Paging: the reviewer's `PagedItems` design (B1): reload keeps loaded pages,
  `loadMore` on the last row's `onAppear`, headers from `totalCount`, no "200+".
- `cancelReminder` for Cancel Reminder; `noteCount` for "It holds N notes".
- Window frame saved in the scratch-aware injected `UserDefaults` (M5).
- M6 `undoManager.removeAllActions()` on programmatic text replace; M7
  `makeFirstResponder(nil)` before flushing on ⌘W/⌘Q; M9 File item "Close",
  a real Window-menu "Notes Window" item, window title "Notes".
- Apply every MINOR, including the YAGNI cuts the reviewer names.

Beyond the review, while applying it:

- M4 + M5: Task 9 anchors `AppCoordinator` on release 2's exact panel-model
  lines (Task 1 Step 2 greps for them) and hoists their defaults into
  `private let defaults`, shared by the panel model and the window.
- MINOR 2: ⌘F goes to an `AppDelegate` action that focuses the toolbar's
  `NSSearchToolbarItem` (the review's fallback), not `performTextFinderAction`,
  which would target the editor's text view.
- MINOR 7d: `Theme` gains `NSColor.dynamic(light:dark:)`; `ink`/`rust` wrap
  `inkNS`/`rustNS`.
- Paging: `loadMore` ignores a cursor it is already fetching and a result that
  arrives after the search field changed; new search words start on page 1.

Absolute paths in the plans and reviews (`/Users/eyakub/Desktop/Rallo`, the
`/private/tmp/...scratchpad` dirs) are from the Mac they were written on:
use your clone and any temp dir.
