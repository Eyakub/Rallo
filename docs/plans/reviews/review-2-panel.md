# Review: docs/plans/2026-10-08-folders-2-panel.md (HEAD 855c1b1)

Read: spec 0019 §9/§10, the plan, release 1 Task 7, release 3 Task 1/2 + call sites, and the real
Notes/*.swift, CoreClient/CoreWorker, AppCoordinator, Theme, project.yml, Generated/rallo_ffi.swift.
Probed on this toolchain (Xcode 27, Swift 5 mode), outside the repo: the plan's `TagTint.attributed`
passes all seven of its own vectors; captured-`var` mutation inside `Task { @MainActor in }` and
`run.foregroundColor != nil` with SwiftUI+AppKit visible both compile (so they are NOT findings);
header widths measured with ImageRenderer (see MAJOR-2).

Counts: BLOCKER 1, MAJOR 3, MINOR 7.

---

## BLOCKER-1 — Header API block, Task 1 Step 1, Task 2 Step 3, Task 3 Step 1: the assumed FFI is pre-§9-change and will not compile

**Location:** plan lines 17, 32–33 (API block); Task 1 Step 1 lines 216, 247–249, 257; Task 2 Step 3
`openItems(scope:limit:)`; Task 3 Step 1 `FolderFixtures.swift`.

**Problem:** Spec §9 and release 1 Task 7 (lines 5049–5050, 5306–5333, 5616–5650) now produce
`FolderSnapshot { id, name, openCount, noteCount, revision }`, `listItems(kind:scope:tag:limit:cursor:) -> ItemPage`,
`searchItems(query:limit:cursor:) -> ItemPage`, `ItemPage { items, nextCursor, totalCount }`, and
`cancelReminder(id:ifRevision:)`. The plan's Task 1 is explicitly "stop and report if it fails" — as
written it fails on four sites and the executor is told not to fix them. Uniffi naming per
`Generated/`: snake_case → camelCase labels, named variant fields keep their label (`case folder(id:)`).

**Fix (exact Swift):**

Header block, replace the three lines:
```swift
FolderSnapshot(id: String, name: String, openCount: UInt32, noteCount: UInt32, revision: Int64)
ItemPage(items: [ItemSnapshot], nextCursor: String?, totalCount: UInt32)
func listItems(kind: ItemListKind, scope: FolderScope, tag: String?, limit: UInt32, cursor: String?) throws -> ItemPage
func searchItems(query: String, limit: UInt32, cursor: String?) throws -> ItemPage
func cancelReminder(id: String, ifRevision: Int64?) throws -> ItemSnapshot
```
Task 1 Step 1:
```swift
let folder = FolderSnapshot(id: "f1", name: "Work", openCount: 5, noteCount: 7, revision: 1)
...
XCTAssertEqual(try store.listItems(kind: .open, scope: .folder(id: work.id), tag: nil, limit: 50, cursor: nil).items.map(\.id), [note.id])
XCTAssertEqual(try store.listItems(kind: .open, scope: .unfiled, tag: nil, limit: 50, cursor: nil).items.map(\.id), [loose.id])
XCTAssertEqual(Set(try store.listItems(kind: .open, scope: .all, tag: nil, limit: 50, cursor: nil).items.map(\.id)), [note.id, loose.id])
let page = try store.listItems(kind: .open, scope: .all, tag: nil, limit: 1, cursor: nil)
XCTAssertEqual(page.totalCount, 2); XCTAssertNotNil(page.nextCursor)   // the panel reads page 1 only; release 3 pages
...
XCTAssertEqual(try store.searchItems(query: "plan", limit: 10, cursor: nil).items.map(\.id), [note.id])
_ = store.cancelReminder(id:ifRevision:)     // release 3 consumes it; pin it here too
```
Task 2 Step 3:
```swift
func openItems(scope: FolderScope = .all, limit: UInt32 = 50) async throws -> [ItemSnapshot] {
    try await worker.perform { try $0.listItems(kind: .open, scope: scope, tag: nil, limit: limit, cursor: nil).items }
}
```
Task 3 Step 1 fixture:
```swift
FolderSnapshot(id: id, name: name, openCount: open, noteCount: open, revision: 1)
```
(Also drop the Task 1 Step 2 sentence about "release 1 added a required folderId … do Task 2 Step 3 first":
release 1 Task 7 Step 6 already passes `folderId: nil` in `CoreClient`, so that failure can't happen.)

---

## MAJOR-1 — Task 5 Step 1 `FolderNamePrompt`: `NSApp.stopModal(withCode:)` is called from a Task continuation, not from the modal loop's event handler, so the alert can stay up until the next input event

**Location:** Task 5 Step 1, inside `handler.run` → `Task { @MainActor in … NSApp.stopModal(withCode: .alertFirstButtonReturn) }`.

**Problem:** The OK click's action returns immediately (it only spawns the Task). The core call resumes
later on the main queue while `runModal()` sits in `nextEventMatchingMask:` waiting. `stopModal` only
sets the session's stop flag; AppKit documents that from outside an event handler "the loop won't end
until the next event" and that `abortModal()` is the call to use from timers/async work. In practice the
alert hangs after a successful create until the mouse moves over a tracking area or a key is pressed —
exactly the Task 5 step 6 path ("Type `Errands` and OK: alert closes").

**Fix:** The return code is already ignored (`_ = alert.runModal()`; the result travels in `accepted`), so:
```swift
try await validate(name)
accepted = name
NSApp.abortModal()          // wakes the modal loop from a non-event context; runModal returns .abort, which we ignore
```
(Keeping `accepted` as a local `var` captured by the Task compiles on this toolchain in Swift 5 mode —
verified — but moving it onto `ConfirmHandler` as `var accepted: String?` costs nothing and survives a
future strict-concurrency switch.)

---

## MAJOR-2 — Task 5 Step 5(a) header: chip + count line do not fit beside the pet in any empty state

**Location:** Task 5 Step 5(a) (`HStack(spacing: 8) { FolderChip … Text(model.scopeCountLine).fixedSize() }`),
Task 3 Step 4 `countLine(open: 0)`.

**Problem (measured, ImageRenderer, same fonts/paddings as the plan):** column available to the VStack is
360 − 20 − 26 − 96 (pet) = 218 pt. Chip "All Notes" = 101 pt, "Work" = 78 pt, long name clamps at 124 pt
(the `.frame(maxWidth: 124)` + `.fixedSize()` combination does truncate — that part is fine).
"Nothing held right now" at `Theme.rounded(13)` = 135 pt. Line on an empty All Notes = 101 + 8 + 135 =
**244 pt > 218**; with the 124 pt chip = 267 pt. Because the pet has `zIndex(1)`, the tail of the count
disappears under the panda. This is the first screen a new user sees, and Task 5 step 6 ("Errands …
empty-state text") and step 7 (50-char folder, also empty) hit it; the plan's step 7 asks to confirm "not
pushed or overlapped" but has no fix. "68 open notes" = 86 pt, so 124 + 8 + 86 = 218 is exactly at the
limit; any three-digit count ("124 open notes") overflows by ~7 pt.

**Fix:** shorten the zero copy on the chip line and give the chip a little less: in `NotesScope.countLine`
`case 0: "No open notes"` (86 pt → 101 + 8 + 86 = 195 fits; 110 + 8 + 86 = 204 fits), change
`testCountLine` and Task 5 step 6's "the empty-state text" accordingly, and set the chip label
`.frame(maxWidth: 110, alignment: .leading)`. This touches spec §10's "On All Notes the list, count and
placeholder are exactly today's" only for the zero case; record it in "Spec notes" and let the
orchestrator confirm (the alternative — keeping "Nothing held right now" — cannot fit next to any chip).

---

## MAJOR-3 — Cross-plan: what release 2 produces vs what release 3 assumes

**Location:** Task 2 Step 3 / Task 6 Step 2 (panel) vs release 3 header list, Task 1 Step 3, Task 2, and
call sites at release-3 lines 2797, 2800, 4060, 4419, 5008.

Mismatches, and which side should change (spec wins where it speaks; it is silent on CoreClient labels):

1. `CoreClient.moveItem`: panel = `moveItem(_ item:, folderID:)`; release 3 Task 2 = `moveItem(_ item:, toFolder:)`
   and its Task 8/11 call `core.moveItem(item, toFolder:)`. Release 3's Task 1 greps `func moveItem(` and says
   "keep release 2's", so release 3 would not add its own and then fails to compile at those call sites.
   **Change the panel now (free):** `func moveItem(_ item: ItemSnapshot, toFolder folderID: String?)`,
   and the five call sites (Task 2 tests ×4, Task 6 `move()`, `undo()`). Then release 3 compiles as written.
2. `apps/macos/RalloTests/CoreClientFoldersTests.swift` + `final class CoreClientFoldersTests`: both plans
   create this file/class. **Release 3 must rename its file/class** (e.g. `WindowCoreClientTests`) or extend.
3. `NotesScope.folderScope`: the panel defines it in `NotesScope.swift`; release 3 Task 4 defines the same
   extension in `NotesWindowSelection.swift` with a conditional "delete if release 2 has it". Fine, but the
   orchestrator should make that unconditional: **release 3 deletes its extension.**
4. Release 3's own assumption list is stale in the same way as BLOCKER-1 (`listItems(...limit:) -> [ItemSnapshot]`,
   `searchItems(query:limit:)`, `FolderSnapshot` without `noteCount`), plus its Global Constraint "the FFI has
   no cursor, so the window lists stop at 200" and its `nonDeletedNoteCount(inFolder:)` (two list calls) are
   obsolete: spec §9 gives `ItemPage` + `cursor` paging and `FolderSnapshot.noteCount`. **Release 3 changes.**
5. Compatible as written (no action): `FolderNamePrompt.ask(title:initial:validate:) async -> String?` with
   `validate: (String) async throws -> Void` (matches spec §10 and release-3 line 4060's trailing-closure use);
   `FolderMoveMenu(currentFolderID:folders:onMove:onNewFolder:)`; `NotesViewModel.scope` (`private(set)` is
   enough, release 3 only reads it); `createNote(_:images:folderID:)` (panel's `= nil` default is harmless);
   `createFolder(_:)`, `folderOverview()`; `NotesScope.swift` is Foundation-only and is added to `RalloTests`
   sources in Task 3, as release 3 Task 1 Step 3/4 expects.

---

## MINOR-1 — "Spec notes" 1, 2, 3, 5 and the "§4 gives exit codes only" line describe contradictions the spec no longer has

**Location:** plan lines 40, 56–60.

**Problem:** The current spec already says: §9 "RalloStore (the uniffi object)"; §10 `validate: (String)
async throws -> Void` and `ask … async -> String?`; §7 "A range covers the `#` and the tag as written …
UTF-16 offsets of the string passed in; callers pass exactly the string they display"; §10 "Panel
subtitle and chip counts come from folder_overview"; §4 has an "FFI RalloError" column. An executor told
to "resolve" these may second-guess the pinned signatures.

**Fix:** delete notes 1, 2, 3, 5 and the line-40 preamble, or reword each as "spec says X; the plan does X".
Keep the Task 1 runtime probe for the `#` (it is cheap).

## MINOR-2 — Task 6 Step 2(c) `move()`: a row that leaves the list keeps stale swipe/edit state

**Problem:** `delete()` clears `openSwipe`, `liveSwipe`, `expandedID`, `editingID` for the row; `move()` only
clears `expandedID` (and only when `scope != .all`). Moving a row out of a folder scope while its tray is
open leaves `openSwipe` pointing at a vanished id, so the next Esc is swallowed by `handleEscape()` and
`swipeOffset(for:)` keeps a dead entry. `highlight(moved.id)` on a row that left is a harmless no-op.

**Fix:** mirror `delete()`:
```swift
if scope != .all {
    if openSwipe?.id == item.id { openSwipe = nil }
    if liveSwipe?.id == item.id { liveSwipe = nil }
    if expandedID == item.id { expandedID = nil }
    if editingID == item.id { editingID = nil }
}
```

## MINOR-3 — Harness: the scratch build stays registered with LaunchServices between tasks

**Location:** harness `h_stop`/`h_clean`; plan says "between tasks only `h_stop`"; Task 8 Step 3 is the
only `lsregister -u`.

**Problem:** `open -n -g "$H_APP"` registers the scratch bundle (same bundle id as the installed app) and it
stays registered for the days the plan runs, while `h_seed` schedules a reminder for tomorrow 09:30 in the
shared `com.razlio.rallo` notification store — the repo CLAUDE.md case where a notification click lands in
the scratch build. Also `screencapture -l` needs Screen Recording permission for the terminal (release 3's
plan says so; this one doesn't).

**Fix:** add `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$H_APP" 2>/dev/null || true`
as the last line of `h_stop` (the next `open` re-registers), and one sentence about Screen Recording
permission in "Harness step 2".

## MINOR-4 — Task 6 Step 5 item 9 races the toast's 5 s auto-dismiss

**Problem:** `show()` clears the toast after 5 s; step 9 asks to move a row, switch to a terminal, run
`folder delete Work --keep-notes`, switch back and click Undo. Doable only if the command is pre-typed.

**Fix:** say so ("have the command ready; Undo must be clicked within 5 s"), or do the delete first and the
move second is not equivalent — keep the order, just warn.

## MINOR-5 — Task 5 Step 7 expected-failure note is wrong

**Problem:** "a build error here is usually the `[core]` capture in askForFolder: core is private let…"
— `[core]` capturing a private property of `self` inside the class's own method is fine and the existing
code already does it (`remind(_:_:)`, NotesView.swift line 352). An executor hitting any build error will
chase this.

**Fix:** delete the parenthetical.

## MINOR-6 — Task 1 contract omits two §9 items release 3 consumes

**Problem:** `cancelReminder(id:ifRevision:)` and `ItemPage` are not pinned anywhere in release 2, yet this
test is described as "the contract the folders panel compiles against" and release 3 builds on it.

**Fix:** covered by the two extra lines in BLOCKER-1's Task 1 snippet.

## MINOR-7 — No progress/manual-checks note

**Problem:** Repo CLAUDE.md keeps progress in `private/docs/progress.md` and manual checks beside it; the plan's
Task 8 hand-off reports to the orchestrator only.

**Fix:** add to Task 8 Step 4: append a dated entry to `private/docs/progress.md` and the click-through list
(Tasks 5–7) to `private/docs/manual-checks.md` (gitignored, so no commit).

---

## Checked and found sound (no finding)

- Edit anchors: every "replace"/"after" string in Tasks 5–7 matches the current files exactly and is unique
  (NotesView.swift 78, 97–103, 218–227, 282, 513–516, 535–547, 569; NoteRow.swift 90–91, 117–123, 148–150,
  157–158, 176–186; AppCoordinator.swift 83; project.yml 76). `isScratch` is a stored `let` set at line 55,
  readable at line 83.
- Actor isolation: `NotesViewModel` is `@MainActor`; all new async methods are called via `Task { await … }`
  from views as today; `CoreWorker.perform` continuations resume on the main queue, which the modal run loop
  services (NSModalPanelRunLoopMode is a common mode), so `reload()` keeps working while the alert is up.
- `Toggle` inside `Menu`/`.contextMenu` for checkmarks, `.disabled(item.checked)` for the current folder,
  `ForEach(…, id: \.folderID)` with `String?` ids, `Menu` label with `.menuStyle(.button)` +
  `.buttonStyle(.plain)` + `.fixedSize()`: all match the existing "Remind" menu pattern.
- Scope persistence and fallback: `reload()` resolves against the fresh overview, lists with the resolved
  scope, writes the fallback to defaults, and the `scope == requested` guard handles a `setScope` that ran
  meanwhile; `checkForChanges` reloads on every `change_revision` bump, and `folder delete` bumps it (§2), so
  "within a second" holds. A delete racing between the overview and the list call only costs one failed
  reload, recovered on the next tick.
- Undo after move: uses the post-move snapshot; a note changed meanwhile → `REVISION_CONFLICT` → existing
  `report()` copy; source folder gone → `FOLDER_NOT_FOUND` message via `displayMessage`. Consistent with reopen/restore.
- Counts come from `folder_overview` (chip, menu, subtitle); `items.count` is only the pre-overview fallback.
- UTF-16 ranges on substrings: `NoteParts` title/body/preview are trimmed/joined strings; `tagRanges` is called
  on exactly the drawn string, and the grammar's "start or after whitespace" rule is preserved by trimming
  and by the preview's space joins. Surrogate halves and out-of-range offsets are skipped (probe passed).
- Real data: tests use temp dirs; harness uses `/tmp/rallo-folders-2/data`; `NotesScopeTests` uses a throwaway
  defaults suite and removes it; scratch instances write `com.razlio.rallo.scratch`; nothing installs.
- Swipe/drag: the Move submenu lives in the existing `.contextMenu`; no gesture or drop handler changes.
- Spec §10 coverage: chip + menu order/separators/checkmark, New Folder… via `NSAlert` with the core's
  message, scope → list/count/placeholder, `notesPanelScope` storage, fallback, row label on All Notes only
  (Notes included), Move to after Remind Me with current checked+disabled and New Folder… (creates and
  moves), `Moved to Work` + Undo, row leaves in a folder scope, tags rust+semibold via `tag_ranges`, expand
  button correctly deferred to release 3, agents section/shortcut/pet click untouched. Commits and Light/Dark
  screenshot + click-through steps are present for every UI task.
