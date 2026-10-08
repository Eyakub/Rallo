# Folders and tags: plans and their status

Spec: `docs/decisions/0019-folders-and-tags.md` (binding). Mockup:
`docs/mockups/folders.html`. Build order: plan 1 → 2 → 3, each its own
release.

| Plan | Fable review | Review fixes |
|---|---|---|
| `2026-10-08-folders-1-core-cli.md` | `reviews/review-1-core-cli.md` (0 blocker, 2 major, 10 minor) | Applied. Not yet re-verified: run fmt, clippy `-D warnings` and `cargo test --workspace` per task while executing. |
| `2026-10-08-folders-2-panel.md` | `reviews/review-2-panel.md` (1 blocker, 3 major, 7 minor) | Applied. Its "API this plan produces for release 3" section is the authority for plan 3. |
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
