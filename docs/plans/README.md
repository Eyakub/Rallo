# Folders and tags: plans and their status

## Handover (2026-10-10)

| Plan | Execution |
|---|---|
| 1 core + CLI | **Done** (`8011e33..b11789f`). |
| 2 panel | **Done** (`b11789f..a1f52cd`). |
| 3 window | **GUI pass done (Dark), fixes applied** (`a1f52cd..HEAD`). Swift 354/0, Rust 455/0. A few checks need a human: see "Plan 3 GUI pass: results" below. |

Plan 3 ran over SSH, which has no Screen Recording or Accessibility, and the
cmux socket refuses outside processes. So no task got its click-through or
Light/Dark screenshots. Each UI task instead got a headless launch smoke:
- the app comes up;
- `activation_policy` goes `regular`;
- `windows.json` shows the window "Notes" at 1140×690, level 0;
- it survives CLI edits.

The GUI pass then ran on the first Mac; see "Plan 3 GUI pass: results" below.

### Plan 3 GUI pass: results (2026-10-10, on the first Mac)

Four agent batches drove the scratch build:
- **A:** window, Dock, expand button, panel regressions and pet;
- **B:** sidebar, delete sheet and list;
- **C:** editor, toolbar and reminder pill;
- **D:** a final re-check of every fix.

They drove it per pid through AX actions and per-pid keys, and took window screenshots. The shots are in `private/docs/folders-3-shots/`, which is gitignored. Five fix rounds followed (`f84c37d..e3cd510`), each code-reviewed and re-checked in the app.

**User decisions made during the pass:**
- **No system blue anywhere.** Selection, hover and highlight use a soft rust wash (`Theme.selection` when focused, `selectionSoft` when not), with ink text and a semibold sidebar label. The user picked this from a rendered comparison of three options.
- **Rust accent.** Rallo has its own `AccentColor` (`#B4501F`), so focus rings and default buttons are rust.
- **Native menus stay native.** Native context menus now highlight in solid rust with white text, not blue. The user was told this; a soft wash there would need custom menus.
- **Dark only.** The user only cares about Dark for now, so UI checks run in Dark only.

**Fixed:**
- **Editor wrap.** Editor text wrapped at about 75 pt, because `sizeThatFits` mutated the text container on SwiftUI's probe sizes.
- **Pet on hide.** The pet vanished when Rallo was hidden. It now has `canHide = false`, recorded in ADR 0002.
- **Sidebar selection.** The selection is drawn by Rallo, with ↑/↓ that leave the rename field alone. Rows line up with their headers. The list, footer and title-bar strip share one material.
- **Light toolbar strip.** It was white; it now uses a transparent title bar with column gradients and a soft divider.
- **⌫ in the list.** It did nothing: SwiftUI's `.delete` is U+0008, but the Mac key sends U+007F.
- **Delete after a delete.** Deleting the selected note now advances to the next one.
- **Delete sheet.** Delete Notes is red. The empty folder's Delete is red and not the default.
- **Row labels.** List rows have accessibility labels and a Mark as Done action.
- **Error banner.** It moved to the bottom. "Weren't saved" and refusals stay until the next success, and an ordinary error never replaces them.
- **Large paste.** The 70 KB paste error now shows in the banner.
- **Toolbar.** It rests under the New Folder card, and Add Image is disabled at 10 images.
- **One-line labels.** The list's reminder label, and the panel's expanded row (meta, then actions on their own line), no longer wrap mid-word.

**Needs a human (not drivable without moving the pointer or changing system settings):**
- **IME (§7):** Japanese and Bangla composition across the 0.6 s timer and every note switch.
- **Drag and drop:** a row onto a sidebar folder, text from another app, and image tiles out.
- **Live system Light/Dark switch** with a note open.
- **Full screen,** then the frame restore after leaving it.
- **VoiceOver:** reading rows, the Mark as Done action and the dropdown.
- **Clicks AX couldn't press:** the "N done" row toggle, the toast's Undo click and a real click-away on rename.
- **11th image through the Add Image picker.** The CLI refusal was checked.

**Deferred minors:**
- **Design question:** a one-line note shows as body text in the editor, not as a title. That follows spec §11 ("the title, when there is one") and matches the panel. Apple Notes always titles the first line.
- **Sort order:** folders sort plainly alphabetically ("Folder 1, Folder 10, Folder 2"); natural sort would read better.
- **Missing test:** for `letGoRaisedMessage` when a select raises a sticky message identical to the live one.
- **Toolbar divider:** the 1 px divider overdraws the column's top pixel.
- **Sidebar inset:** the negative inset compensates for the sidebar style's ~12 pt indent and may drift across macOS versions.

### Plan 3 GUI pass: the original checklist

Launch the scratch build per plan 3's **Scratch run**. It now resolves the
scratch dir with `pwd -P`: a CLI-started instance reports `/private/var/…`,
and a `pkill` on the `/var` spelling missed it, so it kept `app.lock`.

1. **Window and Dock.**
   - On first open from the status menu, the Dock icon appears and the menu bar shows Rallo/File/Edit/Window.
   - The menu bar repaints on close.
   - Settings or the panel stays key after ⌘W.
   - Minimise, then the Dock icon brings it back.
   - The minimum size clamps.
   - The frame restores after relaunch and after full screen.
   - ⌘N/⇧⌘N/⌘F are dimmed off-window.
   - ⌘Q and the status-menu Quit work.
2. **Expand button.**
   - It sits in the panel's title bar, top right, clear of the panda's ear.
   - It clicks rather than drags.
   - It is disabled under the panel's New Folder card and scope menu.
   - It opens the window on the panel's scope with the expanded note.
   - With a fresh conflict in the window, it must not drop the typing.
3. **Sidebar.**
   - Counts are right.
   - New Folder (+, footer, ⇧⌘N) starts with the caret in the field and the name selected.
   - Return renames; click-away **commits** a changed name (a refusal shows in the banner); Esc cancels.
   - The context menu offers only Rename and Delete Folder….
   - Drag a list row onto a folder: the target highlights and the move toast appears. Text dropped from another app is ignored.
   - With a fresh conflict, clicking another folder snaps the highlight back.
4. **Delete sheet.**
   - With notes: "It holds N notes", Keep Notes is the default, Delete Notes is red.
   - A folder holding only done notes says "It holds 1 note".
   - An empty folder: "The folder is empty." Delete is rust, not red; check it reads right.
   - `rallo folder delete` while that folder is selected → the window falls back to Notes.
5. **List.**
   - Headers and counts are correct.
   - Groups show Today, Yesterday, Previous 7 Days and month.
   - Row time labels and the bell show.
   - The 38 pt thumbnail shows.
   - The selection highlight shows.
   - The N done row works.
   - ↑/↓ scroll the selection into view and page past 100.
   - ⌫ deletes only in the list.
   - Undo works in the toast, and ⌘Z belongs to the text.
   - Deleted rows offer Restore only.
   - Search covers every folder.
   - Paging past 250 shows exact counts.
   - VoiceOver opens a note from a row.
6. **Editor.**
   - The title is 24 pt rounded semibold.
   - Body text is 14.5 pt.
   - `#tags` are rust, `#كلمة` included.
   - Text wraps after a resize.
   - The caret stays visible at the end of a long note.
   - Saving: 0.6 s after typing, and at once on switch, ⌘W and ⌘Q.
   - Select all and delete, then leave: the text comes back.
   - Conflict bar: test Show Theirs and Keep Mine. A switch is declined once, then works.
   - A paste over 70 KB shows its error.
   - Pasting from Safari gives plain text.
   - Toggling Light/Dark live with a note open recolours the text.
   - Deleted notes are read-only.
   - Image tiles: Quick Look, drag-out, and Remove followed by Undo.
   - ⌘N focuses the editor, both from the empty state and with a note open.
   - Switching folders and then clicking a note doesn't steal focus.
7. **IME (Japanese and Bangla).**
   - Compose across the 0.6 s timer: nothing saves mid-word.
   - Switch notes mid-word using a click, toolbar New Note, Show Theirs, Delete, ⌘W and ⌘Q. Each time the word lands in the old note, never in the new one.
8. **Toolbar and reminder pill.**
   - Items sit over their own column.
   - Mark as Done and Reopen work.
   - Remind Me presets, the pill, Cancel Reminder and the Custom… popover work. Check the panel's popover too.
   - Add Image: images only, and an 11th image is refused.
   - Move chip, and New Folder… on the in-window card. With the card up, nothing behind it reacts. Esc cancels and focus returns.
9. **Panel regressions.**
   - Esc on the panel's New Folder card closes only the card.
   - Remind Me shows 3 presets and Custom….
   - The panel toast still takes ⌘Z.
   - Thumbnails are 56 pt.
10. **Pet (user's request this session).**
    - It is 112×92.
    - Curled poses (sleep, drowsy, content) sit at 85% on the same ground line.
    - Badges show "9+".
    - `windows.json` level is 25 and collection behaviour is 337.
    - While the window is open (Dock app), Hide from another app must not hide the pet (ADR 0002).
11. **Screenshots.** Take Light and Dark of every changed state into `private/docs/folders-3-shots/`. Then `lsregister -u` the scratch build.

### Plan 3 rulings (decided while executing; the spec is binding)

- **R1–R9:** fixed plan drift against plan 2 as built.
  - Release 2's `deleteFolder(id)` is reused.
  - `RemindPreset.swift` already existed.
  - `onExpand` lives in `NotesViewModel.swift`.
  - The expand button is fenced like the rest of the panel.
  - One scratch-aware `defaults` is shared by the panel and the window.
  - Move-menu New Folder… uses a window-owned `FolderNamePrompter` behind a `.folderNamePrompt` modifier, and Esc works on the card.
  - Rename stays inline (spec §11).
- **R11.** When leaving a note hits a new conflict or refusal, the selection change is declined. The bar or the error shows and the typing stays. A bar the user already saw doesn't block. Close and quit keep the "weren't saved" message.
- **R13.** A late save never lands on the next note (`showCount` guard plus a running-save token).
- **R14.** New FFI `getItem(id:)` (`369a9b0`). An open note whose row leaves the list stays open; it is cleared only when it's deleted or gone. So a user's own move out of a folder scope keeps the note open.
- **R15.** Undo resolves the note's latest revision through `fresh()`.
- **R16.** The expand button sits in the panel's title-bar strip.
- **R17.** Before any save, leave or switch, the input method's word is committed into the current note, as AppKit does on focus loss.
- **R19.** A focus request is keyed to the shown target (`focusShow`).
- **R20.** Click-away commits a changed folder name; Esc cancels.

### Plan 3 deferred minors worth a look later

- **Paging.**
  - The sentinel now carries the reload generation.
  - Search paging during the 200 ms debounce can briefly append rows from the old cursor.
- **Undo manager.** `removeAllActions` clears the window-wide undo manager, which field editors share.
- **Image tiles.**
  - The 210 pt and 38 pt decodes look soft for portrait and panorama images.
  - Deleted notes still offer Remove Image; the core refuses.
- **Add Image.**
  - It uses `runModal`.
  - Partial read failures are silent.
- **Quit.**
  - A conflict or refusal at quit drops the typing silently.
  - ⌘Q from the panel drops the panel's unsent draft.
- **Tests.** A few tests would also pass on the code they replaced; each task report names them.
- **Final-review residuals.**
  - `opened()` skips the panel's note when the requested scope fell back during the reload.
  - `keepMine`'s fallback isn't guarded against a switch mid-await.
  - The list row's VoiceOver label: check in the pass, and add `.accessibilityLabel(item.name)` if it reads a bare "button".
  - `loadMore` can overwrite a reload that started earlier.
  - `fresh()` doesn't consult `lastSaved` (a stale-revision toast, no data loss).
  - A stale rename banner remains after an unchanged-name click-away.

### Side task: smaller pet (`54ac961`)

- The user asked for this mid-plan.
- The pet is now 112×92 pt (was 143×118).
- Curled poses (sleep, drowsy, content) are drawn in an 85% bottom-centred frame. Grumpy stays full size, because it uses the sitting body.
- Badge offsets are scaled. The badge diameter is 18 pt and its text 10 pt.
- ADR 0002's Size row is updated to match.

## Plan 2 notes

Plan 2 and 3 execution ledgers live in the gitignored `.superpowers/sdd/`
on the first Mac; this file is what travels.

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

### Plan 3: drift fixed before executing (`9edaef7`)

Kept for the record; the plan text now reflects all of it.

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

# Reminder attention and eye breaks: plans and their status

Branch `feat/attention-breaks`, which also carries the update badge (0020,
`2d4d0e1`) so both ship in one release.

| Plan | Spec | Execution |
|---|---|---|
| [1 alerts](2026-10-10-attention-1-alerts.md) | 0021 | Not started. Task 1 runs spikes S1–S5 first. |
| [2 eye breaks](2026-10-10-attention-2-eye-breaks.md) | 0022 | Not started. Needs plan 1 merged; Task 1 checks plan 1's API, Task 2 runs spike S6. |

The two plans share a frozen API ("API this plan produces for plan 2" in
plan 1). Plan 2 compile-checks it before anything else.
