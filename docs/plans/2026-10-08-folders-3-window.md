# Folders and Tags, Release 3: The Notes Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three-column Notes window (sidebar, list, editor), the panel's expand button that opens it, and the delete-folder sheet, on top of releases 1 (core, CLI, FFI) and 2 (panel folder chip).

**Architecture:** A titled `NSWindow` hosts a SwiftUI `NavigationSplitView` through `NSHostingController`. All state lives in one `@MainActor` `NotesWindowModel` that talks to the Rust core through `CoreClient` and reloads on the same change signal as the panel; the open note lives in a `NoteEditorSession` whose saving is a pure `SaveScheduler` state machine. The editor is an `NSViewRepresentable` `NSTextView` styled by attributes only. Lists are paged (`ItemPage` cursors): the model keeps the loaded pages per list and a reload fetches as many again. Rallo switches to the `.regular` activation policy while the window is open and back to `.accessory` on close (a few lines in `AppCoordinator`). Everything with logic is Foundation-only and compiled into `RalloTests`; the model and the editor session are tested against a real temp store.

**Tech Stack:** Swift 5 mode, SwiftUI + AppKit, macOS 14, XcodeGen (`apps/macos/project.yml`), UniFFI-generated bindings, XCTest.

**Spec:** docs/decisions/0019-folders-and-tags.md

Scope: §11 (window, expand button) and §12 (delete-folder sheet). §9 (FFI), §10 (`NotesScope`, `FolderMoveMenu`, `FolderNamePrompter`/`FolderNameOverlay`, built by release 2 and reused here) and §11's `NotesWindowSelection` are inputs.

## Swift API this plan assumes from releases 1 and 2

Task 1 compiles release 1's list and checks release 2's names; if the repo differs, it stops and says where (the later tasks' code is not adjusted on the fly).

**Release 1 (UniFFI names, from §9).** The FFI class is `RalloStore`. Methods on it: `folderOverview() throws -> FolderOverview`, `listTags() throws -> [TagSnapshot]`, `createFolder(name: String) throws -> FolderSnapshot`, `renameFolder(id: String, name: String) throws -> FolderSnapshot`, `deleteFolder(id: String, keepNotes: Bool) throws -> FolderDeleteResult`, `moveItem(id: String, folderId: String?, ifRevision: Int64?) throws -> ItemSnapshot`, `listItems(kind: ItemListKind, scope: FolderScope, tag: String?, limit: UInt32, cursor: String?) throws -> ItemPage`, `searchItems(query: String, limit: UInt32, cursor: String?) throws -> ItemPage`, `cancelReminder(id: String, ifRevision: Int64?) throws -> ItemSnapshot`, `createNoteWithImages(text: String, images: [Data], folderId: String?)`, `createReminderWithImages(text:when:images:folderId:)`; existing and unchanged: `editItemText(id:text:ifRevision:)`, `completeItem`, `reopenItem`, `deleteItem`, `restoreItem`, `remindIn`, `remindAt`, `attachImages`, `detachImage`, `changeRevision`. Free function `tagRanges(text: String) -> [TagRange]`. Types: `FolderSnapshot { id, name, openCount: UInt32, noteCount: UInt32, revision: Int64 }` (`noteCount` is open + done, nondeleted), `FolderOverview { allOpen, unfiledOpen, due, done, deleted: UInt32; folders: [FolderSnapshot] }`, `TagSnapshot { name, openCount: UInt32 }`, `TagRange { utf16Start: UInt32, utf16Len: UInt32, name: String }`, `ItemPage { items: [ItemSnapshot], nextCursor: String?, totalCount: UInt32 }`, `enum FolderScope { case all, unfiled, folder(id: String) }`, `enum ItemListKind { case open, done, due, deleted }`, `FolderDeleteResult { moved: UInt32, deleted: UInt32 }`, and `ItemSnapshot.folderId: String?`, `.folderName: String?`, `.tags: [String]`. `RalloError` keeps its five cases; `FOLDER_NAME_INVALID` is `InvalidInput`, `FOLDER_NOT_FOUND` `NotFound`, `FOLDER_EXISTS` `Conflict`, stale revisions `Conflict(code: "REVISION_CONFLICT", …)`. `tagRanges` ranges are UTF-16, cover the `#`, and are computed on exactly the string passed in (§7).

**Release 2 (panel; the "API this plan produces for release 3" section of `docs/plans/2026-10-08-folders-2-panel.md`, as built: `docs/plans/README.md`, "Plan 2 as built", wins where they differ).** `CoreClient`: `createNote(_:images:folderID:)` (default `nil`), `createReminder(_:when:images:folderID:)`, `openItems(scope:limit:)`, `folderOverview()`, `createFolder(_:)`, `deleteFolder(_ id: String, keepNotes: Bool)`, `moveItem(_:folderID:)`. `enum NotesScope: Hashable { case all, unfiled, folder(String) }` in `Notes/NotesScope.swift` with `folderScope: FolderScope` (release 2's `RalloTests` sources already list `NotesScope.swift`, `FolderNamePrompter.swift`, `RemindPreset.swift` and `Theme.swift`). `struct FolderMoveMenu: View { currentFolderID: String?; folders: [FolderSnapshot]; onMove: (String?) -> Void; onNewFolder: () -> Void }`. `@MainActor final class FolderNamePrompter: ObservableObject` in `Notes/FolderNamePrompter.swift` with `ask(title: String, initial: String, confirmTitle: String, validate: @escaping (String) async throws -> Void) async -> String?`, `request`, `cancel()`, shown by `FolderNameOverlay(prompter:)` (`Notes/FolderNameOverlay.swift`), a card on a scrim drawn inside its host view, not an `NSAlert` (`runModal` inside a main-actor job starves `validate`). `validate` is the real create call, so the core's own message shows under the field; Swift never re-implements the name rules, §3 and §10. `NotesViewModel` (now `Notes/NotesViewModel.swift`, with `Toast`): `init(core:defaults: UserDefaults = .standard)` and `private(set) var scope: NotesScope` (plus existing `expandedID`, `namePromptShown`, `scopeMenuOpen`); `AppCoordinator` builds it as `NotesViewModel(core: core, defaults: PanelDefaults.defaults(forDataDir: dataDir))` (`Notes/PanelDefaults.swift`: any data dir but the real one gets the `com.razlio.rallo.scratch` suite). `RemindPreset` and `ReminderSnapshot.deadline` live in `Notes/RemindPreset.swift`. The panel's `Toast` (`Toast.Undo` gains `move`) is unchanged; its private `ToastBar` (still in `Notes/NotesView.swift`) becomes `ToastBar(message:undoable:undoShortcut:undo:)` in Task 11 so the window can reuse it with its own `WindowToast` model.

**What this plan adds to `CoreClient` (Task 2):** `listTags`, `renameFolder`, paged `listItems`/`searchItems` (return `ItemPage`), `cancelReminder`, `static let pageSize`. Deleting a folder uses release 2's `deleteFolder(_ id:keepNotes:)`; no second API.

## Global Constraints

- Swift/SwiftUI, XcodeGen, macOS 14 target, Swift 5 mode. **Never hand-edit `apps/macos/Rallo/Generated/` or `apps/macos/Rallo.xcodeproj`.** New files are listed in `apps/macos/project.yml` (the app target globs `Rallo/`; only the `RalloTests` source list is explicit) and picked up by `(cd apps/macos && xcodegen generate --quiet)`, which every build or test command below runs.
- Rust is Homebrew keg-only `rustup`: every shell session starts with `export PATH=/opt/homebrew/opt/rustup/bin:$PATH`.
- **Swift test command** (used verbatim by every test step; replace the class after `-only-testing:`):
  `cd /Users/eyakub/Desktop/Rallo && (cd apps/macos && xcodegen generate --quiet) && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData test -only-testing:RalloTests/<Class> 2>&1 | tail -40`
- **Scratch app build:** `cd /Users/eyakub/Desktop/Rallo && scripts/build-macos.sh` (no `--install`; never install over `~/Applications/Rallo.app`). The product is `build/DerivedData/Build/Products/Release/Rallo.app`.
- Tests and manual checks use a temp data dir (`--data-dir` / `RALLO_DATA_DIR`), never the real one. Scratch builds registered with LaunchServices get `lsregister -u` afterwards.
- **Scratch run** (used by every UI task's check step):
  ```bash
  export PATH=/opt/homebrew/opt/rustup/bin:$PATH
  cd /Users/eyakub/Desktop/Rallo
  SCRATCH=$(mktemp -d); export RALLO_DATA_DIR="$SCRATCH/data"
  APP="$PWD/build/DerivedData/Build/Products/Release/Rallo.app"; CLI="$APP/Contents/Helpers/rallo"
  mkdir -p private/docs/folders-3-shots
  # seed (the CLI may start a background instance on this data dir; stop it before the real launch)
  "$CLI" folder create Work; "$CLI" folder create Ideas
  "$CLI" note "Quarterly plan: ship #release notes" --folder Work
  "$CLI" note $'Standup\nWhat changed since Friday #bug' --folder Work
  "$CLI" note "Call the dentist"
  "$CLI" note "Café ideas #كلمة and カフェ 🦊 #bug"
  pkill -f -- "--data-dir $RALLO_DATA_DIR"; sleep 1
  # `open` hands its environment to the app: with RALLO_DATA_DIR set the instance is not scratch and ignores the demo flags.
  env -u RALLO_DATA_DIR open -n -g "$APP" --args --data-dir "$RALLO_DATA_DIR" --demo-appearance light --demo-open window
  ```
  Dark Mode: stop it (`pkill -f -- "--data-dir $RALLO_DATA_DIR"`; if an open menu or sheet ignores SIGTERM, `sleep 1; pkill -9 -f -- "--data-dir $RALLO_DATA_DIR"`) and relaunch the same way with `--demo-appearance dark`.
  Driving the UI: send clicks and keys to the app's pid only (Accessibility actions such as `AXPress`/`AXValue` on its elements, or `CGEvent.postToPid`), never through the global HID event tap: typing in the terminal leaks into a frontmost scratch app. Window screenshots: copy the `windows.swift` helper from `scripts/screenshots.sh` (the heredoc under "Capture"), `swiftc -O -o "$SCRATCH/windows" "$SCRATCH/windows.swift"`, then `"$SCRATCH/windows" $(pgrep -f -- "--demo-open window" | head -1)` prints `id layer name`; `screencapture -x -l <id> private/docs/folders-3-shots/<task>-<what>-<light|dark>.png` (needs Screen Recording permission for the terminal). `private/` is gitignored.
  Cleanup after the last check of a session: `pkill -f -- "--data-dir $RALLO_DATA_DIR"; /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP"; rm -rf "$SCRATCH"`.
  The scratch app keeps the panel's scope and the window's frame in a separate defaults suite (`com.razlio.rallo.scratch`), so the installed app's preferences are never touched; `defaults delete com.razlio.rallo.scratch` clears them.
- UI: build, launch the scratch build on a temp data dir, click through every behaviour of the task **once, in Light Mode**, then relaunch in **Dark Mode** and screenshot only the states the task changed (no second walk-through). Show one core validation error at most; unit tests cover the rest. Both appearances are screenshotted before a task is called done.
- **Commits:** conventional (`feat(app): …`, `test(app): …`, `docs: …`), author `eyakubsorkar@gmail.com` (already the repo's git config), **no AI attribution and no Co-Authored-By trailer** (this overrides any default trailer). Stage only the paths each commit step names; the untracked `assets/pet/rallo/launch-kit/` and `marketing/` are not ours.
- No release, version bump or changelog in this plan. The last task updates the README (the in-app features table); release notes wait for release time.
- Copy is exact (spec §11/§12): "Open Notes Window" (expand button help and accessibility label), "Notes Window" (status-menu item and Window-menu item), File menu: "New Note", "New Folder", "Close"; window title "Notes", search prompt "Search all notes", "No note selected", "This note changed somewhere else." with **Show Theirs** / **Keep Mine**, "New Folder", "New Note", "N done", "Results", and the delete sheet: **Delete “Work”?** / "It holds 5 notes. Keep them in Notes, or delete them too? Deleted notes stay in Deleted, where you can restore them." / **Keep Notes** (default), **Delete Notes** (destructive), **Cancel**; empty folder: **Delete “Work”?** / "The folder is empty." / **Delete**, **Cancel**.
- Window: `isReleasedWhenClosed = false`, min 900×560, first open 1140×690 centred, frame remembered under the key `RalloNotesWindow` in the scratch-aware defaults, `.tint(Theme.rust)`, `.regular` activation policy only while open. The pet window and the panel keep ADR 0002's configuration untouched.
- Lists are paged (§9): the window loads a page of `CoreClient.pageSize` rows, the next page when the last row appears, and counts come from the core's `totalCount`/`noteCount`. Nothing in the window is capped or reads "200+".

## Review Focus

The five inputs the spec implies but no obvious test covers, most likely first. Each is pinned by the test or check named in its owning task.

1. **IME composition.** Typing Bangla/Japanese with marked text while the 0.6 s save timer fires or the text restyles must not break the composition (no string replacement, no attribute writes, no save of half-composed text). Pinned in Task 6 (`testRestyleLeavesMarkedTextAlone`) and Task 7 (`testMarkedTextDelaysTheSave`).
2. **Select-all, delete, then leave.** An emptied note with no images must never be saved, and leaving it puts the saved text back. Pinned in Task 7 (`testAnEmptiedNoteIsNeverSavedAndComesBack`).
3. **Changed while typing.** An agent or the CLI edits the note while the user types: the next save raises the conflict bar, Show Theirs/Keep Mine both end clean, and a reload never overwrites unsaved typing. Pinned in Task 7 (`testAChangeSomewhereElseShowsTheConflictBar`, `testKeepMineSavesOnTheNewRevision`, `testAReloadNeverOverwritesTyping`).
4. **A folder holding only done notes.** `FolderSnapshot.openCount` says 0, so the delete sheet (which reads `noteCount`) must still say "It holds 1 note" and Keep Notes must file it in Notes. Pinned in Task 2 (`testNoteCountIncludesDoneNotesWhileOpenCountDoesNot`), Task 8 (`testDeletingAFolderOfOnlyDoneNotesKeepsThem`) and Task 10 (`FolderDeleteCopyTests`).
5. **The selected folder or tag vanishes** (deleted by the CLI, or its last tagged note edited) while selected or while its note is open: the window falls back to Notes / All Notes and never shows a stale list; a note selected on a later page stays selected across a reload. Pinned in Task 4 (`SelectionFallbackTests`) and Task 8 (`testADeletedScopeFolderFallsBackToNotes`, `testAVanishedTagFallsBackToAllNotes`, `testASelectedNoteDeletedElsewhereClearsTheSelection`, `testASelectionOnALaterPageSurvivesAReload`).

## File Structure

New, under `apps/macos/Rallo/NotesWindow/` (the folder is new; pure files are Foundation/AppKit-only so `RalloTests` can compile them):

| File | Responsibility |
|---|---|
| `DateGrouping.swift` | pure: list date sections and the row time label |
| `FolderNaming.swift` | pure: a guess at the first free "New Folder N" (the core judges every name) |
| `NotesWindowSelection.swift` | pure: `NotesWindowSelection`, selection fallback |
| `SaveScheduler.swift` | pure: save debounce state machine with an injected clock |
| `EditorStyling.swift` | pure: title/tag spans in UTF-16, `RowText` (list title and preview) |
| `NoteTextStyler.swift` | AppKit only: `PlainTextView`, attribute-only restyle that skips marked text |
| `NoteEditorSession.swift` | the open note: text, save/conflict/draft, backed by `CoreClient` |
| `NotesWindowModel.swift`, `NotesWindowModel+Notes.swift` | window state, paged lists, reload, folders, note changes |
| `FolderDeleteCopy.swift` | pure: the delete sheet's exact copy |
| `NotesWindowController.swift` | the `NSWindow`, delegate, open/close |
| `NotesWindowView.swift` | root `NavigationSplitView`, error banner, delete sheet |
| `FolderSidebar.swift`, `DeleteFolderSheet.swift` | sidebar and the §12 sheet |
| `NoteListColumn.swift` | list column, rows, paging, toast |
| `NoteEditorColumn.swift`, `NoteTextEditor.swift`, `FolderPrompts.swift` | editor column, the `NSTextView` wrapper, New Folder… glue |

New elsewhere: `Notes/RemindMenuItems.swift` (shared by the panel and the window), `RalloTests/*Tests.swift`. (`Notes/RemindPreset.swift` already exists: release 2 moved it.)

Modified: `Core/CoreClient.swift`, `Notes/RalloError+Display.swift`, `Shared/Theme.swift` (`inkNS`/`rustNS`, the `NSColor`s behind `ink`/`rust`), `Notes/NotesView.swift` (`ToastBar` made reusable, expand button), `Notes/NotesViewModel.swift` (`onExpand`), `Notes/FolderNameOverlay.swift` (`.folderNamePrompt(_:)`, Esc on the card), `Notes/NoteRow.swift`, `Notes/CustomRemindPopover.swift`, `Notes/ImageStrip.swift`, `Notes/Thumbnails.swift`, `App/AppCoordinator.swift`, `App/AppDelegate.swift`, `App/StatusMenuController.swift`, `Settings/SettingsWindowController.swift`, `Diagnostics/WindowReport.swift`, `apps/macos/project.yml`, `README.md`.

---

### Task 1: Compile-check the release 1 and 2 API this plan assumes

**Files:**
- Create: `apps/macos/RalloTests/FolderAPIAssumptionsTests.swift`

**Interfaces:**
- Consumes: releases 1 and 2 merged on this branch (the "Swift API this plan assumes" list above; release 2's names are those in `docs/plans/2026-10-08-folders-2-panel.md`, "API this plan produces for release 3").
- Produces: a permanent test that stops compiling when a generated name or label drifts, and a sanity check that release 2's names exist; if anything differs, stop and tell the orchestrator (a global rename in this plan is not a task for the executor).

- [ ] **Step 1: Write the compile-check test**

Create `apps/macos/RalloTests/FolderAPIAssumptionsTests.swift`:

```swift
import XCTest

/// 0019 release 1 as release 3 uses it. If a generated name or label differs,
/// this file stops compiling, which is the point.
final class FolderAPIAssumptionsTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-folders-api-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testTheFFIShapeReleaseThreeUses() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let work: FolderSnapshot = try store.createFolder(name: "Work")
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(work.openCount, 0)
        XCTAssertEqual(work.noteCount, 0)
        let note: ItemSnapshot = try store.createNoteWithImages(text: "Ship #release", images: [], folderId: work.id)
        XCTAssertEqual(note.folderId, work.id)
        XCTAssertEqual(note.folderName, "Work")
        XCTAssertEqual(note.tags, ["release"])

        let overview: FolderOverview = try store.folderOverview()
        XCTAssertEqual([overview.allOpen, overview.unfiledOpen, overview.due, overview.done, overview.deleted], [1, 0, 0, 0, 0])
        XCTAssertEqual(overview.folders.map(\.name), ["Work"])
        XCTAssertEqual(overview.folders.first?.openCount, 1)
        XCTAssertEqual(overview.folders.first?.noteCount, 1)
        let tags: [TagSnapshot] = try store.listTags()
        XCTAssertEqual(tags.map(\.name), ["release"])
        XCTAssertEqual(tags.first?.openCount, 1)

        let scopes: [FolderScope] = [.all, .unfiled, .folder(id: work.id)]
        let kinds: [ItemListKind] = [.open, .done, .due, .deleted]
        let inWork: ItemPage = try store.listItems(kind: kinds[0], scope: scopes[2], tag: nil, limit: 200, cursor: nil)
        XCTAssertEqual(inWork.items.map(\.id), [note.id])
        XCTAssertEqual(inWork.totalCount, 1)
        XCTAssertNil(inWork.nextCursor)
        XCTAssertEqual(try store.listItems(kind: kinds[0], scope: scopes[0], tag: "release", limit: 200, cursor: nil).totalCount, 1)
        XCTAssertEqual(try store.listItems(kind: kinds[0], scope: scopes[1], tag: nil, limit: 200, cursor: nil).totalCount, 0)
        XCTAssertEqual(try store.listItems(kind: kinds[1], scope: scopes[0], tag: nil, limit: 200, cursor: nil).totalCount, 0)
        let found: ItemPage = try store.searchItems(query: "release", limit: 200, cursor: nil)
        XCTAssertEqual(found.items.map(\.id), [note.id])
        XCTAssertNil(found.nextCursor)

        let moved = try store.moveItem(id: note.id, folderId: nil, ifRevision: note.revision)
        XCTAssertNil(moved.folderId)
        let renamed = try store.renameFolder(id: work.id, name: "Work 2")
        XCTAssertEqual(renamed.name, "Work 2")
        let result: FolderDeleteResult = try store.deleteFolder(id: work.id, keepNotes: true)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.deleted, 0)
        let edited = try store.editItemText(id: note.id, text: "Ship it", ifRevision: moved.revision)
        XCTAssertEqual(edited.text, "Ship it")
    }

    func testCancelReminderLeavesTheNoteOpenWithACancelledReminder() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let reminded = try store.createReminderWithImages(text: "Stretch", when: "in 2 hours", images: [], folderId: nil)
        XCTAssertEqual(reminded.reminder?.state, .active)
        let cancelled = try store.cancelReminder(id: reminded.id, ifRevision: reminded.revision)
        XCTAssertEqual(cancelled.reminder?.state, .cancelled)
        XCTAssertEqual(cancelled.status, .open)
    }

    /// The editor highlights `#tag` ranges the core computed (§7): UTF-16, covering the `#`.
    func testTagRangesCoverTheHashInUTF16() {
        let text = "🦊 কাজ #কাজ and #bug"
        let ranges: [TagRange] = tagRanges(text: text)
        let string = text as NSString
        let slices = ranges.map { string.substring(with: NSRange(location: Int($0.utf16Start), length: Int($0.utf16Len))) }
        XCTAssertEqual(slices, ["#কাজ", "#bug"])
        XCTAssertEqual(ranges.map(\.name), ["কাজ", "bug"])
    }
}
```

- [ ] **Step 2: Check that release 2's names are where its plan says**

```bash
cd /Users/eyakub/Desktop/Rallo/apps/macos/Rallo
grep -n "func moveItem(_ item: ItemSnapshot, folderID" Core/CoreClient.swift
grep -n "func createNote(_ text: String, images: \[Data\], folderID" Core/CoreClient.swift
grep -n "func folderOverview\|func createFolder" Core/CoreClient.swift
grep -n "func deleteFolder(_ id: String, keepNotes: Bool)" Core/CoreClient.swift
grep -n "var folderScope" Notes/NotesScope.swift
grep -n "func ask(title: String, initial: String, confirmTitle: String" Notes/FolderNamePrompter.swift
grep -n "struct FolderNameOverlay: View" Notes/FolderNameOverlay.swift
grep -n "private(set) var scope\|init(core: CoreClient, defaults" Notes/NotesViewModel.swift
grep -n 'notesModel = NotesViewModel(core: core, defaults: PanelDefaults.defaults(forDataDir: dataDir))' App/AppCoordinator.swift
grep -n "^private struct ToastBar: View" Notes/NotesView.swift
grep -n "enum RemindPreset\|var deadline: Date" Notes/RemindPreset.swift
grep -n "NotesScope.swift\|FolderNamePrompter.swift\|RemindPreset.swift\|Theme.swift" ../project.yml
```

Expected: every command prints at least one line (`createFolder` and `folderOverview` one each). Task 9 anchors on that `AppCoordinator` line, Task 11 on `ToastBar` and `FolderNamePrompter`. An empty result means release 2 differs from its plan: stop and report which.

- [ ] **Step 3: Run the test; it must compile and pass**

Run the **Swift test command** with `-only-testing:RalloTests/FolderAPIAssumptionsTests`.
Expected: `Test Suite 'FolderAPIAssumptionsTests' passed`. A compile error names a drifted symbol; §7 says a tag range covers its `#`, so a failing `testTagRangesCoverTheHashInUTF16` means release 1 and the spec differ: stop and tell the orchestrator.

- [ ] **Step 4: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/RalloTests/FolderAPIAssumptionsTests.swift
git commit -m "test(app): pin the folders FFI the notes window builds on"
```

---

### Task 2: `CoreClient` calls the window adds

**Files:**
- Modify: `apps/macos/Rallo/Core/CoreClient.swift` (insert before `// MARK: Export and import (0004)`)
- Create: `apps/macos/RalloTests/CoreClientWindowTests.swift`

**Interfaces:**
- Consumes: Task 1's confirmed FFI; release 2's `CoreClient` wrappers (`createNote(_:images:folderID:)`, `createFolder(_:)`, `deleteFolder(_ id: String, keepNotes:)`, `folderOverview()`, `moveItem(_:folderID:)`, `openItems(scope:limit:)`); `CoreWorker.perform`.
- Produces (all `async throws` on `CoreClient`; release 2 does not define these):
  `static let pageSize: UInt32 = 100`;
  `listTags() -> [TagSnapshot]`; `renameFolder(_ folder: FolderSnapshot, to name: String) -> FolderSnapshot`;
  `listItems(_ kind: ItemListKind, scope: FolderScope = .all, tag: String? = nil, cursor: String? = nil, limit: UInt32 = CoreClient.pageSize) -> ItemPage`;
  `searchItems(_ query: String, cursor: String? = nil, limit: UInt32 = CoreClient.pageSize) -> ItemPage`;
  `cancelReminder(_ item: ItemSnapshot) -> ItemSnapshot`.

- [ ] **Step 1: Write the failing test**

Create `apps/macos/RalloTests/CoreClientWindowTests.swift`:

```swift
import XCTest

/// The window's `CoreClient` calls, against a real temp store (never the real data directory).
final class CoreClientWindowTests: XCTestCase {
    private var dataDir: URL!
    private var core: CoreClient!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-core-window-\(UUID().uuidString)")
        core = CoreClient(dataDir: dataDir.path)
        try await core.open()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testListSearchTagsAndRename() async throws {
        let work = try await core.createFolder("Work")
        let note = try await core.createNote("Ship #release", images: [], folderID: work.id)

        let inWork = try await core.listItems(.open, scope: .folder(id: work.id))
        XCTAssertEqual(inWork.items.map(\.id), [note.id])
        XCTAssertEqual(inWork.totalCount, 1)
        let unfiled = try await core.listItems(.open, scope: .unfiled)
        XCTAssertTrue(unfiled.items.isEmpty)
        let byTag = try await core.listItems(.open, tag: "release")
        XCTAssertEqual(byTag.items.map(\.id), [note.id])
        let found = try await core.searchItems("ship")
        XCTAssertEqual(found.items.map(\.id), [note.id])
        let tags = try await core.listTags()
        XCTAssertEqual(tags.map(\.name), ["release"])

        let renamed = try await core.renameFolder(work, to: "Work 2")
        XCTAssertEqual(renamed.name, "Work 2")
        let moved = try await core.moveItem(note, folderID: nil)
        XCTAssertNil(moved.folderId)
        let overview = try await core.folderOverview()
        XCTAssertEqual(overview.folders.map(\.name), ["Work 2"])
        XCTAssertEqual(overview.unfiledOpen, 1)
    }

    func testListsAndSearchPageThroughCursors() async throws {
        for number in 1...5 { _ = try await core.createNote("Note \(number)") }
        let first = try await core.listItems(.open, limit: 2)
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.totalCount, 5, "the total is the whole list, not the page")
        XCTAssertNotNil(first.nextCursor)
        let second = try await core.listItems(.open, cursor: first.nextCursor, limit: 2)
        let third = try await core.listItems(.open, cursor: second.nextCursor, limit: 2)
        XCTAssertEqual(third.items.count, 1)
        XCTAssertNil(third.nextCursor)
        XCTAssertEqual(Set((first.items + second.items + third.items).map(\.id)).count, 5, "no row twice, none missing")

        let hits = try await core.searchItems("Note", limit: 3)
        XCTAssertEqual(hits.items.count, 3)
        let rest = try await core.searchItems("Note", cursor: hits.nextCursor, limit: 3)
        XCTAssertEqual(rest.items.count, 2)
        XCTAssertNil(rest.nextCursor)
    }

    /// Review focus 4: the delete sheet reads `noteCount`, which counts done notes.
    func testNoteCountIncludesDoneNotesWhileOpenCountDoesNot() async throws {
        let folder = try await core.createFolder("Done only")
        let note = try await core.createNote("Finished", images: [], folderID: folder.id)
        _ = try await core.completeItem(note)

        let overview = try await core.folderOverview()
        XCTAssertEqual(overview.folders.first?.openCount, 0, "the sidebar count is open notes only")
        XCTAssertEqual(overview.folders.first?.noteCount, 1, "the delete sheet must still say the folder holds a note")

        let result = try await core.deleteFolder(try XCTUnwrap(overview.folders.first).id, keepNotes: true)
        XCTAssertEqual(result.moved, 1)
        let kept = try await core.listItems(.done, scope: .unfiled)
        XCTAssertEqual(kept.items.map(\.text), ["Finished"])
    }

    func testCancelReminderCancelsAndKeepsTheNoteOpen() async throws {
        let reminded = try await core.createReminder("Stretch", when: "in 2 hours")
        let cancelled = try await core.cancelReminder(reminded)
        XCTAssertEqual(cancelled.reminder?.state, .cancelled)
        XCTAssertEqual(cancelled.status, .open)
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run the **Swift test command** with `-only-testing:RalloTests/CoreClientWindowTests`.
Expected: compile FAIL, `value of type 'CoreClient' has no member 'listTags'`.

- [ ] **Step 3: Add the wrappers**

In `apps/macos/Rallo/Core/CoreClient.swift`, insert before `    // MARK: Export and import (0004)`:

```swift
    // MARK: The notes window (0019 §9, §11)

    /// How many rows a list asks for at a time (the core allows 1…200).
    static let pageSize: UInt32 = 100

    func listTags() async throws -> [TagSnapshot] {
        try await worker.perform { try $0.listTags() }
    }

    func renameFolder(_ folder: FolderSnapshot, to name: String) async throws -> FolderSnapshot {
        try await worker.perform { try $0.renameFolder(id: folder.id, name: name) }
    }

    /// One page per call; pass the previous page's `nextCursor` for the next.
    func listItems(
        _ kind: ItemListKind, scope: FolderScope = .all, tag: String? = nil, cursor: String? = nil,
        limit: UInt32 = CoreClient.pageSize
    ) async throws -> ItemPage {
        try await worker.perform { try $0.listItems(kind: kind, scope: scope, tag: tag, limit: limit, cursor: cursor) }
    }

    /// Open and done notes in every folder, a page at a time.
    func searchItems(_ query: String, cursor: String? = nil, limit: UInt32 = CoreClient.pageSize) async throws -> ItemPage {
        try await worker.perform { try $0.searchItems(query: query, limit: limit, cursor: cursor) }
    }

    /// The CLI's `cancel-reminder`: the reminder's state becomes `cancelled`; the note stays open.
    func cancelReminder(_ item: ItemSnapshot) async throws -> ItemSnapshot {
        try await worker.perform { try $0.cancelReminder(id: item.id, ifRevision: item.revision) }
    }

```

- [ ] **Step 4: Run the tests and see them pass**

Run the **Swift test command** with `-only-testing:RalloTests/CoreClientWindowTests`.
Expected: `Test Suite 'CoreClientWindowTests' passed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/Core/CoreClient.swift apps/macos/RalloTests/CoreClientWindowTests.swift
git commit -m "feat(app): CoreClient paged lists, tags, folder rename, cancel reminder"
```

---

### Task 3: Date grouping and the row time label (pure)

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/DateGrouping.swift`
- Create: `apps/macos/RalloTests/DateGroupingTests.swift`
- Modify: `apps/macos/project.yml` (test sources)

**Interfaces:**
- Consumes: nothing.
- Produces:
  `enum DateGroup: Hashable { case today, yesterday, previous7Days, previous30Days; case month(year: Int, month: Int) }`;
  `struct DateSection<Element>: Identifiable { let group: DateGroup; let title: String; let elements: [Element]; var id: DateGroup }`;
  `DateGrouping.group(for:now:calendar:) -> DateGroup`; `DateGrouping.title(_:now:calendar:locale:) -> String`; `DateGrouping.sections(_:timestampMs:now:calendar:locale:) -> [DateSection<Element>]`;
  `RowTimeLabel.text(for:now:calendar:locale:) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RalloTests/DateGroupingTests.swift`:

```swift
import XCTest

final class DateGroupingTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let british = Locale(identifier: "en_GB")

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTheDayBoundaries() {
        let utc = calendar()
        let now = date(utc, 2026, 10, 8, 10, 42)
        func group(_ date: Date) -> DateGroup { DateGrouping.group(for: date, now: now, calendar: utc) }
        XCTAssertEqual(group(date(utc, 2026, 10, 8, 0, 0)), .today)
        XCTAssertEqual(group(date(utc, 2026, 10, 7, 23, 59)), .yesterday)
        XCTAssertEqual(group(date(utc, 2026, 10, 7, 0, 0)), .yesterday)
        XCTAssertEqual(group(date(utc, 2026, 10, 6, 23, 59)), .previous7Days)
        XCTAssertEqual(group(date(utc, 2026, 10, 1, 0, 0)), .previous7Days)
        XCTAssertEqual(group(date(utc, 2026, 9, 30, 23, 59)), .previous30Days)
        XCTAssertEqual(group(date(utc, 2026, 9, 8, 0, 0)), .previous30Days)
        XCTAssertEqual(group(date(utc, 2026, 9, 7, 23, 59)), .month(year: 2026, month: 9))
        XCTAssertEqual(group(date(utc, 2026, 10, 9, 8, 0)), .today, "a clock a little ahead is still today")
    }

    func testMonthTitlesDropTheYearOnlyInTheCurrentYear() {
        let utc = calendar()
        let now = date(utc, 2026, 3, 15)
        XCTAssertEqual(DateGrouping.title(.month(year: 2026, month: 1), now: now, calendar: utc, locale: english), "January")
        XCTAssertEqual(DateGrouping.title(.month(year: 2025, month: 12), now: now, calendar: utc, locale: english), "December 2025")
        XCTAssertEqual(DateGrouping.title(.today, now: now, calendar: utc, locale: english), "Today")
        XCTAssertEqual(DateGrouping.title(.yesterday, now: now, calendar: utc, locale: english), "Yesterday")
        XCTAssertEqual(DateGrouping.title(.previous7Days, now: now, calendar: utc, locale: english), "Previous 7 Days")
        XCTAssertEqual(DateGrouping.title(.previous30Days, now: now, calendar: utc, locale: english), "Previous 30 Days")
    }

    func testTheYearBoundary() {
        let utc = calendar()
        let january = date(utc, 2026, 1, 5)
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2025, 12, 20), now: january, calendar: utc), .previous30Days)
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2025, 11, 30), now: january, calendar: utc), .month(year: 2025, month: 11))
        let march = date(utc, 2026, 3, 15)
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2025, 12, 31), now: march, calendar: utc), .month(year: 2025, month: 12))
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2026, 1, 10), now: march, calendar: utc), .month(year: 2026, month: 1))
    }

    func testTheSameInstantFallsOnDifferentDaysInDifferentTimeZones() {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-10-08T23:30:00Z")!
        let note = formatter.date(from: "2026-10-08T10:30:00Z")!
        // Kiritimati (UTC+14) is already on the 9th and its midnight was 10:00Z; Pago Pago (UTC-11) midnight is 11:00Z.
        XCTAssertEqual(DateGrouping.group(for: note, now: now, calendar: calendar("Pacific/Kiritimati")), .today)
        XCTAssertEqual(DateGrouping.group(for: note, now: now, calendar: calendar("Pacific/Pago_Pago")), .yesterday)
    }

    func testYesterdayAcrossADaylightSavingChange() {
        let newYork = calendar("America/New_York")  // clocks went back on 1 November 2026: that day has 25 hours
        let now = date(newYork, 2026, 11, 2, 9, 0)
        XCTAssertEqual(DateGrouping.group(for: date(newYork, 2026, 11, 1, 0, 0), now: now, calendar: newYork), .yesterday)
        XCTAssertEqual(DateGrouping.group(for: date(newYork, 2026, 10, 31, 23, 59), now: now, calendar: newYork), .previous7Days)
    }

    func testSectionsKeepFirstAppearanceOrderAndMergeTheSameGroup() {
        let utc = calendar()
        let now = date(utc, 2026, 10, 8, 10, 42)
        func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        let stamps = [
            ms(date(utc, 2026, 10, 8, 9)), ms(date(utc, 2026, 10, 7, 9)), ms(date(utc, 2026, 10, 8, 8)),
            ms(date(utc, 2026, 8, 20)), ms(date(utc, 2025, 8, 20)),
        ]
        let sections = DateGrouping.sections(stamps, timestampMs: { $0 }, now: now, calendar: utc, locale: english)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "August", "August 2025"])
        XCTAssertEqual(sections.map(\.elements.count), [2, 1, 1, 1])
        XCTAssertEqual(Set(sections.map(\.id)).count, 4, "ids are unique, so ForEach never sees a duplicate")
    }

    func testRowTimeIsTheTimeTodayTheWeekdayThisWeekElseTheDate() {
        let utc = calendar()
        let now = date(utc, 2026, 10, 8, 10, 42)
        func label(_ date: Date) -> String { RowTimeLabel.text(for: date, now: now, calendar: utc, locale: british) }
        XCTAssertEqual(label(date(utc, 2026, 10, 8, 10, 42)), "10:42")
        XCTAssertEqual(label(date(utc, 2026, 10, 6, 9, 0)), "Tuesday")
        XCTAssertEqual(label(date(utc, 2026, 10, 2, 9, 0)), "Friday")
        XCTAssertEqual(label(date(utc, 2026, 10, 1, 9, 0)), "01/10/2026")
    }
}
```

- [ ] **Step 2: Run to see the compile failure**

Add the source to the test target first. In `apps/macos/project.yml`, after `      - path: Rallo/Notes/RalloError+Display.swift` add `      - path: Rallo/NotesWindow/DateGrouping.swift`. Run the **Swift test command** with `-only-testing:RalloTests/DateGroupingTests`.
Expected: FAIL, the `DateGrouping.swift` input file does not exist (then, once an empty file exists, `cannot find 'DateGrouping' in scope`).

- [ ] **Step 3: Write the implementation**

Create `apps/macos/Rallo/NotesWindow/DateGrouping.swift`:

```swift
import Foundation

/// The date sections of the notes window's list (0019 §11).
enum DateGroup: Hashable {
    case today, yesterday, previous7Days, previous30Days
    case month(year: Int, month: Int)
}

struct DateSection<Element>: Identifiable {
    let group: DateGroup
    let title: String
    let elements: [Element]

    var id: DateGroup { group }
}

enum DateGrouping {
    /// Whole days in the calendar's time zone: Today is since midnight,
    /// Yesterday the day before, Previous 7 Days reaches back 7 days from
    /// today's midnight, Previous 30 Days 30; older notes sit in their month.
    static func group(for date: Date, now: Date, calendar: Calendar) -> DateGroup {
        let today = calendar.startOfDay(for: now)
        func midnight(daysBack: Int) -> Date { calendar.date(byAdding: .day, value: -daysBack, to: today)! }
        if date >= today { return .today }
        if date >= midnight(daysBack: 1) { return .yesterday }
        if date >= midnight(daysBack: 7) { return .previous7Days }
        if date >= midnight(daysBack: 30) { return .previous30Days }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year!, month: parts.month!)
    }

    /// "Today" … "September", or "August 2025" outside the current year.
    static func title(_ group: DateGroup, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        switch group {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case let .month(year, month):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            let thisYear = calendar.component(.year, from: now) == year
            formatter.setLocalizedDateFormatFromTemplate(thisYear ? "LLLL" : "LLLL y")
            let firstNoon = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))!
            return formatter.string(from: firstNoon)
        }
    }

    /// Sections in order of first appearance (`elements` should already be
    /// newest first); the same group never appears twice.
    static func sections<Element>(
        _ elements: [Element], timestampMs: (Element) -> Int64, now: Date, calendar: Calendar, locale: Locale = .current
    ) -> [DateSection<Element>] {
        var order: [DateGroup] = []
        var buckets: [DateGroup: [Element]] = [:]
        for element in elements {
            let date = Date(timeIntervalSince1970: TimeInterval(timestampMs(element)) / 1000)
            let group = group(for: date, now: now, calendar: calendar)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(element)
        }
        return order.map {
            DateSection(group: $0, title: title($0, now: now, calendar: calendar, locale: locale), elements: buckets[$0]!)
        }
    }
}

/// The time on a list row: today `10:42`, within the last week the weekday,
/// else the date.
enum RowTimeLabel {
    static func text(for date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if date >= today {
            formatter.setLocalizedDateFormatFromTemplate("jm")
        } else if date >= weekStart {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMd")
        }
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run the **Swift test command** with `-only-testing:RalloTests/DateGroupingTests`.
Expected: `Test Suite 'DateGroupingTests' passed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/DateGrouping.swift apps/macos/RalloTests/DateGroupingTests.swift apps/macos/project.yml
git commit -m "feat(app): date sections and row time labels for the notes window list"
```

---

### Task 4: "New Folder N" naming and the selection fallback (pure)

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/FolderNaming.swift`
- Create: `apps/macos/Rallo/NotesWindow/NotesWindowSelection.swift`
- Create: `apps/macos/RalloTests/FolderNamingTests.swift`
- Create: `apps/macos/RalloTests/SelectionFallbackTests.swift`
- Modify: `apps/macos/project.yml` (test sources)

**Interfaces:**
- Consumes: `NotesScope` (release 2, already a `RalloTests` source).
- Produces:
  `FolderNaming.newFolderName(existing: [String]) -> String`;
  `enum NotesWindowSelection: Hashable { case scope(NotesScope), due, done, deleted, tag(String) }`; `SelectionFallback.resolve(_:folderIDs:tagNames:) -> NotesWindowSelection`; `SelectionFallback.noteID(_:loaded:) -> String?`.

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RalloTests/FolderNamingTests.swift`:

```swift
import XCTest

final class FolderNamingTests: XCTestCase {
    func testTheFirstFreeNewFolderName() {
        XCTAssertEqual(FolderNaming.newFolderName(existing: []), "New Folder")
        XCTAssertEqual(FolderNaming.newFolderName(existing: ["Work", "Ideas"]), "New Folder")
        XCTAssertEqual(FolderNaming.newFolderName(existing: ["Work", "new folder"]), "New Folder 2", "case does not matter")
        XCTAssertEqual(FolderNaming.newFolderName(existing: ["New Folder", "New Folder 2", "NEW FOLDER 4"]), "New Folder 3")
    }
}
```

Create `apps/macos/RalloTests/SelectionFallbackTests.swift`:

```swift
import XCTest

final class SelectionFallbackTests: XCTestCase {
    func testAnExistingFolderOrTagStays() {
        XCTAssertEqual(
            SelectionFallback.resolve(.scope(.folder("w")), folderIDs: ["w"], tagNames: []), .scope(.folder("w")))
        XCTAssertEqual(SelectionFallback.resolve(.tag("bug"), folderIDs: [], tagNames: ["bug"]), .tag("bug"))
        for selection in [NotesWindowSelection.scope(.all), .scope(.unfiled), .due, .done, .deleted] {
            XCTAssertEqual(SelectionFallback.resolve(selection, folderIDs: [], tagNames: []), selection)
        }
    }

    /// Review focus 5.
    func testADeletedFolderFallsBackToNotes() {
        XCTAssertEqual(
            SelectionFallback.resolve(.scope(.folder("gone")), folderIDs: ["w"], tagNames: ["bug"]), .scope(.unfiled))
    }

    /// Review focus 5.
    func testATagNoOpenNoteCarriesAnyMoreFallsBackToAllNotes() {
        XCTAssertEqual(SelectionFallback.resolve(.tag("bug"), folderIDs: ["w"], tagNames: ["release"]), .scope(.all))
    }

    func testTheSelectedNoteSurvivesOnlyWhileItIsLoaded() {
        XCTAssertEqual(SelectionFallback.noteID("a", loaded: ["a", "b"]), "a")
        XCTAssertNil(SelectionFallback.noteID("gone", loaded: ["a", "b"]))
        XCTAssertNil(SelectionFallback.noteID(nil, loaded: ["a"]))
    }
}
```

- [ ] **Step 2: Run to see the compile failure**

In `apps/macos/project.yml` after `      - path: Rallo/Notes/RalloError+Display.swift` add:

```yaml
      - path: Rallo/NotesWindow/FolderNaming.swift
      - path: Rallo/NotesWindow/NotesWindowSelection.swift
```

Run the **Swift test command** with `-only-testing:RalloTests/FolderNamingTests` (then `SelectionFallbackTests`).
Expected: FAIL (the two source files do not exist yet).

- [ ] **Step 3: Write the implementation**

Create `apps/macos/Rallo/NotesWindow/FolderNaming.swift`:

```swift
import Foundation

/// Names for folders the window makes itself (0019 §3). The core decides what
/// a valid name is (`FOLDER_NAME_INVALID`, `FOLDER_EXISTS`) and the window
/// shows its message; Swift never re-implements those rules. This only
/// guesses the first free "New Folder"; a wrong guess is answered by
/// `FOLDER_EXISTS` and the caller tries the next.
enum FolderNaming {
    /// "New Folder", then "New Folder 2", "New Folder 3", …
    static func newFolderName(existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains("new folder") else { return "New Folder" }
        var number = 2
        while taken.contains("new folder \(number)") { number += 1 }
        return "New Folder \(number)"
    }
}
```

Create `apps/macos/Rallo/NotesWindow/NotesWindowSelection.swift`:

```swift
import Foundation

/// What the notes window's sidebar has selected (0019 §11).
enum NotesWindowSelection: Hashable {
    case scope(NotesScope)
    case due, done, deleted
    case tag(String)
}

enum SelectionFallback {
    /// Where the sidebar lands after a reload: a folder that's gone (deleted
    /// here or by the CLI) switches to Notes, a tag no open note carries any
    /// more to All Notes. Everything else stays.
    static func resolve(_ selection: NotesWindowSelection, folderIDs: Set<String>, tagNames: Set<String>) -> NotesWindowSelection {
        switch selection {
        case let .scope(.folder(id)) where !folderIDs.contains(id): .scope(.unfiled)
        case let .tag(name) where !tagNames.contains(name): .scope(.all)
        default: selection
        }
    }

    /// The selected note survives a reload only while it is in what loaded.
    static func noteID(_ selected: String?, loaded: Set<String>) -> String? {
        selected.flatMap { loaded.contains($0) ? $0 : nil }
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run the **Swift test command** with `-only-testing:RalloTests/FolderNamingTests`, then with `-only-testing:RalloTests/SelectionFallbackTests`.
Expected: both suites pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/FolderNaming.swift apps/macos/Rallo/NotesWindow/NotesWindowSelection.swift apps/macos/RalloTests/FolderNamingTests.swift apps/macos/RalloTests/SelectionFallbackTests.swift apps/macos/project.yml
git commit -m "feat(app): folder naming rules and the window's selection fallback"
```

---

### Task 5: Save debounce state machine (pure)

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/SaveScheduler.swift`
- Create: `apps/macos/RalloTests/SaveSchedulerTests.swift`
- Modify: `apps/macos/project.yml` (test sources)

**Interfaces:**
- Consumes: nothing.
- Produces: `struct SaveScheduler { enum Phase: Equatable { clean, dirty(lastEdit: Date), saving(editedMeanwhile: Bool), held, conflict }; init(delay: TimeInterval = 0.6, now: @escaping () -> Date = Date.init); private(set) var phase: Phase; var hasUnsavedText: Bool; var dueAt: Date?; mutating func edited(); mutating func takeDue() -> Bool; mutating func takeFlush() -> Bool; mutating func saved(); mutating func refused(); mutating func conflicted(); mutating func keepMine(); mutating func reset() }`.

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RalloTests/SaveSchedulerTests.swift`:

```swift
import XCTest

final class SaveSchedulerTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private let clock = Clock()

    private func scheduler() -> SaveScheduler {
        SaveScheduler(delay: 0.6, now: { [clock] in clock.now })
    }

    func testASaveFallsDueSixTenthsAfterTheLastKeystroke() {
        var scheduler = scheduler()
        XCTAssertFalse(scheduler.hasUnsavedText)
        scheduler.edited()
        clock.advance(0.5)
        XCTAssertFalse(scheduler.takeDue())
        scheduler.edited()  // typing again pushes the deadline out
        clock.advance(0.5)
        XCTAssertFalse(scheduler.takeDue())
        clock.advance(0.1)
        XCTAssertTrue(scheduler.takeDue())
        XCTAssertEqual(scheduler.phase, .saving(editedMeanwhile: false))
        XCTAssertNil(scheduler.dueAt)
    }

    func testFlushSavesRightAwayOnlyWhenSomethingIsPending() {
        var scheduler = scheduler()
        XCTAssertFalse(scheduler.takeFlush())
        scheduler.edited()
        XCTAssertTrue(scheduler.takeFlush())
        XCTAssertFalse(scheduler.takeFlush(), "already saving")
    }

    func testTypingDuringASaveSavesAgainAfterIt() {
        var scheduler = scheduler()
        scheduler.edited()
        XCTAssertTrue(scheduler.takeFlush())
        scheduler.edited()
        XCTAssertEqual(scheduler.phase, .saving(editedMeanwhile: true))
        scheduler.saved()
        XCTAssertEqual(scheduler.phase, .dirty(lastEdit: clock.now))
        XCTAssertEqual(scheduler.dueAt, clock.now.addingTimeInterval(0.6))
        XCTAssertTrue(scheduler.hasUnsavedText)
    }

    func testASaveWithNoMoreTypingEndsClean() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.saved()
        XCTAssertEqual(scheduler.phase, .clean)
    }

    func testARefusedSaveWaitsForTheNextKeystroke() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.refused()
        XCTAssertEqual(scheduler.phase, .held)
        XCTAssertTrue(scheduler.hasUnsavedText)
        clock.advance(10)
        XCTAssertFalse(scheduler.takeDue(), "a refused save is not retried on a timer")
        scheduler.edited()
        XCTAssertEqual(scheduler.phase, .dirty(lastEdit: clock.now))
    }

    func testARefusalWithTypingMeanwhileTriesAgainOnTheNewText() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.edited()
        scheduler.refused()
        XCTAssertEqual(scheduler.phase, .dirty(lastEdit: clock.now))
    }

    func testAConflictSavesNothingUntilTheBarIsAnswered() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.conflicted()
        scheduler.edited()
        clock.advance(5)
        XCTAssertEqual(scheduler.phase, .conflict)
        XCTAssertFalse(scheduler.takeDue())
        XCTAssertFalse(scheduler.takeFlush())
        scheduler.keepMine()  // Keep Mine: due at once
        XCTAssertTrue(scheduler.takeDue())
    }

    func testShowTheirsAndLeavingGoBackToClean() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.conflicted()
        scheduler.reset()
        XCTAssertEqual(scheduler.phase, .clean)
        XCTAssertFalse(scheduler.hasUnsavedText)
    }

    func testKeepMineOutsideAConflictDoesNothing() {
        var scheduler = scheduler()
        scheduler.keepMine()
        XCTAssertEqual(scheduler.phase, .clean)
    }
}
```

- [ ] **Step 2: Run to see the compile failure**

In `apps/macos/project.yml` after `      - path: Rallo/Notes/RalloError+Display.swift` add `      - path: Rallo/NotesWindow/SaveScheduler.swift`. Run the **Swift test command** with `-only-testing:RalloTests/SaveSchedulerTests`.
Expected: FAIL (`SaveScheduler.swift` does not exist).

- [ ] **Step 3: Write the implementation**

Create `apps/macos/Rallo/NotesWindow/SaveScheduler.swift`:

```swift
import Foundation

/// When the notes window's editor saves (0019 §11): 0.6 s after typing
/// stops, or right away when the selection changes or the window closes. A
/// pure state machine; the editor session owns the timer and the core call.
struct SaveScheduler {
    enum Phase: Equatable {
        /// Nothing unsaved.
        case clean
        /// Typed; due `delay` after the last keystroke.
        case dirty(lastEdit: Date)
        /// A save is running; `editedMeanwhile` keystrokes arrived after it began.
        case saving(editedMeanwhile: Bool)
        /// The core refused (empty note, too long): nothing to retry until the next keystroke.
        case held
        /// The note changed somewhere else; the bar decides, so nothing saves.
        case conflict
    }

    let delay: TimeInterval
    private let now: () -> Date
    private(set) var phase: Phase = .clean

    init(delay: TimeInterval = 0.6, now: @escaping () -> Date = Date.init) {
        self.delay = delay
        self.now = now
    }

    /// Typing that hasn't reached the database (or was refused).
    var hasUnsavedText: Bool { phase != .clean }

    /// When the pending save falls due; nil when none is waiting.
    var dueAt: Date? {
        if case let .dirty(lastEdit) = phase { return lastEdit.addingTimeInterval(delay) }
        return nil
    }

    mutating func edited() {
        switch phase {
        case .saving: phase = .saving(editedMeanwhile: true)
        case .conflict: break
        case .clean, .dirty, .held: phase = .dirty(lastEdit: now())
        }
    }

    /// The timer fired. True when a save must start now.
    mutating func takeDue() -> Bool {
        guard let due = dueAt, now() >= due else { return false }
        phase = .saving(editedMeanwhile: false)
        return true
    }

    /// The selection changes or the window closes. True when a save must start now.
    mutating func takeFlush() -> Bool {
        guard case .dirty = phase else { return false }
        phase = .saving(editedMeanwhile: false)
        return true
    }

    mutating func saved() {
        if case .saving(editedMeanwhile: true) = phase {
            phase = .dirty(lastEdit: now())
        } else {
            phase = .clean
        }
    }

    mutating func refused() {
        if case .saving(editedMeanwhile: true) = phase {
            phase = .dirty(lastEdit: now())
        } else {
            phase = .held
        }
    }

    mutating func conflicted() { phase = .conflict }

    /// Keep Mine: save again, now, on the new revision.
    mutating func keepMine() {
        guard phase == .conflict else { return }
        phase = .dirty(lastEdit: .distantPast)
    }

    /// Show Theirs, or leaving the note.
    mutating func reset() { phase = .clean }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run the **Swift test command** with `-only-testing:RalloTests/SaveSchedulerTests`.
Expected: `Test Suite 'SaveSchedulerTests' passed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/SaveScheduler.swift apps/macos/RalloTests/SaveSchedulerTests.swift apps/macos/project.yml
git commit -m "feat(app): save debounce state machine for the notes window editor"
```

---

### Task 6: Editor styling spans and the attribute-only restyler

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/EditorStyling.swift`
- Create: `apps/macos/Rallo/NotesWindow/NoteTextStyler.swift`
- Create: `apps/macos/RalloTests/EditorStylingTests.swift`
- Modify: `apps/macos/project.yml` (test sources)

**Interfaces:**
- Consumes: `NoteParts` (0018), `TagRange` and `tagRanges(text:)` (release 1).
- Produces:
  `struct EditorSpan: Equatable { enum Kind { title, tag }; kind; range: NSRange }`; `EditorStyling.titleSize = 24`, `.bodySize = 14.5`, `.titleRange(in:) -> NSRange?`, `.spans(text:tags:) -> [EditorSpan]`;
  `struct RowText: Equatable { title, preview; init(_ text: String); displayTitle }`;
  `final class PlainTextView: NSTextView { static func make() -> PlainTextView }`; `NoteTextStyler.Palette { ink, rust: NSColor }` (Task 12 passes the theme's dynamic `NSColor`s, which resolve per appearance at draw time, so nothing restyles on an appearance change); `NoteTextStyler.font(size:weight:rounded:) -> NSFont`; `NoteTextStyler.restyle(_ view: NSTextView, tags: [TagRange], palette: Palette) -> Bool` (false and no change while marked text exists).

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RalloTests/EditorStylingTests.swift`:

```swift
import AppKit
import XCTest

final class EditorStylingTests: XCTestCase {
    private let palette = NoteTextStyler.Palette(ink: .black, rust: .red)

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle, options: .literal)
    }

    private func tagSpans(_ spans: [EditorSpan]) -> [NSRange] { spans.filter { $0.kind == .tag }.map(\.range) }

    // MARK: Title range

    func testTheTitleIsTheFirstLineOrTheTextBeforeAColonAndSpace() {
        XCTAssertEqual(EditorStyling.titleRange(in: "Ledger audit logs\nStore who changed what"), NSRange(location: 0, length: 17))
        XCTAssertEqual(EditorStyling.titleRange(in: "Plan: ship it"), NSRange(location: 0, length: 4))
        XCTAssertEqual(EditorStyling.titleRange(in: "  \n Plan\nbody"), range(of: "Plan", in: "  \n Plan\nbody"))
        XCTAssertNil(EditorStyling.titleRange(in: "No title here"))
        XCTAssertNil(EditorStyling.titleRange(in: ""))
    }

    func testTheTitleRangeCountsUTF16ForBanglaAndEmoji() {
        let bangla = "কাজ: #কাজ করো 🦊 #bug-"
        XCTAssertEqual(EditorStyling.titleRange(in: bangla), NSRange(location: 0, length: 3), "ক া জ are three UTF-16 units")
        let emoji = "🦊 fox\nbody"
        XCTAssertEqual(EditorStyling.titleRange(in: emoji), NSRange(location: 0, length: 6), "the fox is a surrogate pair")
    }

    func testACRLFLineBreakEndsTheTitleAtTheRightPlace() {
        let text = "Plan\r\n#bug later\r\nmore"
        XCTAssertEqual(EditorStyling.titleRange(in: text), NSRange(location: 0, length: 4))
        let spans = EditorStyling.spans(text: text, tags: tagRanges(text: text))
        XCTAssertEqual(tagSpans(spans), [range(of: "#bug", in: text)])
        XCTAssertEqual(range(of: "#bug", in: text).location, 6, "\r\n is two UTF-16 units")
    }

    // MARK: Tags, from the core's ranges

    func testBanglaEmojiAndATrailingHyphenTag() {
        let text = "কাজ: #কাজ করো 🦊 #bug-"
        let spans = EditorStyling.spans(text: text, tags: tagRanges(text: text))
        XCTAssertEqual(tagSpans(spans), [range(of: "#কাজ", in: text), range(of: "#bug", in: text)])
        XCTAssertEqual(spans.first?.kind, .title)
    }

    func testATagAfterAnEmojiAndSpace() {
        let text = "🦊 #fox and C# and https://x.y/#frag"
        let spans = EditorStyling.spans(text: text, tags: tagRanges(text: text))
        XCTAssertEqual(tagSpans(spans), [range(of: "#fox", in: text)], "C# and a URL fragment are not tags")
    }

    func testStaleRangesPastTheEndAreDropped() {
        let stale = TagRange(utf16Start: 2, utf16Len: 40, name: "x")
        XCTAssertTrue(tagSpans(EditorStyling.spans(text: "ab #x", tags: [stale])).isEmpty)
    }

    // MARK: List text

    func testRowTextIsTheTitleAndWhatFollows() {
        XCTAssertEqual(RowText("Standup\nWhat changed\nsince Friday").title, "Standup")
        XCTAssertEqual(RowText("Standup\nWhat changed\nsince Friday").preview, "What changed since Friday")
        XCTAssertEqual(RowText("Call the dentist").title, "Call the dentist")
        XCTAssertEqual(RowText("Call the dentist").preview, "")
        XCTAssertEqual(RowText("One line that is long enough to be a body but has two\nparts here").title, "One line that is long enough to be a body but has two")
    }

    func testAnImageOnlyNoteIsCalledImage() {
        XCTAssertEqual(RowText("").displayTitle, "Image")
        XCTAssertEqual(RowText("  \n ").displayTitle, "Image")
    }

    // MARK: Attributes

    private func textView(_ text: String) -> (PlainTextView, NSWindow) {
        let view = PlainTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view  // an offscreen window, so input methods have somewhere to live
        view.string = text
        return (view, window)
    }

    func testTitleAndTagAttributes() {
        let text = "Plan: ship #bug today"
        let (view, window) = textView(text)
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: text), palette: palette))
        let storage = view.textStorage!
        func font(at index: Int) -> NSFont { storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont }
        func color(at index: Int) -> NSColor { storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor }
        XCTAssertEqual(font(at: 0).pointSize, 24)
        XCTAssertEqual(color(at: 0), .black)
        XCTAssertEqual(font(at: 8).pointSize, 14.5)  // "ship"
        let tag = (text as NSString).range(of: "#bug").location
        XCTAssertEqual(color(at: tag), .red)
        XCTAssertEqual(font(at: tag).pointSize, 14.5)
        XCTAssertEqual(color(at: tag + 4), .black)
        XCTAssertEqual(view.string, text)
        withExtendedLifetime(window) {}
    }

    func testATagInsideTheTitleKeepsTheTitleSize() {
        let text = "Fix #bug\nlater"
        let (view, window) = textView(text)
        NoteTextStyler.restyle(view, tags: tagRanges(text: text), palette: palette)
        let font = view.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, 24)
        XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .red)
        withExtendedLifetime(window) {}
    }

    /// Review focus 1: an input method's composition must survive restyling.
    func testRestyleLeavesMarkedTextAlone() {
        let (view, window) = textView("#bug ")
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 1), replacementRange: NSRange(location: 5, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let before = view.string
        XCTAssertFalse(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), palette: palette))
        XCTAssertEqual(view.string, before)
        XCTAssertTrue(view.hasMarkedText(), "restyling must not end the composition")
        view.unmarkText()
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), palette: palette))
        withExtendedLifetime(window) {}
    }

    func testThePlainTextViewIsPlainTextKitOne() {
        let (view, window) = textView("")
        XCTAssertFalse(view.isRichText)
        XCTAssertFalse(view.importsGraphics)
        XCTAssertNotNil(view.layoutManager, "TextKit 1: the editor measures its height with the layout manager")
        withExtendedLifetime(window) {}
    }
}
```

If `setMarkedText` crashes in the headless test host on this macOS, keep the offscreen window and call `window.makeFirstResponder(view)` before `setMarkedText`; if it still cannot run, move that single test to the manual check in Task 11 and say so in the commit body.

- [ ] **Step 2: Run to see the compile failure**

In `apps/macos/project.yml` after `      - path: Rallo/Notes/RalloError+Display.swift` add:

```yaml
      - path: Rallo/NotesWindow/EditorStyling.swift
      - path: Rallo/NotesWindow/NoteTextStyler.swift
```

Run the **Swift test command** with `-only-testing:RalloTests/EditorStylingTests`.
Expected: FAIL (sources missing).

- [ ] **Step 3: Write the implementation**

Create `apps/macos/Rallo/NotesWindow/EditorStyling.swift`:

```swift
import Foundation

/// What the notes window's editor styles in a note's text (0019 §11). Pure:
/// ranges are UTF-16, as `NSTextView` and the core's `tag_ranges` count.
struct EditorSpan: Equatable {
    enum Kind: Equatable { case title, tag }

    let kind: Kind
    let range: NSRange
}

enum EditorStyling {
    static let titleSize: CGFloat = 24
    static let bodySize: CGFloat = 14.5

    /// The `NoteParts` title where it sits in the text (leading blank space
    /// skipped); nil when the note has none.
    static func titleRange(in text: String) -> NSRange? {
        guard let title = NoteParts(text).title else { return nil }
        let range = (text as NSString).range(of: title, options: .literal)
        return range.location == NSNotFound ? nil : range
    }

    /// The title, then each tag. The core's ranges cover the `#` and are UTF-16
    /// offsets into exactly the string passed to `tagRanges` (§7); one that
    /// doesn't fit the text is dropped.
    static func spans(text: String, tags: [TagRange]) -> [EditorSpan] {
        let length = (text as NSString).length
        var spans: [EditorSpan] = []
        if let title = titleRange(in: text) { spans.append(EditorSpan(kind: .title, range: title)) }
        for tag in tags {
            let range = NSRange(location: Int(tag.utf16Start), length: Int(tag.utf16Len))
            guard range.length > 0, NSMaxRange(range) <= length else { continue }
            spans.append(EditorSpan(kind: .tag, range: range))
        }
        return spans
    }
}

/// A note's two lines in the list: its title (or first line) and what follows.
struct RowText: Equatable {
    let title: String
    let preview: String

    init(_ text: String) {
        let parts = NoteParts(text)
        if let title = parts.title {
            self.title = title
            preview = parts.preview
        } else {
            let lines = parts.body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            title = lines.first ?? ""
            preview = lines.dropFirst().joined(separator: " ")
        }
    }

    /// An image-only note has no text to show.
    var displayTitle: String { title.isEmpty ? "Image" : title }
}
```

Create `apps/macos/Rallo/NotesWindow/NoteTextStyler.swift`:

```swift
import AppKit

/// The editor's text view: plain text only. Paste drops fonts, colours and attachments.
final class PlainTextView: NSTextView {
    /// TextKit 1 (the editor measures with its layout manager), plain text, no
    /// smart quotes or dashes rewriting what the user typed.
    static func make() -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        return view
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

enum NoteTextStyler {
    /// Pass dynamic colours (`Theme.inkNS`, `Theme.rustNS`): they resolve in the
    /// view's appearance when drawn, so Light/Dark needs no restyle.
    struct Palette {
        var ink: NSColor
        var rust: NSColor
    }

    static func font(size: CGFloat, weight: NSFont.Weight, rounded: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Styles by attributes only: the string, the selection and any input
    /// method's marked text are never touched. While marked text exists
    /// nothing is applied; the change after the input method commits
    /// restyles. Returns whether it styled.
    @discardableResult
    static func restyle(_ view: NSTextView, tags: [TagRange], palette: Palette) -> Bool {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return false }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: font(size: EditorStyling.bodySize, weight: .regular, rounded: false),
            .foregroundColor: palette.ink,
            .paragraphStyle: paragraph,
        ]
        let titleFont = font(size: EditorStyling.titleSize, weight: .semibold, rounded: true)
        let tagFont = font(size: EditorStyling.bodySize, weight: .semibold, rounded: false)
        let spans = EditorStyling.spans(text: storage.string, tags: tags)
        let titles = spans.filter { $0.kind == .title }.map(\.range)
        storage.beginEditing()
        storage.setAttributes(body, range: NSRange(location: 0, length: storage.length))
        for range in titles {
            storage.addAttribute(.font, value: titleFont, range: range)
        }
        for span in spans where span.kind == .tag {
            let inTitle = titles.contains { NSIntersectionRange($0, span.range).length > 0 }
            storage.addAttributes([.foregroundColor: palette.rust, .font: inTitle ? titleFont : tagFont], range: span.range)
        }
        storage.endEditing()
        view.typingAttributes = body
        return true
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run the **Swift test command** with `-only-testing:RalloTests/EditorStylingTests`.
Expected: `Test Suite 'EditorStylingTests' passed`. (This file was compiled and exercised against stand-ins during planning; real `tagRanges` values come from the core. If a Bangla expectation fails, the core's range is the source of truth: compare against Task 1's slices before touching `EditorStyling`.)

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/EditorStyling.swift apps/macos/Rallo/NotesWindow/NoteTextStyler.swift apps/macos/RalloTests/EditorStylingTests.swift apps/macos/project.yml
git commit -m "feat(app): editor title and tag styling that never touches marked text"
```

---

### Task 7: The editor session (text, saving, conflicts, drafts)

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/NoteEditorSession.swift`
- Create: `apps/macos/RalloTests/NoteEditorSessionTests.swift`
- Modify: `apps/macos/project.yml` (test sources)

**Interfaces:**
- Consumes: `SaveScheduler` (Task 5), `CoreClient.editItemText(_:text:)` (existing), `CoreClient.createNote(_:images:folderID:)` (release 2), `RalloError.displayMessage`, `ItemSnapshot.name` (0018).
- Produces: `@MainActor final class NoteEditorSession: ObservableObject` with
  `enum Target { case none; case note(ItemSnapshot); case draft(folderID: String?, seed: String) }`;
  `@Published private(set) var text: String`, `target: Target`, `conflict: Bool`, `error: String?`, `focusToken: Int`; `var isComposing: Bool`; `var onCreated: (ItemSnapshot) -> Void`; `var onSaved: (ItemSnapshot) -> Void`; `private(set) var showCount: Int`; `var note: ItemSnapshot?`; `var isDraft: Bool`; `var isEditable: Bool`; `var hasUnsavedText: Bool`;
  `init(core: CoreClient, saveDelay: TimeInterval = 0.6, now: @escaping () -> Date = Date.init)`; `func show(_ target: Target, focus: Bool = false)`; `func textChanged(_ newText: String)`; `func sync(_ latest: ItemSnapshot)`; `func showTheirs(_ latest: ItemSnapshot)`; `func keepMine(_ latest: ItemSnapshot)`; `func flush() async`; `@discardableResult func leave() async -> String?`.

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RalloTests/NoteEditorSessionTests.swift`:

```swift
import XCTest

/// The editor session against a real temp store; `other` is a second handle,
/// standing in for the CLI or an agent.
@MainActor
final class NoteEditorSessionTests: XCTestCase {
    private var dataDir: URL!
    private var core: CoreClient!
    private var other: RalloStore!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-editor-\(UUID().uuidString)")
        core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        other = try RalloStore.open(dataDir: dataDir.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func session(delay: TimeInterval = 0.05) -> NoteEditorSession {
        NoteEditorSession(core: core, saveDelay: delay)
    }

    private func stored(_ id: String) throws -> ItemSnapshot {
        try XCTUnwrap(other.listOpenItems(limit: 50).first { $0.id == id })
    }

    /// Only for checks that something did NOT happen; to wait for a save, use `settle`.
    private func pause(_ seconds: Double = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits for the debounced save to land (at most 2 s) instead of sleeping a fixed time.
    private func settle(_ session: NoteEditorSession) async {
        let deadline = Date().addingTimeInterval(2)
        while session.hasUnsavedText, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await session.flush()  // a save that is still running finishes
    }

    func testTypingSavesAfterTheDelay() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        session.textChanged("v2")
        XCTAssertEqual(try stored(note.id).text, "v1", "not yet")
        await settle(session)
        XCTAssertEqual(try stored(note.id).text, "v2")
        XCTAssertFalse(session.hasUnsavedText)
        XCTAssertEqual(session.note?.revision, 2, "the session keeps the saved revision")
    }

    func testFlushSavesRightAway() async throws {
        let note = try await core.createNote("v1")
        let session = session(delay: 60)
        session.show(.note(note))
        session.textChanged("v2")
        await session.flush()
        XCTAssertEqual(try stored(note.id).text, "v2")
    }

    /// Review focus 2.
    func testAnEmptiedNoteIsNeverSavedAndComesBack() async throws {
        let note = try await core.createNote("Keep me")
        let session = session(delay: 60)
        session.show(.note(note))
        session.textChanged("   \n ")
        await session.flush()
        XCTAssertEqual(try stored(note.id).text, "Keep me")
        let message = await session.leave()
        XCTAssertNil(message, "restoring an emptied note is silent")
        XCTAssertEqual(session.text, "Keep me")
        XCTAssertFalse(session.hasUnsavedText)
    }

    /// Review focus 3.
    func testAChangeSomewhereElseShowsTheConflictBar() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        XCTAssertTrue(session.conflict)
        XCTAssertEqual(session.text, "mine", "the typing stays in the editor")
        XCTAssertEqual(try stored(note.id).text, "theirs")
        await pause()
        XCTAssertEqual(try stored(note.id).text, "theirs", "nothing saves behind the bar")
    }

    func testKeepMineSavesOnTheNewRevision() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        session.keepMine(try stored(note.id))
        await settle(session)
        XCTAssertFalse(session.conflict)
        XCTAssertEqual(try stored(note.id).text, "mine")
    }

    func testShowTheirsTakesTheLatestText() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        session.showTheirs(try stored(note.id))
        XCTAssertFalse(session.conflict)
        XCTAssertEqual(session.text, "theirs")
        XCTAssertFalse(session.hasUnsavedText)
    }

    func testLeavingWithAnUnansweredConflictSaysSo() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.textChanged("mine")
        await session.flush()
        let message = await session.leave()
        XCTAssertEqual(message, "Your last changes to “v1” weren’t saved.")
    }

    func testATextTooLongIsShownInlineAndKept() async throws {
        let note = try await core.createNote("v1")
        let session = session(delay: 60)
        session.show(.note(note))
        let tooLong = String(repeating: "a", count: 70_000)  // the core's limit is 64 KiB
        session.textChanged(tooLong)
        await session.flush()
        XCTAssertNotNil(session.error)
        XCTAssertFalse(session.conflict)
        XCTAssertEqual(session.text, tooLong)
        XCTAssertEqual(try stored(note.id).text, "v1")
        session.textChanged("short")
        XCTAssertNil(session.error, "typing clears the message")
    }

    /// Review focus 3.
    func testAReloadNeverOverwritesTyping() async throws {
        let note = try await core.createNote("v1")
        let session = session(delay: 60)
        session.show(.note(note))
        session.textChanged("typing")
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.sync(try stored(note.id))
        XCTAssertEqual(session.text, "typing")
        XCTAssertEqual(session.note?.revision, 1, "it still saves on the revision it started from")
    }

    func testAReloadUpdatesAnIdleEditor() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        _ = try other.editItemText(id: note.id, text: "theirs", ifRevision: nil)
        session.sync(try stored(note.id))
        XCTAssertEqual(session.text, "theirs")
        XCTAssertEqual(session.note?.revision, 2)
    }

    /// Review focus 1.
    func testMarkedTextDelaysTheSave() async throws {
        let note = try await core.createNote("v1")
        let session = session()
        session.show(.note(note))
        session.isComposing = true
        session.textChanged("v2 にほ")
        await pause()
        XCTAssertEqual(try stored(note.id).text, "v1", "never save a half-composed word")
        session.isComposing = false
        session.textChanged("v2 日本")
        await settle(session)
        XCTAssertEqual(try stored(note.id).text, "v2 日本")
    }

    func testADraftIsCreatedByTheFirstNonEmptySaveInItsFolder() async throws {
        let work = try await core.createFolder("Work")
        let session = session()
        var created: [ItemSnapshot] = []
        session.onCreated = { created.append($0) }
        session.show(.draft(folderID: work.id, seed: ""), focus: true)
        XCTAssertTrue(session.isDraft)
        session.textChanged("  ")
        await session.flush()
        XCTAssertTrue(try other.listOpenItems(limit: 50).isEmpty, "a blank draft is discarded, not saved")
        session.textChanged("Hello #bug")
        await session.flush()
        let all = try other.listOpenItems(limit: 50)
        XCTAssertEqual(all.map(\.text), ["Hello #bug"])
        XCTAssertEqual(all.first?.folderId, work.id)
        XCTAssertEqual(created.map(\.id), all.map(\.id))
        XCTAssertEqual(session.note?.id, all.first?.id, "the session now edits the created note")
        session.textChanged("Hello #bug again")
        await session.flush()
        XCTAssertEqual(try other.listOpenItems(limit: 50).map(\.text), ["Hello #bug again"], "later saves edit, not create")
    }

    func testADraftThatStillReadsAsItsSeedIsEmpty() async throws {
        let session = session()
        session.show(.draft(folderID: nil, seed: "#bug "))
        XCTAssertEqual(session.text, "#bug ")
        session.textChanged("#bug ")
        await session.flush()
        XCTAssertTrue(try other.listOpenItems(limit: 50).isEmpty)
        let message = await session.leave()
        XCTAssertNil(message)
    }

    func testAnUnsavedDraftSurvivesLeavingByBeingSaved() async throws {
        let session = session(delay: 60)
        session.show(.draft(folderID: nil, seed: ""))
        session.textChanged("Write this down")
        await session.leave()
        XCTAssertEqual(try other.listOpenItems(limit: 50).map(\.text), ["Write this down"])
    }

    func testADeletedNoteIsReadOnly() async throws {
        let note = try await core.createNote("gone")
        let deleted = try await core.deleteItem(note)
        let session = session()
        session.show(.note(deleted))
        XCTAssertFalse(session.isEditable)
        session.show(.note(note))
        XCTAssertTrue(session.isEditable)
    }
}
```

- [ ] **Step 2: Run to see the compile failure**

In `apps/macos/project.yml` after `      - path: Rallo/Notes/RalloError+Display.swift` add `      - path: Rallo/NotesWindow/NoteEditorSession.swift`. Run the **Swift test command** with `-only-testing:RalloTests/NoteEditorSessionTests`.
Expected: FAIL (`NoteEditorSession.swift` missing).

- [ ] **Step 3: Write the implementation**

Create `apps/macos/Rallo/NotesWindow/NoteEditorSession.swift`:

```swift
import Combine
import Foundation

/// The note open in the notes window's editor and when its text is saved
/// (0019 §11). Typing saves 0.6 s after it stops (`SaveScheduler`), and
/// `leave()` saves what's pending before the selection changes or the window
/// closes. It never saves an emptied note, never overwrites unsaved typing
/// with a reload, and turns a stale revision into the conflict bar.
@MainActor
final class NoteEditorSession: ObservableObject {
    enum Target {
        case none
        case note(ItemSnapshot)
        /// The "New Note" row: created by the first non-empty save, in `folderID`.
        /// `seed` is text the editor starts with (`#tag ` in a tag's scope);
        /// a draft that still reads as its seed is empty.
        case draft(folderID: String?, seed: String)
    }

    /// What the text view shows. The text view writes it through `textChanged`.
    @Published private(set) var text = ""
    @Published private(set) var target: Target = .none
    /// "This note changed somewhere else." is showing.
    @Published private(set) var conflict = false
    /// A refused save (`TEXT_TOO_LONG`, …), shown inline; the text stays.
    @Published private(set) var error: String?
    /// Moves the caret to the text view; bumped for a new note.
    @Published private(set) var focusToken = 0
    /// Counts `show` calls, so the text view knows a different note arrived.
    private(set) var showCount = 0
    /// The text view has an input method's marked text: never save mid-composition.
    var isComposing = false
    /// A draft's first save created this note.
    var onCreated: (ItemSnapshot) -> Void = { _ in }
    /// A save reached the database; the window reloads.
    var onSaved: (ItemSnapshot) -> Void = { _ in }

    private let core: CoreClient
    private var scheduler: SaveScheduler
    private var timer: Task<Void, Never>?
    private var running: Task<Void, Never>?

    init(core: CoreClient, saveDelay: TimeInterval = 0.6, now: @escaping () -> Date = Date.init) {
        self.core = core
        scheduler = SaveScheduler(delay: saveDelay, now: now)
    }

    var note: ItemSnapshot? {
        if case let .note(note) = target { return note }
        return nil
    }

    var isDraft: Bool {
        if case .draft = target { return true }
        return false
    }

    /// A deleted note can be read, not edited (Restore it first).
    var isEditable: Bool {
        switch target {
        case .none: false
        case let .note(note): note.deletedAtMs == nil
        case .draft: true
        }
    }

    var hasUnsavedText: Bool { scheduler.hasUnsavedText }

    /// Opens a note, nothing, or a draft. Call `leave()` first.
    func show(_ target: Target, focus: Bool = false) {
        timer?.cancel()
        scheduler.reset()
        conflict = false
        error = nil
        self.target = target
        switch target {
        case .none: text = ""
        case let .note(note): text = note.text
        case let .draft(_, seed): text = seed
        }
        showCount += 1
        if focus { focusToken += 1 }
    }

    /// The text view changed (the user typed, pasted or deleted).
    func textChanged(_ newText: String) {
        if case .none = target { return }
        text = newText
        error = nil
        scheduler.edited()
        armTimer()
    }

    /// A reload brought the note's latest state. Unsaved typing is never
    /// overwritten: it saves on the revision it started from, and the
    /// conflict bar answers if the note moved on.
    func sync(_ latest: ItemSnapshot) {
        guard case let .note(current) = target, current.id == latest.id else { return }
        guard !scheduler.hasUnsavedText, !isComposing else { return }
        target = .note(latest)
        if text != latest.text { text = latest.text }
    }

    /// Show Theirs: the note as it is now.
    func showTheirs(_ latest: ItemSnapshot) {
        show(.note(latest))
    }

    /// Keep Mine: the typed text saves again on the note's new revision.
    func keepMine(_ latest: ItemSnapshot) {
        guard case let .note(current) = target, current.id == latest.id else { return }
        target = .note(latest)
        conflict = false
        scheduler.keepMine()
        armTimer()
    }

    /// Saves what's pending, now, and waits for it. Safe to call anytime.
    func flush() async {
        timer?.cancel()
        while true {
            if let running {
                await running.value
                continue
            }
            guard scheduler.takeFlush() else { return }
            start()
        }
    }

    /// Saves what's pending, then lets go of the note: an emptied note gets
    /// its saved text back. Returns a sentence when typing couldn't be saved.
    @discardableResult
    func leave() async -> String? {
        await flush()
        defer {
            scheduler.reset()
            conflict = false
            error = nil
        }
        let name = note?.name ?? "the note"
        switch scheduler.phase {
        case .held where error == nil:
            if let note { text = note.text }
            return nil
        case .held, .conflict:
            return "Your last changes to “\(name)” weren’t saved."
        default:
            return nil
        }
    }

    // MARK: Saving

    private func armTimer() {
        timer?.cancel()
        guard let due = scheduler.dueAt else { return }
        timer = Task { [weak self] in
            let wait = max(0, due.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        if isComposing {
            scheduler.edited()  // look again after the input method commits
            armTimer()
        } else if scheduler.takeDue() {
            start()
        } else if scheduler.dueAt != nil {
            armTimer()
        }
    }

    private func start() {
        running = Task { [weak self] in
            await self?.save()
            self?.running = nil
        }
    }

    private func save() async {
        let sent = text
        let blank = sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        do {
            switch target {
            case .none:
                scheduler.reset()
            case let .note(note):
                // An emptied note is never saved (unless it has images to stand on).
                // `refused()` may go back to dirty (typed meanwhile): the timer must look again.
                if blank, note.images.isEmpty {
                    scheduler.refused()
                    return armTimer()
                }
                let updated = try await core.editItemText(note, text: sent)
                finish(with: updated)
                onSaved(updated)
            case let .draft(folderID, seed):
                if blank || sent.trimmingCharacters(in: .whitespacesAndNewlines) == seed.trimmingCharacters(in: .whitespacesAndNewlines) {
                    scheduler.refused()
                    return armTimer()
                }
                let created = try await core.createNote(sent, images: [], folderID: folderID)
                finish(with: created)
                onCreated(created)
            }
        } catch let failure as RalloError {
            if case let .Conflict(code, _) = failure, code == "REVISION_CONFLICT" {
                scheduler.conflicted()
                conflict = true
            } else {
                scheduler.refused()
                error = failure.displayMessage
            }
            armTimer()
        } catch {
            scheduler.refused()
            self.error = error.localizedDescription
            armTimer()
        }
    }

    /// The save went through: keep its revision, and save again if more was typed meanwhile.
    private func finish(with saved: ItemSnapshot) {
        target = .note(saved)
        scheduler.saved()
        armTimer()
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run the **Swift test command** with `-only-testing:RalloTests/NoteEditorSessionTests`.
Expected: `Test Suite 'NoteEditorSessionTests' passed`. (Saves are awaited with `settle`, bounded at 2 s; the fixed `pause` is left only where a test checks that nothing was saved. If one of those is flaky on a loaded machine, raise the pause, not the logic.)

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/NoteEditorSession.swift apps/macos/RalloTests/NoteEditorSessionTests.swift apps/macos/project.yml
git commit -m "feat(app): editor session with debounced saves, conflicts and drafts"
```

---

### Task 8: The window model (selection, reload, folders, moves, note changes)

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/NotesWindowModel.swift`
- Create: `apps/macos/Rallo/NotesWindow/NotesWindowModel+Notes.swift`
- Modify: `apps/macos/Rallo/Notes/RalloError+Display.swift` (add `code`)
- Create: `apps/macos/RalloTests/NotesWindowModelTests.swift`
- Modify: `apps/macos/project.yml` (test sources)

**Interfaces:**
- Consumes: `CoreClient` (Task 2: paged `listItems`/`searchItems`, `pageSize`, `listTags`, `renameFolder`, `cancelReminder`; release 2: `folderOverview`, `createFolder`, `deleteFolder(_ id:keepNotes:)`, `moveItem(_:folderID:)`), `NotesScope.folderScope` (release 2), `FolderNamePrompter` (release 2), `NoteEditorSession` (Task 7), `NotesWindowSelection`/`SelectionFallback` (Task 4), `FolderNaming` (Task 4), `RemindPreset` (release 2, `Notes/RemindPreset.swift`), `ReminderLabel`, `ImageClipboard.check`.
- Produces: `@MainActor final class NotesWindowModel: ObservableObject` with `PagedItems { items, nextCursor, totalCount: Int, pages: Int; hasMore }`, `WindowToast`, `PendingFolderDelete { folder; noteCount }`, and
  state `overview`, `tags`, `open`, `done`, `found` (`PagedItems`), `selection`, `selectedNoteID`, `isDrafting` (`private(set)`), `query`, `doneExpanded`, `toast`, `errorMessage`, `renamingFolderID`, `pendingFolderDelete`, `customRemindOpen`; `let core`, `let editor`, `let pageSize`, `let namePrompter` (the window's New Folder… card, Task 11);
  `init(core:saveDelay:pageSize:)`; derived `items`, `doneItems`, `results` (the loaded rows of `open`, `done`, `found`), `isSearching`, `visibleItems`, `selectedItem`, `folders`, `header: Header`, `listIsGrouped`, `canCreateNote`; `loadedItem(_:)`, `folder(_:)`, `folderName(_:)`, `groupTimestamp(_:)`;
  `opened(selection:noteID:)`, `closed()`, `select(_:)`, `selectNote(_:)`, `reload()`, `loadMore(done:)`, `queryChanged()`, `announce(_:undo:)`, `undo()`, `run(_:)`, `report(_:)`, `fresh(_:)`, `beginNewNote()`, `showTheirs()`, `keepMine()`;
  folders: `newFolderInline()`, `renameFolder(_:to:)`, `requestDelete(_:)` (synchronous: the count is `FolderSnapshot.noteCount`), `confirmDelete(_:keepNotes:)`; moves: `move(_:toFolder:)`, `canDrop(_:)`, `drop(_:onto:)`;
  notes (`+Notes`): `toggleDone`, `delete`, `restore`, `remind(_:_ preset:)`, `remind(_:at:)`, `cancelReminder`, `attachImages(_:to:)`, `removeImage(_:from:)`;
  `RalloError.code: String`.

- [ ] **Step 1: `RemindPreset` (already done)**

Release 2 already moved `RemindPreset` (and `ReminderSnapshot.deadline`) into `apps/macos/Rallo/Notes/RemindPreset.swift` and lists it in the `RalloTests` sources (Task 1 Step 2 checked both). Nothing to do; `NotesView.swift` is not touched by this task.

- [ ] **Step 2: Add `RalloError.code`**

In `apps/macos/Rallo/Notes/RalloError+Display.swift`, append inside the file:

```swift
extension RalloError {
    /// The core's error code (`REVISION_CONFLICT`, `FOLDER_EXISTS`, …).
    var code: String {
        switch self {
        case let .InvalidInput(code, _), let .NotFound(code, _), let .Conflict(code, _), let .Storage(code, _): code
        case .IncompatibleSchema: "INCOMPATIBLE_SCHEMA"
        }
    }
}
```

- [ ] **Step 3: Write the failing tests**

In `apps/macos/project.yml` after `      - path: Rallo/Notes/RalloError+Display.swift` add:

```yaml
      - path: Rallo/NotesWindow/NotesWindowModel.swift
      - path: Rallo/NotesWindow/NotesWindowModel+Notes.swift
```

Create `apps/macos/RalloTests/NotesWindowModelTests.swift`:

```swift
import XCTest

/// The window model against a real temp store; `other` is a second handle
/// standing in for the CLI.
@MainActor
final class NotesWindowModelTests: XCTestCase {
    private var dataDir: URL!
    private var core: CoreClient!
    private var other: RalloStore!
    private var model: NotesWindowModel!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-window-\(UUID().uuidString)")
        core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        other = try RalloStore.open(dataDir: dataDir.path)
        model = NotesWindowModel(core: core, saveDelay: 0.05)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    @discardableResult
    private func note(_ text: String, in folder: FolderSnapshot? = nil) throws -> ItemSnapshot {
        try other.createNoteWithImages(text: text, images: [], folderId: folder?.id)
    }

    private func folder(_ name: String) throws -> FolderSnapshot {
        try other.createFolder(name: name)
    }

    /// Waits (at most 2 s) for what a background reload or save settles, instead of sleeping a fixed time.
    private func eventually(_ condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(2)
        while try !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Loading

    func testReloadLoadsTheOverviewTagsAndAllNotes() async throws {
        let work = try folder("Work")
        try note("Plan #release", in: work)
        try note("Dentist")
        await model.reload()
        XCTAssertEqual(model.overview?.allOpen, 2)
        XCTAssertEqual(model.overview?.unfiledOpen, 1)
        XCTAssertEqual(model.folders.map(\.name), ["Work"])
        XCTAssertEqual(model.tags.map(\.name), ["release"])
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.header, NotesWindowModel.Header(title: "All Notes", subtitle: "2 open · 0 done"))
    }

    func testAFolderListsItsOpenNotesAndCountsItsDoneOnes() async throws {
        let work = try folder("Work")
        let finished = try note("Finished", in: work)
        try note("Open one", in: work)
        try note("Elsewhere")
        _ = try other.completeItem(id: finished.id, ifRevision: nil)
        await model.select(.scope(.folder(work.id)))
        XCTAssertEqual(model.items.map(\.text), ["Open one"])
        XCTAssertEqual(model.doneItems.map(\.text), ["Finished"])
        XCTAssertEqual(model.header, NotesWindowModel.Header(title: "Work", subtitle: "1 open · 1 done"))
    }

    func testATagListsOpenNotesAcrossFolders() async throws {
        let work = try folder("Work")
        try note("a #bug", in: work)
        try note("b #bug")
        try note("c")
        await model.select(.tag("bug"))
        XCTAssertEqual(Set(model.items.map(\.text)), ["a #bug", "b #bug"])
        XCTAssertEqual(model.header.title, "#bug")
    }

    func testDueDoneAndDeletedViews() async throws {
        let a = try note("done one")
        _ = try other.completeItem(id: a.id, ifRevision: nil)
        let b = try note("deleted one")
        _ = try other.deleteItem(id: b.id, ifRevision: nil)
        await model.select(.done)
        XCTAssertEqual(model.items.map(\.text), ["done one"])
        XCTAssertEqual(model.header, NotesWindowModel.Header(title: "Done", subtitle: "1 note"))
        await model.select(.deleted)
        XCTAssertEqual(model.items.map(\.text), ["deleted one"])
        await model.select(.due)
        XCTAssertEqual(model.header.title, "Due")
        XCTAssertFalse(model.listIsGrouped)
        XCTAssertFalse(model.canCreateNote)
    }

    func testOpenNotesAreNewestFirst() async throws {
        try note("first")
        try await Task.sleep(nanoseconds: 20_000_000)
        try note("second")
        await model.reload()
        XCTAssertEqual(model.items.map(\.text), ["second", "first"])
    }

    // MARK: Paging (0019 §9)

    /// `count` notes, oldest first, each in its own millisecond so the list order is fixed.
    private func notes(_ count: Int) async throws -> [ItemSnapshot] {
        var made: [ItemSnapshot] = []
        for number in 1...count {
            made.append(try note("Note \(number)"))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return made
    }

    func testAListLoadsAPageAtATimeAndCountsTheWholeList() async throws {
        model = NotesWindowModel(core: core, saveDelay: 0.05, pageSize: 2)
        _ = try await notes(5)
        await model.reload()
        XCTAssertEqual(model.open.items.count, 2)
        XCTAssertEqual(model.open.totalCount, 5)
        XCTAssertTrue(model.open.hasMore)
        XCTAssertEqual(model.header.subtitle, "5 open · 0 done", "the count is the whole list, never what loaded")
        await model.loadMore()
        await model.loadMore()
        XCTAssertEqual(model.open.items.count, 5)
        XCTAssertFalse(model.open.hasMore)
        XCTAssertEqual(Set(model.open.items.map(\.id)).count, 5, "no row twice")
        await model.loadMore()
        XCTAssertEqual(model.open.items.count, 5, "nothing more to load")
    }

    /// Review focus 5: a reload fetches as many pages as were loaded, so the selection stays.
    func testASelectionOnALaterPageSurvivesAReload() async throws {
        model = NotesWindowModel(core: core, saveDelay: 0.05, pageSize: 2)
        let made = try await notes(5)
        let oldest = try XCTUnwrap(made.first)
        await model.reload()
        await model.loadMore()
        await model.loadMore()
        XCTAssertEqual(model.open.items.last?.id, oldest.id, "newest first: the first note is on the last page")
        await model.selectNote(oldest.id)
        try note("Note 6")
        await model.reload()
        XCTAssertEqual(model.open.items.count, 6)
        XCTAssertEqual(model.selectedNoteID, oldest.id)
        XCTAssertEqual(model.editor.note?.id, oldest.id)
    }

    func testSearchResultsPageToo() async throws {
        model = NotesWindowModel(core: core, saveDelay: 0.05, pageSize: 2)
        _ = try await notes(3)
        model.query = "Note"
        await model.reload()
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.header, NotesWindowModel.Header(title: "Results", subtitle: "3 notes"))
        await model.loadMore()
        XCTAssertEqual(model.results.count, 3)
        XCTAssertFalse(model.found.hasMore)
    }

    // MARK: Selection falls back

    /// Review focus 5.
    func testADeletedScopeFolderFallsBackToNotes() async throws {
        let work = try folder("Work")
        try note("In work", in: work)
        await model.select(.scope(.folder(work.id)))
        _ = try other.deleteFolder(id: work.id, keepNotes: true)
        await model.reload()
        XCTAssertEqual(model.selection, .scope(.unfiled))
        XCTAssertEqual(model.items.map(\.text), ["In work"], "kept notes show up in Notes")
    }

    func testAVanishedTagFallsBackToAllNotes() async throws {
        let tagged = try note("a #bug")
        await model.select(.tag("bug"))
        _ = try other.editItemText(id: tagged.id, text: "a", ifRevision: nil)
        await model.reload()
        XCTAssertEqual(model.selection, .scope(.all))
    }

    func testASelectedNoteDeletedElsewhereClearsTheSelection() async throws {
        let item = try note("Doomed")
        await model.reload()
        await model.selectNote(item.id)
        XCTAssertEqual(model.editor.note?.id, item.id)
        _ = try other.deleteItem(id: item.id, ifRevision: nil)
        await model.reload()
        XCTAssertNil(model.selectedNoteID)
        XCTAssertNil(model.editor.note)
    }

    func testAMarkedDoneNoteStaysSelectedInItsScope() async throws {
        let item = try note("Finish me")
        await model.reload()
        await model.selectNote(item.id)
        await model.toggleDone(item)
        XCTAssertEqual(model.selectedNoteID, item.id)
        XCTAssertEqual(model.selectedItem?.status, .done)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.doneItems.count, 1)
    }

    // MARK: Search

    func testSearchListsResultsAcrossFoldersAndClearingReturnsToTheScope() async throws {
        let work = try folder("Work")
        try note("budget plan", in: work)
        try note("budget notes")
        try note("unrelated")
        await model.select(.scope(.unfiled))
        model.query = "budget"
        await model.reload()
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(Set(model.visibleItems.map(\.text)), ["budget plan", "budget notes"])
        XCTAssertEqual(model.header.title, "Results")
        XCTAssertFalse(model.canCreateNote)
        model.query = ""
        model.queryChanged()
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(Set(model.visibleItems.map(\.text)), ["budget notes", "unrelated"])
        XCTAssertEqual(model.header.title, "Notes")
    }

    // MARK: Moving

    func testMoveToAFolderAndUndo() async throws {
        let work = try folder("Work")
        let item = try note("Move me")
        await model.reload()
        await model.move(item, toFolder: work.id)
        XCTAssertEqual(model.loadedItem(item.id)?.folderId, work.id)
        XCTAssertEqual(model.toast?.message, "Moved to Work")
        await model.undo()
        XCTAssertNil(model.loadedItem(item.id)?.folderId)
        XCTAssertNil(model.toast)
    }

    func testDroppingANoteMovesItAndUnknownIDsAreIgnored() async throws {
        let work = try folder("Work")
        let item = try note("Drag me")
        await model.reload()
        XCTAssertFalse(model.canDrop(["not-a-note"]))
        await model.drop(["not-a-note"], onto: work.id)
        XCTAssertNil(model.toast)
        XCTAssertTrue(model.canDrop([item.id]))
        await model.drop([item.id], onto: work.id)
        XCTAssertEqual(model.loadedItem(item.id)?.folderId, work.id)
    }

    func testMovingWhileTypingSavesTheTypingFirst() async throws {
        let work = try folder("Work")
        let item = try note("v1")
        await model.reload()
        await model.selectNote(item.id)
        model.editor.textChanged("v2")
        await model.move(item, toFolder: work.id)
        XCTAssertNil(model.errorMessage, "no revision conflict with our own save")
        let stored = try XCTUnwrap(other.listOpenItems(limit: 50).first)
        XCTAssertEqual(stored.text, "v2")
        XCTAssertEqual(stored.folderId, work.id)
    }

    // MARK: Folders

    func testNewFolderInlineNamesSelectsAndStartsRenaming() async throws {
        await model.newFolderInline()
        let first = try XCTUnwrap(model.folders.first)
        XCTAssertEqual(first.name, "New Folder")
        XCTAssertEqual(model.selection, .scope(.folder(first.id)))
        XCTAssertEqual(model.renamingFolderID, first.id)
        await model.newFolderInline()
        XCTAssertEqual(Set(model.folders.map(\.name)), ["New Folder", "New Folder 2"])
    }

    func testARefusedRenameStaysInTheFieldWithTheCoresReason() async throws {
        let work = try folder("Work")
        _ = try folder("Ideas")
        await model.reload()
        model.renamingFolderID = work.id
        for refused in ["notes", "ideas", "   "] {  // reserved, taken (any case), empty: the core says no
            model.errorMessage = nil
            await model.renameFolder(work, to: refused)
            XCTAssertNotNil(model.errorMessage, "“\(refused)” should show the core's message")
            XCTAssertEqual(model.renamingFolderID, work.id, "the field stays editable")
        }
        await model.renameFolder(work, to: "  Projects ")
        XCTAssertNil(model.renamingFolderID)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.folders.map(\.name), ["Ideas", "Projects"])
    }

    func testARenameMayChangeOnlyTheCase() async throws {
        let work = try folder("work")
        await model.reload()
        await model.renameFolder(work, to: "Work")
        XCTAssertEqual(model.folders.map(\.name), ["Work"])
    }

    /// Review focus 4.
    func testDeletingAFolderOfOnlyDoneNotesKeepsThem() async throws {
        let work = try folder("Work")
        let finished = try note("Finished", in: work)
        _ = try other.completeItem(id: finished.id, ifRevision: nil)
        await model.reload()
        let snapshot = try XCTUnwrap(model.folder(work.id))
        XCTAssertEqual(snapshot.openCount, 0)
        XCTAssertEqual(snapshot.noteCount, 1)
        model.requestDelete(snapshot)
        XCTAssertEqual(model.pendingFolderDelete?.noteCount, 1)
        await model.confirmDelete(try XCTUnwrap(model.pendingFolderDelete), keepNotes: true)
        XCTAssertNil(model.pendingFolderDelete)
        XCTAssertTrue(model.folders.isEmpty)
        await model.select(.done)
        XCTAssertEqual(model.items.map(\.text), ["Finished"])
        XCTAssertNil(model.items.first?.folderId)
    }

    func testDeleteNotesSendsThemToDeletedWhereTheyCanBeRestored() async throws {
        let work = try folder("Work")
        try note("Goes", in: work)
        await model.reload()
        model.requestDelete(try XCTUnwrap(model.folder(work.id)))
        XCTAssertEqual(model.pendingFolderDelete?.noteCount, 1)
        await model.confirmDelete(try XCTUnwrap(model.pendingFolderDelete), keepNotes: false)
        await model.select(.deleted)
        XCTAssertEqual(model.items.map(\.text), ["Goes"])
        await model.restore(try XCTUnwrap(model.items.first))
        await model.select(.scope(.unfiled))
        XCTAssertEqual(model.items.map(\.text), ["Goes"], "restored into Notes: the folder is gone")
    }

    func testAnEmptyFolderCountsZero() async throws {
        let ideas = try folder("Ideas")
        await model.reload()
        model.requestDelete(try XCTUnwrap(model.folder(ideas.id)))
        XCTAssertEqual(model.pendingFolderDelete?.noteCount, 0)
    }

    // MARK: Notes

    func testDeleteAndUndoRestore() async throws {
        let item = try note("Delete me")
        await model.reload()
        await model.delete(item)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.toast?.message, "Deleted “Delete me”")
        await model.undo()
        XCTAssertEqual(model.items.map(\.text), ["Delete me"])
    }

    func testMarkAsDoneAndReopen() async throws {
        let item = try note("Finish")
        await model.reload()
        await model.toggleDone(item)
        XCTAssertEqual(model.toast?.message, "Marked “Finish” as done")
        let done = try XCTUnwrap(model.doneItems.first)
        await model.toggleDone(done)
        XCTAssertEqual(model.items.map(\.text), ["Finish"])
    }

    func testRemindAndCancelReminder() async throws {
        let item = try note("Remind me")
        await model.reload()
        await model.remind(item, .inOneHour)
        let reminded = try XCTUnwrap(model.loadedItem(item.id))
        XCTAssertEqual(reminded.reminder?.state, .active)
        await model.cancelReminder(reminded)
        XCTAssertEqual(model.loadedItem(item.id)?.reminder?.state, .cancelled)
        XCTAssertEqual(model.loadedItem(item.id)?.status, .open, "the note stays open")
    }

    // MARK: New notes

    func testANewNoteIsCreatedInTheScopesFolder() async throws {
        let work = try folder("Work")
        await model.select(.scope(.folder(work.id)))
        await model.beginNewNote()
        XCTAssertTrue(model.isDrafting)
        XCTAssertNil(model.selectedNoteID)
        model.editor.textChanged("Fresh idea")
        await model.editor.flush()
        await eventually { model.items.count == 1 }  // the reload after the create
        XCTAssertFalse(model.isDrafting)
        let created = try XCTUnwrap(try other.listOpenItems(limit: 50).first)
        XCTAssertEqual(created.folderId, work.id)
        XCTAssertEqual(model.selectedNoteID, created.id)
        XCTAssertEqual(model.items.map(\.id), [created.id])
    }

    func testANewNoteInATagScopeStartsWithTheTag() async throws {
        try note("seed #bug")
        await model.select(.tag("bug"))
        await model.beginNewNote()
        XCTAssertEqual(model.editor.text, "#bug ")
        XCTAssertTrue(model.editor.isDraft)
    }

    func testNewNoteIsRefusedWhereTheListCannotShowIt() async throws {
        await model.select(.done)
        await model.beginNewNote()
        XCTAssertFalse(model.isDrafting)
    }

    func testSwitchingAwayFromAnUntouchedDraftDiscardsIt() async throws {
        try note("other")
        await model.reload()
        await model.beginNewNote()
        let existing = try XCTUnwrap(model.items.first)
        await model.selectNote(existing.id)
        XCTAssertFalse(model.isDrafting)
        XCTAssertEqual(try other.listOpenItems(limit: 50).count, 1)
    }

    func testClosingTheWindowDiscardsAnUntouchedDraft() async throws {
        await model.reload()
        await model.beginNewNote()
        await model.closed()
        XCTAssertFalse(model.isDrafting, "reopening must not show a stale New Note row")
        XCTAssertFalse(model.editor.isDraft)
        XCTAssertTrue(try other.listOpenItems(limit: 50).isEmpty)
    }

    // MARK: Conflict answers

    func testShowTheirsAndKeepMineGoThroughTheModel() async throws {
        let item = try note("v1")
        await model.reload()
        await model.selectNote(item.id)
        _ = try other.editItemText(id: item.id, text: "theirs", ifRevision: nil)
        model.editor.textChanged("mine")
        await model.editor.flush()
        XCTAssertTrue(model.editor.conflict)
        await model.showTheirs()
        XCTAssertFalse(model.editor.conflict)
        XCTAssertEqual(model.editor.text, "theirs")

        _ = try other.editItemText(id: item.id, text: "theirs 2", ifRevision: nil)
        model.editor.textChanged("mine 2")
        await model.editor.flush()
        XCTAssertTrue(model.editor.conflict)
        await model.keepMine()
        try await eventually { try other.listOpenItems(limit: 50).first?.text == "mine 2" }
        XCTAssertEqual(try other.listOpenItems(limit: 50).first?.text, "mine 2")
    }
}
```

- [ ] **Step 4: Run to see the compile failure**

Run the **Swift test command** with `-only-testing:RalloTests/NotesWindowModelTests`.
Expected: FAIL (model files missing).

- [ ] **Step 5: Write the model**

Create `apps/macos/Rallo/NotesWindow/NotesWindowModel.swift`:

```swift
import Combine
import Foundation

/// A transient message at the bottom of the window's list, optionally undoable.
struct WindowToast: Identifiable {
    let id = UUID()
    let message: String
    let undo: (() async -> Void)?
}

/// A folder the delete sheet (0019 §12) is asking about.
struct PendingFolderDelete: Identifiable {
    let folder: FolderSnapshot
    /// Open + done, nondeleted: the core's `note_count` (0019 §9), what `folder delete` calls "holds".
    var noteCount: Int { Int(folder.noteCount) }

    var id: String { folder.id }
}

/// The loaded pages of one list and how to get the next (0019 §9).
struct PagedItems {
    var items: [ItemSnapshot] = []
    var nextCursor: String?
    /// The whole list's length, however much of it has loaded.
    var totalCount = 0
    /// Pages fetched so far: a reload fetches as many again, so a note selected on page 3 stays loaded.
    var pages = 0

    var hasMore: Bool { nextCursor != nil }
}

/// The notes window's state (0019 §11): what the sidebar selected, what the
/// list shows, the open note, folder changes, and the reload that keeps all of
/// it in step with the change signal. Views read it; AppKit prompts and
/// panels stay out of it, so it runs against a real store in tests.
@MainActor
final class NotesWindowModel: ObservableObject {
    @Published private(set) var overview: FolderOverview?
    @Published private(set) var tags: [TagSnapshot] = []
    /// The selection's list: open notes for a folder, tag or All Notes; the
    /// whole view for Due, Done and Deleted.
    @Published private(set) var open = PagedItems()
    /// Done notes of the same folder or tag, behind the "N done" row.
    @Published private(set) var done = PagedItems()
    /// Search results, across every folder.
    @Published private(set) var found = PagedItems()
    @Published private(set) var selection: NotesWindowSelection = .scope(.all)
    @Published private(set) var selectedNoteID: String?
    /// The "New Note" row is showing.
    @Published private(set) var isDrafting = false
    @Published var query = ""
    @Published var doneExpanded = false
    @Published private(set) var toast: WindowToast?
    @Published var errorMessage: String?
    @Published var renamingFolderID: String?
    @Published var pendingFolderDelete: PendingFolderDelete?
    /// The Custom… reminder popover is open on the selected note.
    @Published var customRemindOpen = false

    let core: CoreClient
    let editor: NoteEditorSession
    /// The window's New Folder… card (0019 §10), drawn over the whole window (Task 11).
    let namePrompter = FolderNamePrompter()
    /// Rows per page (tests pass 2 to exercise paging).
    let pageSize: UInt32
    private var generation = 0
    /// The cursor being fetched, so a last row appearing twice doesn't load its page twice.
    private var loadingCursor: String?
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(core: CoreClient, saveDelay: TimeInterval = 0.6, pageSize: UInt32 = CoreClient.pageSize) {
        self.core = core
        self.pageSize = pageSize
        editor = NoteEditorSession(core: core, saveDelay: saveDelay)
        editor.onSaved = { [weak self] _ in Task { await self?.reload() } }
        editor.onCreated = { [weak self] note in self?.draftCreated(note) }
    }

    // MARK: What the window shows

    var items: [ItemSnapshot] { open.items }
    var doneItems: [ItemSnapshot] { done.items }
    var results: [ItemSnapshot] { found.items }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var visibleItems: [ItemSnapshot] { isSearching ? results : items }

    /// Every note the list has loaded, done ones included.
    private var loaded: [ItemSnapshot] { isSearching ? results : items + doneItems }

    func loadedItem(_ id: String) -> ItemSnapshot? { loaded.first { $0.id == id } }

    var selectedItem: ItemSnapshot? { selectedNoteID.flatMap(loadedItem) }

    var folders: [FolderSnapshot] { overview?.folders ?? [] }

    func folder(_ id: String) -> FolderSnapshot? { folders.first { $0.id == id } }

    /// "Notes" for no folder, else the folder's name.
    func folderName(_ id: String?) -> String {
        id.flatMap { folder($0)?.name } ?? "Notes"
    }

    struct Header: Equatable {
        let title: String
        let subtitle: String
    }

    /// Counts are the core's `totalCount`s: the whole list, never what has loaded.
    var header: Header {
        if isSearching { return Header(title: "Results", subtitle: Self.notes(found.totalCount)) }
        let openAndDone = "\(open.totalCount) open · \(done.totalCount) done"
        switch selection {
        case let .scope(scope):
            let title = switch scope {
            case .all: "All Notes"
            case .unfiled: "Notes"
            case let .folder(id): folderName(id)
            }
            return Header(title: title, subtitle: openAndDone)
        case let .tag(name): return Header(title: "#\(name)", subtitle: openAndDone)
        case .due: return Header(title: "Due", subtitle: Self.notes(open.totalCount))
        case .done: return Header(title: "Done", subtitle: Self.notes(open.totalCount))
        case .deleted: return Header(title: "Deleted", subtitle: Self.notes(open.totalCount))
        }
    }

    private static func notes(_ count: Int) -> String {
        "\(count) \(count == 1 ? "note" : "notes")"
    }

    /// Due has no date groups; the others group by a date (`groupTimestamp`).
    var listIsGrouped: Bool {
        if isSearching { return false }
        if case .due = selection { return false }
        return true
    }

    /// Open notes group by creation, Done by completion, Deleted by deletion.
    func groupTimestamp(_ item: ItemSnapshot) -> Int64 {
        switch selection {
        case .done: item.completedAtMs ?? item.updatedAtMs
        case .deleted: item.deletedAtMs ?? item.updatedAtMs
        default: item.createdAtMs
        }
    }

    /// New Note (⌘N) works in a folder, Notes, All Notes or a tag, not in
    /// Due, Done, Deleted or search results.
    var canCreateNote: Bool {
        if isSearching { return false }
        switch selection {
        case .scope, .tag: return true
        case .due, .done, .deleted: return false
        }
    }

    // MARK: Opening, selecting

    /// The window opened (or came forward): show `requested` (the panel's
    /// scope), reload, and select `noteID` if it's in the list.
    func opened(selection requested: NotesWindowSelection?, noteID: String?) async {
        if let requested, requested != selection {
            await select(requested)
        } else {
            await reload()
        }
        if let noteID, loadedItem(noteID) != nil { await selectNote(noteID) }
    }

    /// The window closed: save typing; an emptied note gets its text back, and
    /// an untouched "New Note" goes (one that got text was already created).
    func closed() async {
        namePrompter.cancel()
        if let message = await editor.leave() { errorMessage = message }
        if isDrafting {
            isDrafting = false
            editor.show(.none)
        }
    }

    func select(_ new: NotesWindowSelection) async {
        guard new != selection else { return }
        await letGoOfNote()
        selection = new
        query = ""
        open = PagedItems()
        done = PagedItems()
        found = PagedItems()
        doneExpanded = false
        await reload()
    }

    func selectNote(_ id: String?) async {
        guard id != selectedNoteID || isDrafting else { return }
        await letGoOfNote()
        selectedNoteID = id
        if let item = selectedItem { editor.show(.note(item)) } else { editor.show(.none) }
    }

    /// Saves typing and closes the editor's note; what couldn't be saved is said once.
    private func letGoOfNote() async {
        if let message = await editor.leave() { errorMessage = message }
        isDrafting = false
        selectedNoteID = nil
        editor.show(.none)
    }

    // MARK: Reload

    /// Reads everything the window shows. Overlapping reloads settle on the
    /// newest, and a note being edited keeps its unsaved typing (the editor
    /// session decides). Each list fetches as many pages as it had loaded, so
    /// a note selected on a later page stays selected.
    func reload() async {
        generation += 1
        let mine = generation
        do {
            let overview = try await core.folderOverview()
            let tags = try await core.listTags()
            let target = SelectionFallback.resolve(
                selection, folderIDs: Set(overview.folders.map(\.id)), tagNames: Set(tags.map(\.name))
            )
            let keep = target == selection  // a fallback starts over on page 1
            let openList = try await fetch(pages: keep ? open.pages : 1) { try await page(target, done: false, cursor: $0) }
            var doneList = PagedItems()
            if Self.hasDoneList(target) {
                doneList = try await fetch(pages: keep ? done.pages : 1) { try await page(target, done: true, cursor: $0) }
            }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var foundList = PagedItems()
            if !text.isEmpty {
                foundList = try await fetch(pages: found.pages) { try await core.searchItems(text, cursor: $0, limit: pageSize) }
            }
            guard mine == generation else { return }
            self.overview = overview
            self.tags = tags
            if target != selection {
                selection = target
                doneExpanded = false
            }
            open = openList
            done = doneList
            found = foundList
            await syncSelectedNote()
        } catch {
            errorMessage = "Couldn’t load notes: \(error.localizedDescription)"
        }
    }

    /// One page of the selection's list (`done`: the "N done" list of a folder,
    /// Notes, All Notes or tag). The core orders every list: newest first, Done
    /// by completion, Deleted by deletion, Due by deadline.
    private func page(_ selection: NotesWindowSelection, done: Bool, cursor: String?) async throws -> ItemPage {
        let kind: ItemListKind = done ? .done : .open
        switch selection {
        case let .scope(scope): return try await core.listItems(kind, scope: scope.folderScope, cursor: cursor, limit: pageSize)
        case let .tag(name): return try await core.listItems(kind, tag: name, cursor: cursor, limit: pageSize)
        case .due: return try await core.listItems(.due, cursor: cursor, limit: pageSize)
        case .done: return try await core.listItems(.done, cursor: cursor, limit: pageSize)
        case .deleted: return try await core.listItems(.deleted, cursor: cursor, limit: pageSize)
        }
    }

    /// Folders, Notes, All Notes and tags have the second "N done" list; Due, Done and Deleted don't.
    private static func hasDoneList(_ selection: NotesWindowSelection) -> Bool {
        switch selection {
        case .scope, .tag: true
        case .due, .done, .deleted: false
        }
    }

    /// `pages` pages (at least one) of one list, following the core's cursors.
    private func fetch(pages: Int, _ next: (String?) async throws -> ItemPage) async throws -> PagedItems {
        var loaded = PagedItems()
        var cursor: String?
        repeat {
            let got = try await next(cursor)
            loaded.items += got.items
            loaded.totalCount = Int(got.totalCount)
            loaded.pages += 1
            cursor = got.nextCursor
        } while cursor != nil && loaded.pages < max(1, pages)
        loaded.nextCursor = cursor
        return loaded
    }

    /// The last loaded row of a list came into view: its next page (0019 §9).
    /// `done` picks the "N done" list; while searching it's the results.
    func loadMore(done wantDone: Bool = false) async {
        let searching = isSearching  // the field can change while the page loads
        let list = searching ? found : (wantDone ? done : open)
        guard let cursor = list.nextCursor, cursor != loadingCursor else { return }
        loadingCursor = cursor
        defer { if loadingCursor == cursor { loadingCursor = nil } }
        let mine = generation
        do {
            let next: ItemPage
            if searching {
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                next = try await core.searchItems(text, cursor: cursor, limit: pageSize)
            } else {
                next = try await page(selection, done: wantDone, cursor: cursor)
            }
            guard mine == generation, searching == isSearching else { return }  // the list was replaced meanwhile
            var updated = list
            updated.items += next.items
            updated.nextCursor = next.nextCursor
            updated.totalCount = Int(next.totalCount)
            updated.pages += 1
            if searching { found = updated } else if wantDone { done = updated } else { open = updated }
        } catch {
            await report(error)
        }
    }

    /// After a reload: the open note takes its latest state, or, when it's
    /// gone from the list (deleted or moved elsewhere), the selection clears.
    private func syncSelectedNote() async {
        guard let id = selectedNoteID else { return }
        let ids = Set(loaded.map(\.id))
        if SelectionFallback.noteID(id, loaded: ids) != nil {
            if let item = loadedItem(id) { editor.sync(item) }
        } else {
            await letGoOfNote()
        }
    }

    /// A debounced search: the field's text changed.
    func queryChanged() {
        searchTask?.cancel()
        // New words start over on page 1; the old results stay up until the new ones land.
        if isSearching { found.pages = 0 } else { found = PagedItems() }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: Toasts and errors

    func announce(_ message: String, undo: (() async -> Void)? = nil) {
        errorMessage = nil
        toastTask?.cancel()
        toast = WindowToast(message: message, undo: undo)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func undo() async {
        guard let undo = toast?.undo else { return }
        toastTask?.cancel()
        toast = nil
        await undo()
    }

    /// Runs one core change, then reloads; a failure reloads and says why.
    func run(_ work: (CoreClient) async throws -> Void) async {
        errorMessage = nil
        do {
            try await work(core)
            await reload()
        } catch {
            await report(error)
        }
    }

    func report(_ error: Error) async {
        await reload()
        if let error = error as? RalloError {
            if error.code == "REVISION_CONFLICT" {
                errorMessage = "That note changed elsewhere; here’s the latest."
            } else {
                errorMessage = error.displayMessage
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    /// A note as the database has it now: typing is saved first, so a change
    /// made from the toolbar never trips over the editor's own revision.
    func fresh(_ item: ItemSnapshot) async -> ItemSnapshot {
        if item.id == editor.note?.id, editor.hasUnsavedText {
            await editor.flush()
            await reload()
        }
        let listed = loadedItem(item.id)
        // A save a moment ago may not have reached the list yet: the editor's copy is newer.
        if let saved = editor.note, saved.id == item.id, saved.revision > (listed?.revision ?? 0) { return saved }
        return listed ?? item
    }

    // MARK: A new note

    /// ⌘N: a "New Note" draft at the top of the list, selected, editor focused.
    func beginNewNote() async {
        guard canCreateNote else { return }
        await letGoOfNote()
        isDrafting = true
        let folderID: String? = if case let .scope(.folder(id)) = selection { id } else { nil }
        let seed = if case let .tag(name) = selection { "#\(name) " } else { "" }
        editor.show(.draft(folderID: folderID, seed: seed), focus: true)
    }

    /// The draft's first save created the note: select it.
    private func draftCreated(_ note: ItemSnapshot) {
        generation += 1  // a reload already running can't know the note
        isDrafting = false
        selectedNoteID = note.id
        Task { await reload() }
    }

    // MARK: Conflict bar

    /// Show Theirs: the note as it is now.
    func showTheirs() async {
        guard let id = editor.note?.id else { return }
        await reload()
        if let latest = loadedItem(id) { editor.showTheirs(latest) } else { await letGoOfNote() }
    }

    /// Keep Mine: the typed text saves again on the note's new revision.
    func keepMine() async {
        guard let id = editor.note?.id else { return }
        await reload()
        if let latest = loadedItem(id) { editor.keepMine(latest) } else { await letGoOfNote() }
    }

    // MARK: Folders

    /// "+ New Folder" and ⌘⇧N: creates "New Folder" (or "New Folder 2", …) and
    /// starts an inline rename. The local name is a guess; the core's
    /// `FOLDER_EXISTS` decides, and the next guess is tried.
    func newFolderInline() async {
        var name = FolderNaming.newFolderName(existing: folders.map(\.name))
        for _ in 0..<20 {
            do {
                let folder = try await core.createFolder(name)
                await select(.scope(.folder(folder.id)))
                renamingFolderID = folder.id
                return
            } catch let error as RalloError where error.code == "FOLDER_EXISTS" {
                await reload()  // someone else made it first (the CLI); try the next free name
                name = FolderNaming.newFolderName(existing: folders.map(\.name))
            } catch {
                await report(error)
                return
            }
        }
    }

    /// Inline rename. The core judges the name: a refusal shows its message
    /// and the field stays editable.
    func renameFolder(_ folder: FolderSnapshot, to name: String) async {
        do {
            _ = try await core.renameFolder(folder, to: name)
            renamingFolderID = nil
            errorMessage = nil
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Delete Folder…: the sheet asks (0019 §12), counting `folder.noteCount`.
    func requestDelete(_ folder: FolderSnapshot) {
        pendingFolderDelete = PendingFolderDelete(folder: folder)
    }

    /// Keep Notes (`keepNotes`) files them in Notes; Delete Notes sends them to Deleted.
    func confirmDelete(_ pending: PendingFolderDelete, keepNotes: Bool) async {
        pendingFolderDelete = nil
        do {
            _ = try await core.deleteFolder(pending.folder.id, keepNotes: keepNotes)
            announce("Deleted “\(pending.folder.name)”")
            await reload()  // a deleted scope folder falls back to Notes
        } catch {
            await report(error)
        }
    }

    // MARK: Moving notes

    func move(_ item: ItemSnapshot, toFolder folderID: String?) async {
        let item = await fresh(item)
        guard item.folderId != folderID else { return }
        do {
            let moved = try await core.moveItem(item, folderID: folderID)
            let before = item.folderId
            announce("Moved to \(folderName(folderID))") { [weak self] in
                await self?.run { _ = try await $0.moveItem(moved, folderID: before) }
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// A note dragged onto a sidebar folder. Ids that aren't a nondeleted note in the list are ignored.
    func canDrop(_ ids: [String]) -> Bool { ids.contains { loadedItem($0).map { $0.deletedAtMs == nil } ?? false } }

    func drop(_ ids: [String], onto folderID: String?) async {
        guard let item = ids.compactMap(loadedItem).first(where: { $0.deletedAtMs == nil }) else { return }
        await move(item, toFolder: folderID)
    }
}
```

Create `apps/macos/Rallo/NotesWindow/NotesWindowModel+Notes.swift`:

```swift
import Combine
import Foundation

/// Changes to the open note and the notes in the list (0019 §11). Each one
/// first lets the editor save, so a toolbar action never races the editor's
/// own revision; each says what it did, with Undo where the panel has it.
extension NotesWindowModel {
    /// The completion circle and Mark as Done / Reopen.
    func toggleDone(_ item: ItemSnapshot) async {
        let item = await fresh(item)
        do {
            if item.status == .done {
                _ = try await core.reopenItem(item)
            } else {
                let done = try await core.completeItem(item)
                announce("Marked “\(done.name)” as done") { [weak self] in
                    await self?.run { _ = try await $0.reopenItem(done) }
                }
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Soft delete (the trash button and ⌫); Undo restores it.
    func delete(_ item: ItemSnapshot) async {
        let item = await fresh(item)
        do {
            let deleted = try await core.deleteItem(item)
            announce("Deleted “\(deleted.name)”") { [weak self] in
                await self?.run { _ = try await $0.restoreItem(deleted) }
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// Restore, in the Deleted view: the note returns to its folder (or Notes).
    func restore(_ item: ItemSnapshot) async {
        do {
            let restored = try await core.restoreItem(item)
            announce("Restored “\(restored.name)”")
            await reload()
        } catch {
            await report(error)
        }
    }

    /// The same three choices as the panel's Remind Me menu.
    func remind(_ item: ItemSnapshot, _ preset: RemindPreset) async {
        let item = await fresh(item)
        await setReminder { core in
            switch preset {
            case .inTwentyMinutes: try await core.remindIn(item, duration: "20m")
            case .inOneHour: try await core.remindIn(item, duration: "1h")
            case .tomorrowMorning: try await core.remindAt(item, date: RemindPreset.tomorrowMorning())
            }
        }
    }

    /// Custom…, with the time the popover previewed.
    func remind(_ item: ItemSnapshot, at date: Date) async {
        let item = await fresh(item)
        await setReminder { try await $0.remindAt(item, date: date) }
    }

    private func setReminder(_ change: (CoreClient) async throws -> ItemSnapshot) async {
        do {
            let updated = try await change(core)
            if let reminder = updated.reminder {
                let deadline = Date(timeIntervalSince1970: TimeInterval(reminder.deadlineMs) / 1000)
                announce("Reminder set for \(ReminderLabel.text(for: deadline))")
            }
            await reload()
        } catch {
            await report(error)
        }
    }

    /// The reminder pill's Cancel Reminder (0019 §9): the reminder becomes
    /// `cancelled`, the note stays open.
    func cancelReminder(_ item: ItemSnapshot) async {
        let item = await fresh(item)
        await run { _ = try await $0.cancelReminder(item) }
    }

    /// Add Image: the images the user picked, already normalised.
    func attachImages(_ images: [Data], to item: ItemSnapshot) async {
        let item = await fresh(item)
        do {
            try ImageClipboard.check(images, staged: item.images.count)
            _ = try await core.attachImages(item, images: images)
            await reload()
        } catch let refusal as ImageRefusal {
            errorMessage = refusal.message
        } catch {
            await report(error)
        }
    }

    /// Remove Image; the bytes are read first so Undo can attach the image again.
    func removeImage(_ image: ImageSnapshot, from item: ItemSnapshot) async {
        let item = await fresh(item)
        let data = try? Data(contentsOf: URL(fileURLWithPath: image.path))
        do {
            let updated = try await core.detachImage(item, imageID: image.id)
            announce("Removed the image", undo: data.map { data in
                { [weak self] in await self?.run { _ = try await $0.attachImages(updated, images: [data]) } }
            })
            await reload()
        } catch {
            await report(error)
        }
    }
}
```

- [ ] **Step 6: Run the tests and see them pass**

Run the **Swift test command** with `-only-testing:RalloTests/NotesWindowModelTests` (the scheme builds the whole app target too).
Expected: `NotesWindowModelTests` passes. If `testRemindAndCancelReminder` fails on `.active`, print `reminded.reminder` first: a one-hour reminder on a scratch store should be `.active`; Cancel Reminder leaves it `.cancelled` (never `.acknowledged`, which is the "I saw the alert" path).

- [ ] **Step 7: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/NotesWindowModel.swift apps/macos/Rallo/NotesWindow/NotesWindowModel+Notes.swift apps/macos/Rallo/Notes/RalloError+Display.swift apps/macos/RalloTests/NotesWindowModelTests.swift apps/macos/project.yml
git commit -m "feat(app): notes window model for selection, reload, folders and note changes"
```

---

### Task 9: The window shell, Dock presence, and every way to open it

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/NotesWindowController.swift`
- Create: `apps/macos/Rallo/NotesWindow/NotesWindowView.swift`
- Modify: `apps/macos/Rallo/App/AppDelegate.swift`, `apps/macos/Rallo/App/AppCoordinator.swift`, `apps/macos/Rallo/App/StatusMenuController.swift`
- Modify: `apps/macos/Rallo/Settings/SettingsWindowController.swift`, `apps/macos/Rallo/Notes/NotesView.swift`, `apps/macos/Rallo/Notes/NotesViewModel.swift`, `apps/macos/Rallo/Diagnostics/WindowReport.swift`

**Interfaces:**
- Consumes: `NotesWindowModel` (Task 8, including `namePrompter`), `NotesWindowSelection` (Task 4), `NotesViewModel.scope`, `.expandedID`, `.namePromptShown`, `.scopeMenuOpen` (release 2 / existing), `NotesPanelController.window/isOpen/close()`, release 2's `PanelDefaults.defaults(forDataDir:)` line in `AppCoordinator.init`.
- Produces:
  `@MainActor final class NotesWindowController: NSObject, NSWindowDelegate { init(model:defaults:); var onPresenceChange: (Bool) -> Void; var isOpen: Bool; var isKey: Bool; var nsWindow: NSWindow?; func show(selection: NotesWindowSelection? = nil, noteID: String? = nil); func focusSearch() }` (the frame is saved under `RalloNotesWindow` in the injected defaults, never AppKit autosave);
  `NotesWindowView(model:)`; `NotesViewModel.onExpand: () -> Void`; `SettingsWindowController.isOpen`, `.bringForward()`; `AppCoordinator`: `openNotesWindow()`, `notesWindowAcceptsCommands`, `notesWindowCanCreateNote`, `notesWindowHasUnsavedText`, `newNoteInNotesWindow()`, `newFolderInNotesWindow()`, `focusNotesWindowSearch()`, `flushNotesWindow() async`; `StatusMenuController.Actions.openNotesWindow`; main menu File (New Note ⌘N, New Folder ⇧⌘N, Close ⌘W), Edit gains Find ⌘F, Window (Minimize ⌘M, Notes Window).

- [ ] **Step 1: Write the window controller and the shell view**

Create `apps/macos/Rallo/NotesWindow/NotesWindowController.swift`:

```swift
import AppKit
import Quartz
import SwiftUI

/// The Notes window (0019 §11): a titled, resizable window around the
/// three-column `NotesWindowView`. One window is kept for the life of the app;
/// opening it makes Rallo a Dock app, closing it (red button, ⌘W) makes it a
/// menu-bar app again.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    let model: NotesWindowModel
    /// The coordinator's scratch-aware defaults: AppKit's frame autosave would
    /// write the real app's domain from a scratch build (same bundle id).
    private let defaults: UserDefaults
    private static let frameKey = "RalloNotesWindow"
    private var window: NSWindow?
    /// Told when the window opens (true) and closes (false), so the activation
    /// policy follows it. A closing window still reads `isVisible`, hence the argument.
    var onPresenceChange: (Bool) -> Void = { _ in }

    init(model: NotesWindowModel, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
    }

    /// Showing, or minimised to the Dock.
    var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }
    var isKey: Bool { window?.isKeyWindow ?? false }
    var nsWindow: NSWindow? { window }

    /// Opens (or brings forward) the window; `selection` and `noteID` come from
    /// the panel's expand button, nil keeps what the window last showed.
    func show(selection: NotesWindowSelection? = nil, noteID: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        onPresenceChange(true)  // `.regular` first, so the window can become key
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await model.opened(selection: selection, noteID: noteID) }
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)  // the input method commits marked text before the editor saves
        rememberFrame()
        // After AppKit's close sequence: switching the policy inside it can leave the menu bar unpainted.
        DispatchQueue.main.async { [weak self] in self?.onPresenceChange(false) }
        Task { await model.closed() }
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    /// ⌘F: the toolbar's search field (`.searchable` puts an `NSSearchToolbarItem` there).
    func focusSearch() {
        let search = window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
        search?.beginSearchInteraction()
    }

    private func rememberFrame() {
        if let window { defaults.set(window.frameDescriptor, forKey: Self.frameKey) }
    }

    private func makeWindow() -> NSWindow {
        let window = NotesAppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Not "Rallo Notes": that is the panel's title, and Mission Control and
        // the window report must tell the two apart.
        window.title = "Notes"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.delegate = self
        let hosting = NSHostingController(rootView: NotesWindowView(model: model))
        hosting.sizingOptions = []  // the window decides its size, not the SwiftUI content
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1140, height: 690))
        if let saved = defaults.string(forKey: Self.frameKey) {
            window.setFrame(from: saved)
        } else {
            window.center()
        }
        return window
    }
}

/// Quick Look asks the responder chain who supplies its items (0018), as it
/// does for the panel.
final class NotesAppWindow: NSWindow {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookPresenter.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}
```

Create `apps/macos/Rallo/NotesWindow/NotesWindowView.swift` (the three column bodies are temporary `Text` lines that Tasks 10, 11 and 12 replace):

```swift
import SwiftUI

/// The Notes window's content: sidebar, list, editor (0019 §11).
struct NotesWindowView: View {
    @ObservedObject var model: NotesWindowModel

    var body: some View {
        NavigationSplitView {
            Text("Sidebar")  // replaced in Task 10
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            Text("List")  // replaced in Task 11
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            Text("Editor")  // replaced in Task 12
        }
        .tint(Theme.rust)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search all notes")
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .overlay(alignment: .top) { errorBanner }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    model.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .font(Theme.rounded(12.5, .medium))
            .foregroundStyle(Theme.error)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceTop))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.error.opacity(0.45)))
            .frame(maxWidth: 520)
            .padding(.top, 10)
            .accessibilityLabel("Error: \(message)")
        }
    }
}
```

- [ ] **Step 2: Wire the app: Settings controller, status menu, panel button, coordinator, delegate, report**

`apps/macos/Rallo/Settings/SettingsWindowController.swift`, Edit: old

```swift
    init(model: SettingsModel) {
        self.model = model
    }
```

new

```swift
    init(model: SettingsModel) {
        self.model = model
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Without activating anything else: used when the Notes window closes and
    /// Settings is still up.
    func bringForward() { window?.makeKeyAndOrderFront(nil) }
```

`apps/macos/Rallo/App/StatusMenuController.swift`, three Edits (the action is `AppCoordinator.openNotesWindow()`, below):

1. old `        var openNotes: () -> Void\n        var jumpToWaitingAgent: () -> Void` → new `        var openNotes: () -> Void\n        var openNotesWindow: () -> Void\n        var jumpToWaitingAgent: () -> Void`
2. old `        menu.addItem(notesMenuItem())` → new
```swift
        menu.addItem(notesMenuItem())
        menu.addItem(item("Notes Window", #selector(openNotesWindow)))
```
3. old `    @objc private func openNotes() { actions.openNotes() }` → new
```swift
    @objc private func openNotes() { actions.openNotes() }
    @objc private func openNotesWindow() { actions.openNotesWindow() }
```

`apps/macos/Rallo/Notes/NotesViewModel.swift`, Edit: old
```swift
    /// Asks for permission (never asked yet) or opens System Settings (denied).
    var onEnableNotifications: () -> Void = {}
```
new
```swift
    /// Asks for permission (never asked yet) or opens System Settings (denied).
    var onEnableNotifications: () -> Void = {}
    /// The title bar's expand button: close the panel, open the Notes window (0019 §11).
    var onExpand: () -> Void = {}
```

`apps/macos/Rallo/Notes/NotesView.swift`, Edit in `NotesView.body`. The button sits before the scope dropdown's overlay and the New Folder dialog, so both draw over it, and it is fenced like the rest of the panel while either is up. Old
```swift
        .foregroundStyle(Theme.ink)
        .frame(width: 360, height: 460)
        .overlayPreferenceValue(FolderChipAnchorKey.self) { anchor in
```
new
```swift
        .foregroundStyle(Theme.ink)
        .frame(width: 360, height: 460)
        .overlay(alignment: .topTrailing) {
            Button {
                model.onExpand()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.bark)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Notes Window")
            .accessibilityLabel("Open Notes Window")
            .padding(.top, 1)
            .padding(.trailing, 8)
            .disabled(model.namePromptShown || model.scopeMenuOpen)
            .accessibilityHidden(model.namePromptShown || model.scopeMenuOpen)
            .blur(radius: model.namePromptShown ? 4 : 0)
        }
        .overlayPreferenceValue(FolderChipAnchorKey.self) { anchor in
```

`apps/macos/Rallo/Diagnostics/WindowReport.swift`, two Edits: old `    static func make(pet: PetController, notesWindow: NSWindow?) -> [String: Any] {` → new `    static func make(pet: PetController, notesWindow: NSWindow?, notesAppWindow: NSWindow? = nil) -> [String: Any] {`; old `        if let notesWindow { report["notes"] = describe(notesWindow) }` → new
```swift
        if let notesWindow { report["notes"] = describe(notesWindow) }
        if let notesAppWindow { report["notes_window"] = describe(notesAppWindow) }
```

`apps/macos/Rallo/App/AppCoordinator.swift`, Edits:

1. old
```swift
    private let notesModel: NotesViewModel
    private let notes: NotesPanelController
```
new
```swift
    private let notesModel: NotesViewModel
    private let notes: NotesPanelController
    private let notesWindowModel: NotesWindowModel
    private let notesWindow: NotesWindowController
    /// `.standard` for the real data dir, else the scratch suite (`PanelDefaults`):
    /// the panel's scope and the window's frame.
    private let defaults: UserDefaults
```
2. Release 2 wrote the panel model's line (`PanelDefaults`, picked by data-dir path); Task 1 Step 2 checked it is there. Hoist its defaults so the window shares them. Old
```swift
        // The panel's folder choice (0019) lives in UserDefaults, which is per
        // bundle id: any data dir but the real one must not overwrite the real app's.
        notesModel = NotesViewModel(core: core, defaults: PanelDefaults.defaults(forDataDir: dataDir))
        notes = NotesPanelController(model: notesModel)
```
new
```swift
        // The panel's folder choice and the Notes window's frame (0019) live in
        // UserDefaults, which is per bundle id: any data dir but the real one
        // must not overwrite the real app's.
        defaults = PanelDefaults.defaults(forDataDir: dataDir)
        notesModel = NotesViewModel(core: core, defaults: defaults)
        notes = NotesPanelController(model: notesModel)
        notesWindowModel = NotesWindowModel(core: core)
        notesWindow = NotesWindowController(model: notesWindowModel, defaults: defaults)
```
3. old `                openNotes: { [weak self] in self?.openNotes(highlighting: nil) },` → new
```swift
                openNotes: { [weak self] in self?.openNotes(highlighting: nil) },
                openNotesWindow: { [weak self] in self?.openNotesWindow() },
```
4. old `        notesModel.onEnableNotifications = { [weak self] in Task { await self?.turnOnNotifications() } }` → new
```swift
        notesModel.onEnableNotifications = { [weak self] in Task { await self?.turnOnNotifications() } }
        notesModel.onExpand = { [weak self] in self?.expandNotesPanel() }
        notesWindow.onPresenceChange = { [weak self] open in self?.updateActivationPolicy(notesWindowOpen: open) }
```
5. old
```swift
            guard let self, self.notes.isOpen else { return }
            Task { await self.notesModel.reload() }
```
new
```swift
            guard let self else { return }
            if notes.isOpen { Task { await notesModel.reload() } }
            if notesWindow.isOpen { Task { await notesWindowModel.reload() } }
```
6. old
```swift
        if notes.isOpen {
            await notesModel.reload()
        }
```
new
```swift
        if notes.isOpen {
            await notesModel.reload()
        }
        if notesWindow.isOpen {
            await notesWindowModel.reload()
        }
```
7. old
```swift
        case let .application(bundleID):
            log.record("app_reopen", ["sender": bundleID])
            openNotes(highlighting: nil)
```
new
```swift
        case let .application(bundleID):
            log.record("app_reopen", ["sender": bundleID])
            if notesWindow.isOpen {
                openNotesWindow()  // the Dock icon: bring the window back, minimised or not
            } else {
                openNotes(highlighting: nil)
            }
```
8. old
```swift
    func openSettings() {
        settings.show()
    }
```
new
```swift
    func openSettings() {
        settings.show()
    }

    // MARK: Notes window (0019)

    /// The status menu's and the Window menu's "Notes Window", the Dock icon.
    func openNotesWindow() {
        notesWindow.show()
    }

    /// The panel's expand button: the panel closes and the window opens on the
    /// panel's scope, with the panel's expanded note selected.
    private func expandNotesPanel() {
        let selection = NotesWindowSelection.scope(notesModel.scope)
        let noteID = notesModel.expandedID
        notes.close()
        notesWindow.show(selection: selection, noteID: noteID)
        log.record("notes_window_opened", ["from": "panel"])
    }

    /// Rallo is a Dock app only while the Notes window is open (0019 §11);
    /// Settings and the panel never change the policy.
    private func updateActivationPolicy(notesWindowOpen: Bool) {
        let wanted: NSApplication.ActivationPolicy = notesWindowOpen ? .regular : .accessory
        guard wanted != NSApp.activationPolicy() else { return }
        NSApp.setActivationPolicy(wanted)
        log.record("activation_policy", ["policy": wanted == .regular ? "regular" : "accessory"])
        // Dropping to .accessory can leave Settings or the panel showing in an inactive app.
        if wanted == .accessory, settings.isOpen || notes.isOpen {
            NSApp.activate()
            if settings.isOpen { settings.bringForward() } else { notes.window?.makeKeyAndOrderFront(nil) }
        }
    }

    /// ⌘N, ⇧⌘N and ⌘F act only while the window is key and its New Folder card is not up.
    var notesWindowAcceptsCommands: Bool { notesWindow.isKey && notesWindowModel.namePrompter.request == nil }
    var notesWindowCanCreateNote: Bool { notesWindowAcceptsCommands && notesWindowModel.canCreateNote }
    var notesWindowHasUnsavedText: Bool { notesWindowModel.editor.hasUnsavedText }
    func newNoteInNotesWindow() { Task { await notesWindowModel.beginNewNote() } }
    func newFolderInNotesWindow() { Task { await notesWindowModel.newFolderInline() } }
    func focusNotesWindowSearch() { notesWindow.focusSearch() }

    /// ⌘Q: end any input-method composition first, so the committed text is what saves.
    func flushNotesWindow() async {
        notesWindow.nsWindow?.makeFirstResponder(nil)
        await notesWindowModel.editor.flush()
    }
```
9. old `            case "notes": openNotes(highlighting: nil)` → new
```swift
            case "notes": openNotes(highlighting: nil)
            case "window": openNotesWindow()
```
10. old `        let report = WindowReport.make(pet: pet, notesWindow: notes.window)` → new `        let report = WindowReport.make(pet: pet, notesWindow: notes.window, notesAppWindow: notesWindow.nsWindow)`

`apps/macos/Rallo/App/AppDelegate.swift`, Edits:

1. old
```swift
    /// token field in Settings). This main menu is never visible; it only carries the
    /// standard Edit key equivalents.
```
new
```swift
    /// token field in Settings). It is visible only while the Notes window is open
    /// (Rallo is then a Dock app, 0019); otherwise it carries the standard Edit key
    /// equivalents and the Notes window's File and Window items.
```
2. old
```swift
        let settings = app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
```
new
```swift
        let settings = app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Rallo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
```
3. old
```swift
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        return main
```
new
```swift
        let file = NSMenu(title: "File")
        let noteItem = file.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "n")
        noteItem.target = self
        let folderItem = file.addItem(withTitle: "New Folder", action: #selector(newFolder), keyEquivalent: "N")
        folderItem.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let notesWindowItem = windowMenu.addItem(withTitle: "Notes Window", action: #selector(openNotesWindow), keyEquivalent: "")
        notesWindowItem.target = self
        // No NSApp.windowsMenu: AppKit would list window titles and the Settings tab title, and drop
        // "Notes Window" while the window is closed (0019 §11 pins this menu's items).
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(fileItem)
        main.addItem(editItem)
        main.addItem(windowItem)
        return main
```
4. old `    @objc private func openSettings() { coordinator?.openSettings() }` → new
```swift
    @objc private func openSettings() { coordinator?.openSettings() }
    @objc private func newNote() { coordinator?.newNoteInNotesWindow() }
    @objc private func newFolder() { coordinator?.newFolderInNotesWindow() }
    @objc private func openNotesWindow() { coordinator?.openNotesWindow() }
    @objc private func find() { coordinator?.focusNotesWindowSearch() }

    /// ⌘N, ⇧⌘N and ⌘F belong to the Notes window: they are dimmed (and do
    /// nothing) anywhere else, so they never fire from the panel or Settings,
    /// nor behind the window's New Folder card.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newNote) { return coordinator?.notesWindowCanCreateNote ?? false }
        if menuItem.action == #selector(newFolder) || menuItem.action == #selector(find) {
            return coordinator?.notesWindowAcceptsCommands ?? false
        }
        return true
    }
```
5. old `    func applicationWillTerminate(_ notification: Notification) {` → new
```swift
    /// Quitting saves what's being typed in the Notes window first (0019 §11).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.notesWindowHasUnsavedText else { return .terminateNow }
        Task { @MainActor in
            await coordinator.flushNotesWindow()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
```
6. Make `AppDelegate` a menu validator: old `final class AppDelegate: NSObject, NSApplicationDelegate {` → new `final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {`.
7. ⌘F (the main menu is AppKit, so `.searchable` gets no Find command on its own): in `editMenu()`, old `        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")` → new
```swift
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: "Find", action: #selector(find), keyEquivalent: "f")
        findItem.target = self
```

- [ ] **Step 3: Build and run the whole Swift suite**

Run `cd /Users/eyakub/Desktop/Rallo && scripts/build-macos.sh` then the **Swift test command** with `-only-testing:RalloTests` (no class: all tests).
Expected: build succeeds (`built: …/Rallo.app`); all tests pass.

- [ ] **Step 4: Click-through check, Light and Dark**

Follow **Scratch run** (seed, then launch with `--demo-open window`). Verify each, ticking only what you saw:
- The window appears 1140×690, centred, titled "Notes" (hidden title; Mission Control and the Window report name it "Notes", the panel stays "Rallo Notes"), three columns showing the temporary Sidebar/List/Editor texts and the sidebar toggle; dragging it below 900×560 stops at the minimum; move and resize it, quit and relaunch: it comes back where you left it, and `defaults read com.razlio.rallo.scratch RalloNotesWindow` prints the frame (the installed app's `com.razlio.rallo` domain gets nothing).
- The Dock shows a Rallo icon and the menu bar shows **Rallo, File, Edit, Window** while it is open; `grep activation_policy "$RALLO_DATA_DIR/diagnostics/events.jsonl" | tail -3` shows `regular`. If the menu bar stays blank on the first open, change `show()` to follow the policy switch with `DispatchQueue.main.async { NSApp.activate(); window.makeKeyAndOrderFront(nil) }` and check again.
- File reads **New Note** ⌘N, **New Folder** ⇧⌘N, **Close** ⌘W; Edit ends with **Find** ⌘F; Window reads **Minimize** ⌘M and **Notes Window**, nothing else (no window titles, no Settings tab name). ⌘N, ⇧⌘N and ⌘F are dimmed while Settings or the panel is key.
- ⌘W closes it: the Dock icon goes, the menu bar menus go, the log shows `accessory`. The paw menu's **Notes Window** (under **Open Notes…**) reopens it. The red button does the same as ⌘W; Minimize keeps the Dock icon, and clicking the Dock icon brings the minimised window back (the log shows `app_reopen`).
- Open Settings (⌘,) with the window open, then close the window with ⌘W: Settings stays on screen and key, the Dock icon is gone. Repeat with the notes panel (⌃⌥⌘N) in place of Settings.
- With the window open, ⌃⌥⌘N and a pet click still toggle the panel; the panel's new expand button (top right, tooltip "Open Notes Window") closes the panel and brings the window forward. Inspect its position against the panda: nudge `.padding(.top, …)`/`.padding(.trailing, …)` so it clears the panda's ears and the title bar's buttons.
- ⌘Q with the window open quits cleanly. The status-menu **Quit Rallo** does too.
- Screenshot the window and the panel with its expand button in **Light and Dark**: `private/docs/folders-3-shots/t9-window-{light,dark}.png`, `t9-panel-{light,dark}.png`.
Run the **Cleanup** from the Scratch run section afterwards.

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/NotesWindowController.swift apps/macos/Rallo/NotesWindow/NotesWindowView.swift apps/macos/Rallo/App/AppDelegate.swift apps/macos/Rallo/App/AppCoordinator.swift apps/macos/Rallo/App/StatusMenuController.swift apps/macos/Rallo/Settings/SettingsWindowController.swift apps/macos/Rallo/Notes/NotesView.swift apps/macos/Rallo/Notes/NotesViewModel.swift apps/macos/Rallo/Diagnostics/WindowReport.swift
git commit -m "feat(app): notes window shell, Dock presence and the panel's expand button"
```

---

### Task 10: The sidebar and the delete-folder sheet

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/FolderDeleteCopy.swift`
- Create: `apps/macos/RalloTests/FolderDeleteCopyTests.swift`
- Create: `apps/macos/Rallo/NotesWindow/FolderSidebar.swift`
- Create: `apps/macos/Rallo/NotesWindow/DeleteFolderSheet.swift`
- Modify: `apps/macos/Rallo/NotesWindow/NotesWindowView.swift`
- Modify: `apps/macos/project.yml` (test sources)

**Interfaces:**
- Consumes: `NotesWindowModel` (Task 8: `overview`, `folders`, `tags`, `selection`, `select`, `newFolderInline`, `renameFolder`, `requestDelete` (synchronous), `confirmDelete`, `pendingFolderDelete`, `renamingFolderID`, `canDrop`, `drop`), `PendingFolderDelete` (`noteCount` is the folder's `noteCount`, open + done).
- Produces: `FolderDeleteCopy(folderName:noteCount:) { title, message, holdsNotes }`; `FolderSidebar(model:)`; `DeleteFolderSheet(pending:model:)`.

- [ ] **Step 1: Write the failing copy tests**

Create `apps/macos/RalloTests/FolderDeleteCopyTests.swift`:

```swift
import XCTest

/// §12's words, exactly. Review focus 4: the count the sheet is given is
/// open + done notes, so a folder of only finished notes still says it holds them.
final class FolderDeleteCopyTests: XCTestCase {
    func testAFolderWithNotes() {
        let copy = FolderDeleteCopy(folderName: "Work", noteCount: 5)
        XCTAssertEqual(copy.title, "Delete “Work”?")
        XCTAssertEqual(
            copy.message,
            "It holds 5 notes. Keep them in Notes, or delete them too? Deleted notes stay in Deleted, where you can restore them.")
        XCTAssertTrue(copy.holdsNotes)
    }

    func testAFolderWithOneNote() {
        let copy = FolderDeleteCopy(folderName: "Work", noteCount: 1)
        XCTAssertEqual(
            copy.message,
            "It holds 1 note. Keep it in Notes, or delete it too? Deleted notes stay in Deleted, where you can restore them.")
        XCTAssertTrue(copy.holdsNotes)
    }

    func testAnEmptyFolder() {
        let copy = FolderDeleteCopy(folderName: "Ideas", noteCount: 0)
        XCTAssertEqual(copy.title, "Delete “Ideas”?")
        XCTAssertEqual(copy.message, "The folder is empty.")
        XCTAssertFalse(copy.holdsNotes)
    }

    func testTheNameIsQuotedAsTheUserWroteIt() {
        XCTAssertEqual(FolderDeleteCopy(folderName: "কাজ", noteCount: 0).title, "Delete “কাজ”?")
    }
}
```

- [ ] **Step 2: Run to see the compile failure**

In `apps/macos/project.yml` after `      - path: Rallo/Notes/RalloError+Display.swift` add `      - path: Rallo/NotesWindow/FolderDeleteCopy.swift`. Run the **Swift test command** with `-only-testing:RalloTests/FolderDeleteCopyTests`.
Expected: FAIL (file missing).

- [ ] **Step 3: Write the copy, the sidebar and the sheet**

Create `apps/macos/Rallo/NotesWindow/FolderDeleteCopy.swift`:

```swift
import Foundation

/// The delete-folder sheet's words (0019 §12).
struct FolderDeleteCopy: Equatable {
    let title: String
    let message: String
    let holdsNotes: Bool

    init(folderName: String, noteCount: Int) {
        title = "Delete “\(folderName)”?"
        holdsNotes = noteCount > 0
        switch noteCount {
        case 0:
            message = "The folder is empty."
        case 1:
            message = "It holds 1 note. Keep it in Notes, or delete it too? Deleted notes stay in Deleted, where you can restore them."
        default:
            message = "It holds \(noteCount) notes. Keep them in Notes, or delete them too? Deleted notes stay in Deleted, where you can restore them."
        }
    }
}
```

Create `apps/macos/Rallo/NotesWindow/FolderSidebar.swift`:

```swift
import SwiftUI

/// The window's left column (0019 §11): Folders (Notes first, then
/// alphabetical, each a drop target for notes), Views, and Tags.
struct FolderSidebar: View {
    @ObservedObject var model: NotesWindowModel

    private var selection: Binding<NotesWindowSelection?> {
        Binding(
            get: { model.selection },
            set: { new in
                if let new { Task { await model.select(new) } }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                FolderRow(model: model, folder: nil, count: Int(model.overview?.unfiledOpen ?? 0))
                    .tag(NotesWindowSelection.scope(.unfiled))
                ForEach(model.folders, id: \.id) { folder in
                    FolderRow(model: model, folder: folder, count: Int(folder.openCount))
                        .tag(NotesWindowSelection.scope(.folder(folder.id)))
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        Task { await model.newFolderInline() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Folder")
                    .accessibilityLabel("New Folder")
                }
            }
            Section("Views") {
                SidebarLabel(symbol: "tray.full", title: "All Notes", count: Int(model.overview?.allOpen ?? 0))
                    .tag(NotesWindowSelection.scope(.all))
                SidebarLabel(symbol: "bell", title: "Due", count: Int(model.overview?.due ?? 0))
                    .tag(NotesWindowSelection.due)
                SidebarLabel(symbol: "checkmark.circle", title: "Done", count: Int(model.overview?.done ?? 0))
                    .tag(NotesWindowSelection.done)
                SidebarLabel(symbol: "trash", title: "Deleted", count: Int(model.overview?.deleted ?? 0))
                    .tag(NotesWindowSelection.deleted)
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.name) { tag in
                        SidebarLabel(hash: tag.name, count: Int(tag.openCount))
                            .tag(NotesWindowSelection.tag(tag.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var footer: some View {
        Button {
            Task { await model.newFolderInline() }
        } label: {
            Label("New Folder", systemImage: "plus.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.bark)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .help("New Folder (⇧⌘N)")
    }
}

/// One Views or Tags row: icon (or `#`), name, open count.
private struct SidebarLabel: View {
    var symbol: String?
    var hash: String?
    let title: String
    let count: Int

    init(symbol: String, title: String, count: Int) {
        self.symbol = symbol
        hash = nil
        self.title = title
        self.count = count
    }

    init(hash name: String, count: Int) {
        symbol = nil
        hash = name
        title = name
        self.count = count
    }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(Theme.rust).frame(width: 18)
            } else {
                Text("#").fontWeight(.bold).foregroundStyle(Theme.rust).frame(width: 18)
            }
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.bark)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Notes (`folder == nil`) or a folder. Rename is inline; a note dropped on
/// the row is filed in the folder.
private struct FolderRow: View {
    @ObservedObject var model: NotesWindowModel
    let folder: FolderSnapshot?
    let count: Int
    @State private var targeted = false
    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    private var renaming: Bool { folder != nil && model.renamingFolderID == folder?.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(Theme.rust).frame(width: 18)
            if renaming, let folder {
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { Task { await model.renameFolder(folder, to: name) } }
                    .onExitCommand {
                        model.renamingFolderID = nil
                        model.errorMessage = nil
                    }
                    .onAppear {
                        name = folder.name
                        fieldFocused = true
                    }
                    // Select the name once the field really has focus (selecting from
                    // onAppear races the focus change and can land nowhere).
                    .onChange(of: fieldFocused) { _, focused in
                        if focused { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    }
                    .accessibilityLabel("Folder name")
            } else {
                Text(folder?.name ?? "Notes").lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.bark)
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(targeted ? Theme.highlight : .clear))
        .dropDestination(for: String.self) { ids, _ in
            guard model.canDrop(ids) else { return false }  // an unknown id is ignored
            Task { await model.drop(ids, onto: folder?.id) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            if let folder {
                Button("Rename") { model.renamingFolderID = folder.id }
                Divider()
                Button("Delete Folder…", role: .destructive) { model.requestDelete(folder) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
```

Create `apps/macos/Rallo/NotesWindow/DeleteFolderSheet.swift`:

```swift
import SwiftUI

/// §12's sheet. Keep Notes is the default; deleting notes is the destructive choice.
struct DeleteFolderSheet: View {
    let pending: PendingFolderDelete
    @ObservedObject var model: NotesWindowModel

    private var copy: FolderDeleteCopy {
        FolderDeleteCopy(folderName: pending.folder.name, noteCount: pending.noteCount)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.rust)
                .accessibilityHidden(true)
            Text(copy.title)
                .font(Theme.rounded(16, .semibold))
            Text(copy.message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.bark)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                if copy.holdsNotes {
                    Button { confirm(keepNotes: true) } label: { wide("Keep Notes") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button(role: .destructive) { confirm(keepNotes: false) } label: { wide("Delete Notes") }
                        .buttonStyle(.bordered)
                } else {
                    // Nothing to keep or delete; Keep Notes is the harmless flag for the core.
                    Button(role: .destructive) { confirm(keepNotes: true) } label: { wide("Delete") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Button { model.pendingFolderDelete = nil } label: { wide("Cancel") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 340)
        .tint(Theme.rust)
    }

    private func wide(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity)
    }

    private func confirm(keepNotes: Bool) {
        Task { await model.confirmDelete(pending, keepNotes: keepNotes) }
    }
}
```

In `apps/macos/Rallo/NotesWindow/NotesWindowView.swift` make two Edits. Old

```swift
            Text("Sidebar")  // replaced in Task 10
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
```

new

```swift
            FolderSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
```

and old `        .onChange(of: model.query) { _, _ in model.queryChanged() }` new

```swift
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .sheet(item: $model.pendingFolderDelete) { pending in
            DeleteFolderSheet(pending: pending, model: model)
        }
```

- [ ] **Step 4: Run the copy tests and the model tests**

Run the **Swift test command** with `-only-testing:RalloTests/FolderDeleteCopyTests`, then `-only-testing:RalloTests/NotesWindowModelTests`.
Expected: both pass.

- [ ] **Step 5: Build, click through, screenshot**

Run `scripts/build-macos.sh`, then **Scratch run**. Verify:
- Sidebar sections: **Folders** (header with a `+`), **Notes** first then **Ideas**, **Work** alphabetical, each with its open count (Work 2, Ideas 0, Notes 2); **Views**: All Notes 4, Due, Done, Deleted with counts; **Tags**: `# bug`, `# release`, `# كلمة` with counts (the Bangla/Arabic-script tag renders right-to-left inside its own row without breaking the count column). Selecting any row highlights it (the columns to the right are still the temporary texts).
- `+` in the header, the footer "New Folder" and ⇧⌘N each create **New Folder** (then **New Folder 2**, …), select it, and start an inline rename with the name selected. Typing a name and Return renames it (the list re-sorts alphabetically); Esc cancels; clicking elsewhere leaves it **New Folder**. Rename to an existing name (any case): the core's own message shows in the banner at the top of the window and the field stays editable (one refusal is enough; `testARefusedRenameStaysInTheFieldWithTheCoresReason` covers the rest); renaming `work` to `Work` is accepted.
- Right-click a folder: **Rename** (inline) and **Delete Folder…** only; Notes has no menu.
- Delete Folder… on **Work** (2 open notes; also mark one done with `"$CLI" done <id>` first so it holds 1 open + 1 done): the sheet reads **Delete “Work”?** / "It holds 2 notes. Keep them in Notes, or delete them too? Deleted notes stay in Deleted, where you can restore them." with **Keep Notes** (highlighted, Return), **Delete Notes** (red text) and **Cancel** (Esc). Cancel changes nothing. Keep Notes: Work disappears, the notes' count moves to Notes, the toast does not appear yet (Task 11), the selection falls to Notes if Work was selected. Repeat with a folder holding **only a done note**: it must say "It holds 1 note." (review focus 4). Delete Notes on a third folder: Deleted's count rises by its notes. An empty folder shows **Delete “Ideas”?** / "The folder is empty." with **Delete** / **Cancel**.
- `"$CLI" folder delete Ideas` from a terminal while Ideas is selected: within a second the selection falls to Notes (review focus 5).
- Screenshots in Light and Dark: the sidebar, the sheet with notes, the empty-folder sheet: `private/docs/folders-3-shots/t10-*.png`.
Run the **Cleanup**.

- [ ] **Step 6: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/FolderDeleteCopy.swift apps/macos/Rallo/NotesWindow/FolderSidebar.swift apps/macos/Rallo/NotesWindow/DeleteFolderSheet.swift apps/macos/Rallo/NotesWindow/NotesWindowView.swift apps/macos/RalloTests/FolderDeleteCopyTests.swift apps/macos/project.yml
git commit -m "feat(app): notes window sidebar, inline folder rename and the delete-folder sheet"
```

---

### Task 11: The list column, search, and the Undo toast

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/NoteListColumn.swift`
- Create: `apps/macos/Rallo/NotesWindow/FolderPrompts.swift`
- Modify: `apps/macos/Rallo/Notes/NotesView.swift` (`ToastBar` shared with the window)
- Create: `apps/macos/Rallo/Notes/RemindMenuItems.swift`
- Modify: `apps/macos/Rallo/Notes/NoteRow.swift` (use `RemindMenuItems`)
- Modify: `apps/macos/Rallo/Notes/Thumbnails.swift` (`ThumbnailCache.image(for:points:)`)
- Modify: `apps/macos/Rallo/Notes/FolderNameOverlay.swift` (`.folderNamePrompt(_:)`, Esc on the card)
- Modify: `apps/macos/Rallo/NotesWindow/NotesWindowView.swift`

**Interfaces:**
- Consumes: `NotesWindowModel` (Task 8: `header`, `visibleItems`, `doneItems`, `open`/`done`/`found` (`totalCount`, `hasMore`, `items`), `loadMore(done:)`, `doneExpanded`, `listIsGrouped`, `groupTimestamp`, `selectedNoteID`, `selectedItem`, `isDrafting`, `isSearching`, `canCreateNote`, `selectNote`, `toggleDone`, `delete`, `restore`, `remind`, `move`, `beginNewNote`, `undo`, `toast`, `folders`, `namePrompter`), `DateGrouping`, `RowTimeLabel`, `RowText` (Tasks 3 and 6), `FolderMoveMenu`, `FolderNamePrompter` and `FolderNameOverlay` (release 2), `NotesWindowModel.core`, `CompletionButton` (existing, `NoteRow.swift`), `ReminderSnapshot.deadline` (release 2, `RemindPreset.swift`), `ReminderLabel`, `ThumbnailCache`.
- Produces: `NoteListColumn(model:)`; `ToastBar(message:undoable:undoShortcut:undo:)` (the panel's, made shared); `RemindMenuItems(onPreset:onCustom:)` (the Remind Me choices, shared with the panel row); `WindowFolderPrompt.newFolder(for:model:)`; `View.folderNamePrompt(_ prompter: FolderNamePrompter)`; `ThumbnailCache.shared.image(for: String, points: CGFloat)`.

- [ ] **Step 1: Share the Remind Me menu and decode thumbnails at any size**

Create `apps/macos/Rallo/Notes/RemindMenuItems.swift`:

```swift
import SwiftUI

/// The Remind Me choices (0016), shared by the panel's rows and the notes
/// window: 20 minutes, 1 hour, tomorrow at 9:00, then Custom….
struct RemindMenuItems: View {
    let onPreset: (RemindPreset) -> Void
    let onCustom: () -> Void

    var body: some View {
        ForEach(RemindPreset.allCases) { preset in
            Button(preset.title) { onPreset(preset) }
        }
        Divider()
        Button("Custom…", action: onCustom)
    }
}
```

In `apps/macos/Rallo/Notes/NoteRow.swift`, Edit: old

```swift
    @ViewBuilder
    private var remindButtons: some View {
        ForEach(RemindPreset.allCases) { preset in
            Button(preset.title) { Task { await model.remind(item, preset) } }
        }
        Divider()
        Button("Custom…") { model.customRemindID = item.id }
    }
```

new

```swift
    private var remindButtons: some View {
        RemindMenuItems(
            onPreset: { preset in Task { await model.remind(item, preset) } },
            onCustom: { model.customRemindID = item.id }
        )
    }
```

In `apps/macos/Rallo/Notes/Thumbnails.swift`, Edit: old

```swift
    func image(for path: String) async -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            if FileManager.default.fileExists(atPath: path) { return cached }
            cache.removeObject(forKey: path as NSString)  // deleted behind our back
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let points = Self.points
        let made = await Task.detached(priority: .userInitiated) { Thumbnails.image(url: url, points: points) }.value
        if let made { cache.setObject(made, forKey: path as NSString) }
        return made
    }
```

new

```swift
    func image(for path: String, points: CGFloat? = nil) async -> NSImage? {
        let points = points ?? Self.points
        let key = "\(path)@\(Int(points))" as NSString
        if let cached = cache.object(forKey: key) {
            if FileManager.default.fileExists(atPath: path) { return cached }
            cache.removeObject(forKey: key)  // deleted behind our back
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let made = await Task.detached(priority: .userInitiated) { Thumbnails.image(url: url, points: points) }.value
        if let made { cache.setObject(made, forKey: key) }
        return made
    }
```

- [ ] **Step 2: Share the panel's toast bar, and write the New Folder… glue**

In `apps/macos/Rallo/Notes/NotesView.swift` (Task 1 Step 2 checked `ToastBar` is still release 0.12's), two Edits. Old

```swift
private struct ToastBar: View {
    let toast: Toast
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if toast.undo != nil {
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(Theme.toastAccent)
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
```

new

```swift
/// A transient message with an optional Undo, at the bottom of the panel and
/// of the notes window's list (0019 §11).
struct ToastBar: View {
    let message: String
    let undoable: Bool
    /// ⌘Z presses Undo in the panel; in the notes window ⌘Z belongs to the text.
    var undoShortcut = true
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if undoable {
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(Theme.toastAccent)
                    .keyboardShortcut(undoShortcut ? KeyboardShortcut("z", modifiers: .command) : nil)
            }
        }
```

and old `                ToastBar(toast: toast) { Task { await model.undo() } }` new `                ToastBar(message: toast.message, undoable: toast.undo != nil) { Task { await model.undo() } }`.

Create `apps/macos/Rallo/NotesWindow/FolderPrompts.swift`:

```swift
import Foundation

/// "New Folder…" in a note's Move menu (§10): the window's `FolderNamePrompter`
/// card, whose `validate` is the real create call, so the core's own message
/// shows under the field and the card stays up until the folder exists or the
/// user cancels. Then the note moves into it.
@MainActor
enum WindowFolderPrompt {
    static func newFolder(for item: ItemSnapshot, model: NotesWindowModel) async {
        var created: FolderSnapshot?
        _ = await model.namePrompter.ask(title: "New Folder", initial: "", confirmTitle: "Create") { [core = model.core] name in
            created = try await core.createFolder(name)
        }
        guard let folder = created else { return }
        await model.reload()  // the toast names the folder: the overview must know it
        await model.move(item, toFolder: folder.id)
    }
}
```

Make the card self-contained for a host that isn't the panel. In `apps/macos/Rallo/Notes/FolderNameOverlay.swift`, two Edits.

1. Esc cancels from the card itself (the panel also routes Esc through its model; a second `cancel()` is a no-op). Old
```swift
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(request.title)
```
new
```swift
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(request.title)
        .onExitCommand { prompter.cancel() }
```
2. Append at the end of the file:
```swift
extension View {
    /// Draws `prompter`'s card over this view (0019 §10). While it shows, the
    /// view behind is blurred, disabled and hidden from VoiceOver, so nothing
    /// there (an Undo toast, a toolbar button) reacts; when it goes, the
    /// keyboard returns to whatever had it. The panel wires the same fence
    /// itself, because its scope dropdown shares it.
    func folderNamePrompt(_ prompter: FolderNamePrompter) -> some View {
        modifier(FolderNamePromptModifier(prompter: prompter))
    }
}

private struct FolderNamePromptModifier: ViewModifier {
    @ObservedObject var prompter: FolderNamePrompter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The first responder when the card appeared (the list, the text view, …).
    @State private var returnFocus: WeakResponder?

    func body(content: Content) -> some View {
        let shown = prompter.request != nil
        content
            .disabled(shown)
            .accessibilityHidden(shown)
            .blur(radius: shown ? 4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: shown)
            .overlay { FolderNameOverlay(prompter: prompter) }
            .onChange(of: shown) { _, isShown in
                if isShown {
                    returnFocus = NSApp.keyWindow.map { WeakResponder(window: $0, responder: $0.firstResponder) }
                } else if let saved = returnFocus {
                    returnFocus = nil
                    if let window = saved.window, let responder = saved.responder { window.makeFirstResponder(responder) }
                }
            }
    }
}

private struct WeakResponder {
    weak var window: NSWindow?
    weak var responder: NSResponder?
}
```
(`FolderNameOverlay.swift` imports only SwiftUI, which brings AppKit on macOS; add `import AppKit` if the compiler disagrees.)

- [ ] **Step 3: Write the list column**

Create `apps/macos/Rallo/NotesWindow/NoteListColumn.swift`:

```swift
import AppKit
import SwiftUI

/// The middle column (0019 §11): the scope's name and counts, notes grouped by
/// date, a collapsed "N done" row, the Undo toast, and the Delete and New Note
/// toolbar buttons. ⌘N lives in the File menu, ⌫ and the arrow keys here.
struct NoteListColumn: View {
    @ObservedObject var model: NotesWindowModel
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasDoneRow: Bool { !model.isSearching && model.done.totalCount > 0 }

    private var isEmpty: Bool { model.visibleItems.isEmpty && !model.isDrafting && !hasDoneRow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isEmpty { emptyState } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastBar(message: toast.message, undoable: toast.undo != nil, undoShortcut: false) { Task { await model.undo() } }
                    .id(toast.id)
                    .padding(12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.toast?.id)
        .toolbar { toolbar }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.header.title)
                .font(Theme.rounded(20, .bold))
                .lineLimit(1)
            Text(model.header.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bark)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        let text: String = if model.isSearching {
            "No results"
        } else {
            switch model.selection {
            case .deleted: "Nothing deleted"
            case .done: "Nothing done yet"
            case .due: "No reminders waiting"
            default: "No notes here yet"
            }
        }
        return Text(text)
            .font(Theme.rounded(14, .medium))
            .foregroundStyle(Theme.bark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sections: [DateSection<ItemSnapshot>] {
        DateGrouping.sections(model.visibleItems, timestampMs: model.groupTimestamp, now: .now, calendar: .current)
    }

    /// The rows in the order they are drawn, for the arrow keys.
    private var order: [ItemSnapshot] {
        model.visibleItems + (model.doneExpanded && hasDoneRow ? model.doneItems : [])
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.isDrafting { DraftRow() }
                if model.listIsGrouped {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(Theme.rounded(11.5, .bold))
                            .foregroundStyle(Theme.bark)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.elements, id: \.id) { row($0, dimmed: false) }
                    }
                } else {
                    ForEach(model.visibleItems, id: \.id) { row($0, dimmed: false) }
                }
                if hasDoneRow {
                    doneRow
                    if model.doneExpanded {
                        ForEach(model.doneItems, id: \.id) { row($0, dimmed: true) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, model.toast == nil ? 8 : 64)
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.delete) { deleteSelected() }
        .onKeyPress(.deleteForward) { deleteSelected() }
    }

    private func row(_ item: ItemSnapshot, dimmed: Bool) -> some View {
        NoteListRow(
            item: item, selected: !model.isDrafting && model.selectedNoteID == item.id, dimmed: dimmed, model: model
        )
        .onTapGesture {
            listFocused = true
            Task { await model.selectNote(item.id) }
        }
        .onAppear {
            // The last loaded row came into view: the next page (0019 §9).
            let list = dimmed ? model.done : (model.isSearching ? model.found : model.open)
            if item.id == list.items.last?.id, list.hasMore { Task { await model.loadMore(done: dimmed) } }
        }
    }

    /// "N done": collapsed by default; expanding shows the scope's finished notes, dimmed.
    private var doneRow: some View {
        Button {
            model.doneExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(model.doneExpanded ? 90 : 0))
                Text("\(model.done.totalCount) done")
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.bark)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .padding(.top, 10)
        .padding(.horizontal, 6)
        .accessibilityLabel("\(model.done.totalCount) done")
        .accessibilityValue(model.doneExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the finished notes")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if case .deleted = model.selection {
                Button {
                    if let item = model.selectedItem { Task { await model.restore(item) } }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .disabled(model.selectedItem == nil)
                .help("Restore")
            } else {
                Button {
                    if let item = model.selectedItem { Task { await model.delete(item) } }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(model.selectedItem == nil)
                .help("Delete")
            }
            Button {
                Task { await model.beginNewNote() }
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .disabled(!model.canCreateNote)
            .help("New Note (⌘N)")
        }
    }

    // MARK: Keys

    private func step(_ delta: Int) -> KeyPress.Result {
        let ids = order.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = model.selectedNoteID.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        Task { await model.selectNote(ids[next]) }
        return .handled
    }

    /// ⌫ in the list deletes the selected note; Deleted offers Restore, no delete.
    private func deleteSelected() -> KeyPress.Result {
        if case .deleted = model.selection { return .ignored }
        guard let item = model.selectedItem else { return .ignored }
        Task { await model.delete(item) }
        return .handled
    }
}

/// The "New Note" row at the top while a draft is open.
private struct DraftRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Theme.rust)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("New Note").font(.system(size: 13.5, weight: .semibold))
                Text("Start typing…").font(.system(size: 12)).foregroundStyle(Theme.bark)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.highlight))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Note, not saved yet")
    }
}

/// One note in the list: completion circle, title, then the time (or the
/// reminder) and a body preview, with the first image as a 38 pt thumbnail.
private struct NoteListRow: View {
    let item: ItemSnapshot
    let selected: Bool
    let dimmed: Bool
    @ObservedObject var model: NotesWindowModel
    @State private var hovering = false

    private var text: RowText { RowText(item.text) }
    private var isDone: Bool { item.status == .done }
    private var isDeleted: Bool { item.deletedAtMs != nil }
    private var date: Date { Date(timeIntervalSince1970: TimeInterval(model.groupTimestamp(item)) / 1000) }

    private var activeReminder: ReminderSnapshot? {
        guard let reminder = item.reminder, reminder.state == .active else { return nil }
        return reminder
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(text.displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(text.title.isEmpty ? Theme.bark : Theme.ink)
                    .lineLimit(1)
                meta
            }
            Spacer(minLength: 0)
            if let image = item.images.first { ListThumbnail(path: image.path) }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.highlight : (hovering ? Theme.hover : .clear))
        )
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .draggable(item.id)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var leading: some View {
        if isDeleted {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Theme.bark)
                .frame(width: 26, height: 22)
                .accessibilityHidden(true)
        } else if isDone {
            Button {
                Task { await model.toggleDone(item) }
            } label: {
                ZStack {
                    Circle().fill(Theme.bamboo)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                }
                .frame(width: 18, height: 18)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reopen")
            .accessibilityLabel("Reopen “\(item.name)”")
        } else {
            CompletionButton(completing: false) { Task { await model.toggleDone(item) } }
                .accessibilityLabel("Mark “\(item.name)” as done")
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if let reminder = activeReminder {
                Image(systemName: "bell")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.rust)
                Text(Self.capitalized(ReminderLabel.text(for: reminder.deadline)))
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.rust)
            } else {
                Text(RowTimeLabel.text(for: date, now: .now, calendar: .current))
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.ink)
            }
            if !text.preview.isEmpty {
                Text(text.preview)
                    .foregroundStyle(Theme.bark)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
    }

    private static func capitalized(_ string: String) -> String {
        string.prefix(1).uppercased() + string.dropFirst()
    }

    @ViewBuilder
    private var menu: some View {
        if isDeleted {
            Button("Restore") { Task { await model.restore(item) } }
        } else {
            Button(isDone ? "Reopen" : "Mark as Done") { Task { await model.toggleDone(item) } }
            Menu("Remind Me") {
                RemindMenuItems(
                    onPreset: { preset in Task { await model.remind(item, preset) } },
                    onCustom: {
                        Task {
                            await model.selectNote(item.id)
                            model.customRemindOpen = true
                        }
                    }
                )
            }
            Menu("Move to") {
                FolderMoveMenu(
                    currentFolderID: item.folderId,
                    folders: model.folders,
                    onMove: { id in Task { await model.move(item, toFolder: id) } },
                    onNewFolder: { Task { await WindowFolderPrompt.newFolder(for: item, model: model) } }
                )
            }
            Divider()
            Button("Copy Text") { copy(item.text) }
            Button("Copy ID for the Terminal") { copy(item.id) }
            Divider()
            Button("Delete", role: .destructive) { Task { await model.delete(item) } }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// The first image, 38 pt on the right of a row.
private struct ListThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.bark)
            }
        }
        .frame(width: 38, height: 38)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: path) { image = await ThumbnailCache.shared.image(for: path, points: 38) }
        .accessibilityHidden(true)
    }
}
```

In `apps/macos/Rallo/NotesWindow/NotesWindowView.swift`, two Edits: old

```swift
            Text("List")  // replaced in Task 11
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
```

new

```swift
            NoteListColumn(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
```

and old `        .overlay(alignment: .top) { errorBanner }` new

```swift
        .overlay(alignment: .top) { errorBanner }
        .folderNamePrompt(model.namePrompter)
```

- [ ] **Step 4: Build and run the suite**

Run `scripts/build-macos.sh`, then the **Swift test command** with `-only-testing:RalloTests` (the `ThumbnailCache` and `NoteRow` edits touch the panel: `NotesWindowModelTests` and the rest must still pass).
Expected: build and all tests pass.

- [ ] **Step 5: Click through, Light and Dark**

Follow **Scratch run**, but first make the data interesting. With the app stopped, backdate a few notes and add an image, e.g.:

```bash
sqlite3 "$RALLO_DATA_DIR/rallo.sqlite3" "UPDATE items SET created_at_ms = created_at_ms - 86400000 WHERE text LIKE 'Call the dentist%'; UPDATE items SET created_at_ms = created_at_ms - 3*86400000 WHERE text LIKE 'Standup%'; UPDATE items SET created_at_ms = created_at_ms - 40*86400000 WHERE text LIKE 'Café%';"
"$CLI" note "Photo note" --image assets/pet/rallo/pet-idle@2x.png
"$CLI" remind "Send the weekly update" --in 1h
```

(The CLI may start a background app instance: stop it with the `pkill` line from Scratch run before launching; run the `sqlite3` line only while the app is stopped.) Then verify, ticking only what you saw (mark **Call the dentist** done with its circle first, so Done has a note):
- The list header reads the scope's name and `N open · M done`; selecting each sidebar row changes the list: a folder shows only its notes, **All Notes** all open notes, **Due** the reminder note (no date groups), **Done** the done note under a completion-date group, **Deleted** empty ("Nothing deleted"), a tag its tagged notes across folders (`#bug` shows two).
- Groups read **Today**, **Yesterday**, **Previous 7 Days**, and a month header for the 40-day-old note; the Today group has a time like `10:42`, the 3-day-old note its weekday, the reminder row a rust bell with "Today at …", the photo note a 38 pt thumbnail on the right. A note with a title shows the title on line one and the time + preview on line two.
- Click a row: it takes the highlight colour; ↑/↓ move the selection; ⌫ deletes the selected note and the toast "Deleted “…”" appears at the bottom with **Undo**, which brings it back (⌘Z does not press the window's Undo; the panel's toast still takes ⌘Z). The completion circle marks a note done (toast with Undo, and the row moves into the collapsed **N done** row); expanding that row shows the note dimmed, and its green check reopens it.
- Right-click a row: **Mark as Done**, **Remind Me** (20 minutes, 1 hour, tomorrow; "Custom…" is wired in Task 12), **Move to** (Notes, folders with the current one checked and disabled, New Folder…), Copy Text, Copy ID, Delete. **Move to → Work** shows the toast "Moved to Work" with **Undo** (moves it back); in a folder scope the moved row leaves the list. **New Folder…** opens the card over the whole window (blurred behind; nothing behind it clicks, toolbar and toast included; ⌘N/⇧⌘N/⌘F dimmed; Esc and Cancel close it and the keyboard goes back to the list), refuses a duplicate name with the core's reason under the field while staying up, then creates the folder and moves the note into it.
- In **Deleted**, a row's context menu offers **Restore** only, the toolbar shows **Restore** instead of the trash, and ⌫ does nothing.
- Drag a row onto **Work** in the sidebar: the folder row highlights, the note moves, the toast shows. Dragging onto **All Notes**, Views or Tags does nothing; dropping text from another app on a folder row is ignored.
- ⌘F (Edit → Find) focuses the toolbar search field, whose placeholder reads "Search all notes". If it does nothing, log `window.toolbar?.items` in `NotesWindowController.focusSearch()`: when SwiftUI built no `NSSearchToolbarItem`, find the `NSSearchField` in the toolbar items' views and `window.makeFirstResponder` it instead. Typing `plan` lists matches across all folders under **Results** (flat), including done notes; the New Note toolbar button is disabled; clearing the field returns to the scope. The empty states read "No results", "Nothing done yet", etc.
- `"$CLI" note "from the terminal"` while the window is open: the new note appears within a second without touching anything, and the counts in the sidebar update.
- Paging (0019 §9): stop the app, seed 250 more notes (`for i in $(seq 1 250); do "$CLI" note "Idea $i"; done`, then the `pkill` line), relaunch. **All Notes**' header and sidebar count both read the exact open total, over 250 (never `200+`, never the 100 that loaded); scroll to the bottom: the rest load as the last row appears, with no row twice. Select a note near the bottom, run `"$CLI" note "one more"`: the list reloads and the selection stays. Search `Idea` and scroll the results the same way; the header says the full count.
- Screenshots Light and Dark: the list with all groups, the Deleted view, the expanded done row, a context menu: `private/docs/folders-3-shots/t11-*.png`. Run the **Cleanup**.

- [ ] **Step 6: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/NoteListColumn.swift apps/macos/Rallo/NotesWindow/FolderPrompts.swift apps/macos/Rallo/NotesWindow/NotesWindowView.swift apps/macos/Rallo/Notes/NotesView.swift apps/macos/Rallo/Notes/RemindMenuItems.swift apps/macos/Rallo/Notes/NoteRow.swift apps/macos/Rallo/Notes/Thumbnails.swift apps/macos/Rallo/Notes/FolderNameOverlay.swift
git commit -m "feat(app): notes window list with date groups, search, drag to folders and Undo"
```

---

### Task 12: The editor: text, conflict bar, images, new notes

**Files:**
- Create: `apps/macos/Rallo/NotesWindow/NoteTextEditor.swift`
- Create: `apps/macos/Rallo/NotesWindow/NoteEditorColumn.swift`
- Modify: `apps/macos/Rallo/Shared/Theme.swift` (`inkNS`, `rustNS`: the `NSColor`s behind `ink`, `rust`)
- Modify: `apps/macos/Rallo/Notes/ImageStrip.swift` (callbacks and a tile size instead of the panel's model)
- Modify: `apps/macos/Rallo/NotesWindow/NotesWindowView.swift`

**Interfaces:**
- Consumes: `NoteEditorSession` (Task 7: `text`, `textChanged`, `isComposing`, `showCount`, `focusToken`, `isDraft`, `isEditable`, `note`, `conflict`, `error`), `NotesWindowModel` (`selectedItem`, `showTheirs()`, `keepMine()`, `removeImage`), `PlainTextView`, `NoteTextStyler`, `tagRanges(text:)` (Tasks 6 and 1), `ImageStrip`, `QuickLookPresenter`.
- Produces: `Theme.inkNS`, `Theme.rustNS`, `NSColor.dynamic(light:lightAlpha:dark:darkAlpha:)`; `NoteTextEditor(session:)`; `NoteEditorColumn(model:editor:)`; `ImageStrip(item:tile:onRemove:onFocusChange:)` plus the panel's `ImageStrip(item:model:)` convenience initializer (unchanged call sites).

- [ ] **Step 1: Let `ImageStrip` serve both the panel and the window**

Apply these Edits to `apps/macos/Rallo/Notes/ImageStrip.swift`:

1. old
```swift
struct ImageStrip: View {
    let item: ItemSnapshot
    @ObservedObject var model: NotesViewModel
    @FocusState private var focused: String?
```
new
```swift
struct ImageStrip: View {
    let item: ItemSnapshot
    /// 56 pt squares in the panel (`ThumbnailCache.points`), 210×140 tiles in the notes window (0019).
    var tile = CGSize(width: 56, height: 56)
    let onRemove: (ImageSnapshot) -> Void
    let onFocusChange: (Bool) -> Void
    @FocusState private var focused: String?
```
2. old `                    RowThumbnail(image: image, label: "Image \(index + 1) of \(item.images.count), \(Self.kind(image))")` new `                    RowThumbnail(image: image, label: "Image \(index + 1) of \(item.images.count), \(Self.kind(image))", size: tile)`
3. old `                            Button("Remove Image", role: .destructive) { Task { await model.removeImage(image, from: item) } }` new `                            Button("Remove Image", role: .destructive) { onRemove(image) }`
4. old `                        .accessibilityAction(named: "Remove Image") { Task { await model.removeImage(image, from: item) } }` new `                        .accessibilityAction(named: "Remove Image") { onRemove(image) }`
5. old
```swift
        .frame(height: ThumbnailCache.points)
        .background(GeometryReader { proxy in
```
new
```swift
        .frame(height: tile.height)
        .background(GeometryReader { proxy in
```
6. old
```swift
        .onChange(of: focused) { _, id in model.thumbnailFocused = id != nil }
        .onDisappear { model.thumbnailFocused = false }
```
new
```swift
        .onChange(of: focused) { _, id in onFocusChange(id != nil) }
        .onDisappear { onFocusChange(false) }
```
7. old
```swift
    private func remove(_ image: ImageSnapshot) -> KeyPress.Result {
        Task { await model.removeImage(image, from: item) }
        return .handled
    }
```
new
```swift
    private func remove(_ image: ImageSnapshot) -> KeyPress.Result {
        onRemove(image)
        return .handled
    }
```
8. old
```swift
private struct RowThumbnail: View {
    let image: ImageSnapshot
    let label: String
```
new
```swift
extension ImageStrip {
    /// The panel's strip: 56 pt tiles; removals and focus go to the panel's model.
    @MainActor
    init(item: ItemSnapshot, model: NotesViewModel) {
        self.init(
            item: item,
            onRemove: { image in Task { await model.removeImage(image, from: item) } },
            onFocusChange: { model.thumbnailFocused = $0 }
        )
    }
}

private struct RowThumbnail: View {
    let image: ImageSnapshot
    let label: String
    let size: CGSize
```
9. old
```swift
        .frame(width: ThumbnailCache.points, height: ThumbnailCache.points)
        .background(Theme.field)
```
new
```swift
        .frame(width: size.width, height: size.height)
        .background(Theme.field)
```
10. old `            thumbnail = await ThumbnailCache.shared.image(for: image.path)` new `            thumbnail = await ThumbnailCache.shared.image(for: image.path, points: max(size.width, size.height))`

- [ ] **Step 2: Expose the theme's AppKit colours, then write the text editor**

`Theme`'s colours are already dynamic `NSColor` providers wrapped in `Color`; the editor's attributes need the `NSColor` itself, which resolves in the text view's appearance whenever it draws (no appearance observer, no colour-space snapshot). In `apps/macos/Rallo/Shared/Theme.swift`, four Edits:

1. old
```swift
    // Paw ink / belly cream.
    static let ink = Color(light: 0x2B1A13, dark: 0xF5E8DC)
```
new
```swift
    // Paw ink / belly cream.
    static let inkNS = NSColor.dynamic(light: 0x2B1A13, dark: 0xF5E8DC)
    static let ink = Color(nsColor: inkNS)
```
2. old
```swift
    static let rust = Color(light: 0xB4501F, dark: 0xF08A4B)
```
new
```swift
    static let rustNS = NSColor.dynamic(light: 0xB4501F, dark: 0xF08A4B)
    static let rust = Color(nsColor: rustNS)
```
3. old
```swift
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
```
new
```swift
        self.init(nsColor: .dynamic(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
```
4. old
```swift
extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
```
new
```swift
extension NSColor {
    /// Resolves in the appearance it is drawn in (Light or Dark).
    static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
```

Create `apps/macos/Rallo/NotesWindow/NoteTextEditor.swift`:

```swift
import AppKit
import SwiftUI

/// The note's text in an `NSTextView` (0019 §11): plain text, paste drops
/// formatting, the `NoteParts` title in 24 pt semibold rounded and `#tags`
/// tinted, all by attributes (`NoteTextStyler`), never by replacing the
/// string. It sizes itself to its text so the date above and the images below
/// scroll with it in one `ScrollView`.
struct NoteTextEditor: NSViewRepresentable {
    @ObservedObject var session: NoteEditorSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> PlainTextView {
        let view = PlainTextView.make()
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Note text")
        view.insertionPointColor = Theme.rustNS
        return view
    }

    func updateNSView(_ view: PlainTextView, context: Context) {
        let coordinator = context.coordinator
        view.isEditable = session.isEditable
        coordinator.applying = true
        defer { coordinator.applying = false }
        // Never replace the string while an input method is composing.
        if !view.hasMarkedText(), view.string != session.text {
            let kept = view.selectedRange()
            view.string = session.text
            view.undoManager?.removeAllActions()  // undo across a programmatic replace would hit stale ranges
            view.setSelectedRange(NSRange(location: min(kept.location, (session.text as NSString).length), length: 0))
        }
        if coordinator.shown != session.showCount {  // another note: no undo across notes, caret at the start
            coordinator.shown = session.showCount
            view.undoManager?.removeAllActions()
            let end = (session.text as NSString).length
            view.setSelectedRange(NSRange(location: session.isDraft ? end : 0, length: 0))
        }
        coordinator.restyle(view)
        if coordinator.focusToken != session.focusToken {
            coordinator.focusToken = session.focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlainTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 480, 80)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: max(ceil(used.height) + nsView.textContainerInset.height * 2, 200))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: NoteEditorSession
        var applying = false
        var shown = -1
        var focusToken = 0

        init(session: NoteEditorSession) {
            self.session = session
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? PlainTextView else { return }
            session.isComposing = view.hasMarkedText()
            session.textChanged(view.string)
            restyle(view)
        }

        /// Dynamic colours: Light/Dark switches redraw them without a restyle.
        func restyle(_ view: PlainTextView) {
            let palette = NoteTextStyler.Palette(ink: Theme.inkNS, rust: Theme.rustNS)
            NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), palette: palette)
        }
    }
}
```

- [ ] **Step 3: Write the editor column**

Create `apps/macos/Rallo/NotesWindow/NoteEditorColumn.swift`:

```swift
import SwiftUI

/// The right column (0019 §11): the open note's date, text and images, with
/// the "changed somewhere else" bar above. The toolbar and the reminder pill
/// come in the next task.
struct NoteEditorColumn: View {
    @ObservedObject var model: NotesWindowModel
    @ObservedObject var editor: NoteEditorSession

    /// The list's copy of the note (latest after a reload), else the session's
    /// (a note created a moment ago).
    private var note: ItemSnapshot? { model.selectedItem ?? editor.note }

    var body: some View {
        Group {
            if note == nil && !editor.isDraft {
                Text("No note selected")
                    .font(Theme.rounded(15, .medium))
                    .foregroundStyle(Theme.bark)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if editor.conflict {
                ConflictBar(
                    showTheirs: { Task { await model.showTheirs() } },
                    keepMine: { Task { await model.keepMine() } }
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(createdText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.bark)
                        .frame(maxWidth: .infinity)
                    NoteTextEditor(session: editor)
                    if let message = editor.error {
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.error)
                            .accessibilityLabel("Error: \(message)")
                    }
                    if let note, !note.images.isEmpty {
                        ImageStrip(
                            item: note,
                            tile: CGSize(width: 210, height: 140),
                            onRemove: { image in Task { await model.removeImage(image, from: note) } },
                            onFocusChange: { _ in }
                        )
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// "8 October 2026 at 10:42"
    private var createdText: String {
        let created = note.map { Date(timeIntervalSince1970: TimeInterval($0.createdAtMs) / 1000) } ?? .now
        return created.formatted(date: .long, time: .shortened)
    }
}

/// An agent or the CLI changed the note while it was being edited (0019 §11).
private struct ConflictBar: View {
    let showTheirs: () -> Void
    let keepMine: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.rust)
                .accessibilityHidden(true)
            Text("This note changed somewhere else.")
                .font(Theme.rounded(13, .medium))
            Spacer(minLength: 8)
            Button("Show Theirs", action: showTheirs)
                .buttonStyle(.bordered)
            Button("Keep Mine", action: keepMine)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.highlight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
```

In `apps/macos/Rallo/NotesWindow/NotesWindowView.swift`, Edit: old `            Text("Editor")  // replaced in Task 12` new `            NoteEditorColumn(model: model, editor: model.editor)`.

- [ ] **Step 4: Build and run the suite**

Run `scripts/build-macos.sh`, then the **Swift test command** with `-only-testing:RalloTests`.
Expected: build and all tests pass.

- [ ] **Step 5: Click through, Light and Dark**

Follow **Scratch run** (use the Task 11 seed, with an image note). Verify, ticking only what you saw:
- With nothing selected the editor reads **No note selected** in the bark colour. Selecting a note shows its date centred like `8 October 2026 at 10:42`, then its text: the `NoteParts` title in 24 pt semibold rounded (`Quarterly plan`, `Standup`), the body at 14.5 pt, every `#tag` rust and semibold (`#release`, `#bug`, and the Arabic-script `#كلمة`, also the one in `Café ideas … 🦊 #bug`); a tag typed inside a title keeps the title size.
- Typing saves 0.6 s after you stop: in a terminal `"$CLI" list` shows the old text at 0.3 s and the new at ~1 s. Switching to another note, ⌘W, and ⌘Q each save immediately (type, then do it at once, then check with the CLI / relaunch).
- Select all, delete, wait 2 s: the CLI still shows the old text; switch to another note and back: the old text is back. A note with an image can be emptied of text and saves.
- While you have typed, run `"$CLI" edit <id> "from the CLI"` (find the id with `"$CLI" list`), wait 1 s: the bar **This note changed somewhere else.** appears with **Show Theirs** and **Keep Mine**, your text stays; **Show Theirs** replaces the text with the CLI's and the bar goes; repeat and **Keep Mine** saves yours (CLI shows it). A reload (any CLI note added meanwhile) never overwrote your typing.
- Input methods: switch to an IME (Japanese Hiragana, or Bangla Phonetic), start composing a word and pause longer than a second with the underlined text uncommitted: it stays underlined and unsaved until committed, and tags typed around it keep styling after. Start another composition and press ⌘W mid-word: what the CLI shows is the committed text, never the underlined form; repeat with ⌘Q and relaunch.
- With the editor idle, `"$CLI" edit <id> "changed outside"`: the text updates within a second; ⌘Z then does nothing and nothing crashes (the undo stack was cleared with the replace).
- Switch System Settings between Light and Dark with a note open: the title, body and tag colours follow at once. Paste formatted text from Safari: it arrives plain. ⌘Z undoes typing; the caret starts at the beginning of a note you open. A long note scrolls with the caret as you type at the bottom.
- 70 KB paste (`python3 -c "print('a'*70000)" | pbcopy`, then ⌘V): the message about the size shows under the text in red, the text stays, and typing it shorter clears the message.
- ⌘N (File menu → New Note, also the list toolbar button) in a folder: a **New Note** row at the top of the list, selected, the editor focused and empty; typing creates the note 0.6 s later in that folder (check with `"$CLI" list --folder Work`) and the row becomes the real note; ⌘N then clicking another row without typing leaves nothing behind. In a tag scope the text starts with `#bug `. ⌘N is dimmed in Due/Done/Deleted and while searching.
- The image note shows its images as 210×140 tiles below the text; click opens Quick Look (arrow keys move between images, Space closes), a tile drags out to the Finder as a copy, and right-click offers Copy Image, Show in Finder, Remove Image (toast "Removed the image" with **Undo**, which attaches it again).
- A Deleted note opens read-only (the text can be selected, not edited).
- Screenshots Light and Dark: a note with title, tags and an image; the conflict bar; the empty state; a new-note draft: `private/docs/folders-3-shots/t12-*.png`. Run the **Cleanup**.

- [ ] **Step 6: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/NotesWindow/NoteTextEditor.swift apps/macos/Rallo/NotesWindow/NoteEditorColumn.swift apps/macos/Rallo/NotesWindow/NotesWindowView.swift apps/macos/Rallo/Notes/ImageStrip.swift apps/macos/Rallo/Shared/Theme.swift
git commit -m "feat(app): notes window editor with styled plain text, conflict bar and image tiles"
```

---

### Task 13: Editor toolbar, reminder pill and the Custom reminder popover

**Files:**
- Modify: `apps/macos/Rallo/Notes/CustomRemindPopover.swift`
- Modify: `apps/macos/Rallo/Notes/NoteRow.swift` (the popover's call site)
- Modify: `apps/macos/Rallo/NotesWindow/NoteEditorColumn.swift`

**Interfaces:**
- Consumes: `NotesWindowModel` (`toggleDone`, `remind`, `remind(_:at:)`, `cancelReminder`, `attachImages`, `move`, `customRemindOpen`, `folders`, `folderName`), `RemindMenuItems` (Task 11), `FolderMoveMenu` (release 2), `WindowFolderPrompt` (Task 11), `ImageClipboard.storable`, `ReminderLabel`.
- Produces: `CustomRemindPopover(onSet: (Date) -> Void, onCancel: () -> Void)` (shared by the panel row and the window); the editor toolbar (Mark as Done / Reopen, Remind Me, Add Image, Move chip) and the reminder pill.

- [ ] **Step 1: Make the Custom… popover independent of the panel's model**

Replace `apps/macos/Rallo/Notes/CustomRemindPopover.swift` with:

```swift
import SwiftUI

/// "Remind Me → Custom…" (0016): type a time, see when it lands, set it.
/// Shared by the panel's rows and the notes window; the caller says what
/// setting and cancelling do.
struct CustomRemindPopover: View {
    let onSet: (Date) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var preview: CustomRemindPreview { CustomRemindPreview(text: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("When?", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(set)
            Text(preview.message)
                .font(.caption)
                .foregroundStyle(preview.date == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Set", action: set)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.date == nil)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { focused = true }
        .onExitCommand(perform: onCancel)
    }

    private func set() {
        // Recomputed now, so a preview left open still sets the time it says.
        guard let date = CustomRemindPreview(text: text).date else { return }
        onSet(date)
    }
}
```

In `apps/macos/Rallo/Notes/NoteRow.swift`, Edit: old `            CustomRemindPopover(item: item, model: model)` new

```swift
            CustomRemindPopover(
                onSet: { date in
                    model.customRemindID = nil
                    Task { await model.remind(item, at: date) }
                },
                onCancel: { model.customRemindID = nil }
            )
```

- [ ] **Step 2: Add the toolbar, the pill and the popover to the editor column**

In `apps/macos/Rallo/NotesWindow/NoteEditorColumn.swift` make these Edits.

1. old
```swift
import SwiftUI

/// The right column (0019 §11): the open note's date, text and images, with
/// the "changed somewhere else" bar above. The toolbar and the reminder pill
/// come in the next task.
struct NoteEditorColumn: View {
```
new
```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The right column (0019 §11): the open note's date, reminder, text and
/// images, with the "changed somewhere else" bar above and the note's actions
/// in the toolbar.
struct NoteEditorColumn: View {
```
2. old
```swift
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }

    private var content: some View {
```
new
```swift
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .toolbar { toolbar }
    }

    /// A note that can be acted on: saved, and not in Deleted.
    private var actionable: ItemSnapshot? {
        guard let note, note.deletedAtMs == nil else { return nil }
        return note
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            let done = actionable?.status == .done
            Button {
                if let note = actionable { Task { await model.toggleDone(note) } }
            } label: {
                Label(done ? "Reopen" : "Mark as Done", systemImage: done ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .disabled(actionable == nil)
            .help(done ? "Reopen" : "Mark as Done")

            Menu {
                if let note = actionable {
                    RemindMenuItems(
                        onPreset: { preset in Task { await model.remind(note, preset) } },
                        onCustom: { model.customRemindOpen = true }
                    )
                }
            } label: {
                Label("Remind Me", systemImage: "bell")
            }
            .disabled(actionable == nil)
            .help("Remind Me")

            Button(action: addImage) {
                Label("Add Image", systemImage: "photo.badge.plus")
            }
            .disabled(actionable == nil)
            .help("Add Image")

            Menu {
                if let note = actionable {
                    FolderMoveMenu(
                        currentFolderID: note.folderId,
                        folders: model.folders,
                        onMove: { id in Task { await model.move(note, toFolder: id) } },
                        onNewFolder: { Task { await WindowFolderPrompt.newFolder(for: note, model: model) } }
                    )
                }
            } label: {
                Label(model.folderName(actionable?.folderId), systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(actionable == nil)
            .help("Move to Folder")
        }
    }

    /// Add Image: an open panel for images, normalised like pasted ones, then `attach_images`.
    private func addImage() {
        guard let note = actionable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to add to this note"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let images = await Task.detached { urls.compactMap { try? Data(contentsOf: $0) }.compactMap(ImageClipboard.storable) }.value
            if images.isEmpty {
                model.errorMessage = "Couldn’t read that image."
            } else {
                await model.attachImages(images, to: note)
            }
        }
    }

    private var content: some View {
```
3. old
```swift
                        .frame(maxWidth: .infinity)
                    NoteTextEditor(session: editor)
```
new
```swift
                        .frame(maxWidth: .infinity)
                        .popover(isPresented: $model.customRemindOpen, arrowEdge: .bottom) {
                            CustomRemindPopover(
                                onSet: { date in
                                    model.customRemindOpen = false
                                    if let note = actionable { Task { await model.remind(note, at: date) } }
                                },
                                onCancel: { model.customRemindOpen = false }
                            )
                        }
                    if let note = actionable, let reminder = note.reminder, reminder.state == .active {
                        ReminderPill(
                            reminder: reminder,
                            onPreset: { preset in Task { await model.remind(note, preset) } },
                            onCustom: { model.customRemindOpen = true },
                            onCancel: { Task { await model.cancelReminder(note) } }
                        )
                    }
                    NoteTextEditor(session: editor)
```
4. old
```swift
/// An agent or the CLI changed the note while it was being edited (0019 §11).
private struct ConflictBar: View {
```
new
```swift
/// The note's reminder (a bell, `Theme.rust`); clicking it offers the Remind Me
/// choices again, and Cancel Reminder.
private struct ReminderPill: View {
    let reminder: ReminderSnapshot
    let onPreset: (RemindPreset) -> Void
    let onCustom: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let when = ReminderLabel.text(for: reminder.deadline)
        Menu {
            RemindMenuItems(onPreset: onPreset, onCustom: onCustom)
            Divider()
            Button("Cancel Reminder", role: .destructive, action: onCancel)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reminder.alertBlocked ? "bell.slash" : "bell")
                    .font(.system(size: 11, weight: .semibold))
                Text(when.prefix(1).uppercased() + when.dropFirst())
            }
            .font(Theme.rounded(12.5, .semibold))
            .foregroundStyle(Theme.rust)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.highlight))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(reminder.statusNote?.help ?? "Reminder \(when)")
        .accessibilityLabel("Reminder \(when)")
    }
}

/// An agent or the CLI changed the note while it was being edited (0019 §11).
private struct ConflictBar: View {
```

- [ ] **Step 3: Build and run the suite**

Run `scripts/build-macos.sh`, then the **Swift test command** with `-only-testing:RalloTests`.
Expected: build and all tests pass.

- [ ] **Step 4: Click through, Light and Dark**

Follow **Scratch run**. Verify, ticking only what you saw:
- With a note selected the toolbar (right of the list's buttons, before the search field) shows **Mark as Done**, **Remind Me**, **Add Image**, and the **Move chip** (`[folder] Work ⌄`, or `Notes ⌄`); with no note, or a note in Deleted, all four are dimmed. If the toolbar items sit in one group instead of over their own column, accept it and note it in the commit body.
- Mark as Done: the toast "Marked “…” as done" with **Undo**; the button becomes **Reopen** and reopens it. Remind Me: **In 20 Minutes** sets a reminder and the pill `Today at …` (rust bell on the highlight capsule) appears under the date; the list row shows the bell label too. Clicking the pill offers the choices again and **Cancel Reminder** (the pill disappears, the note stays open). **Custom…** (toolbar, pill and the list's context menu) opens the popover under the date: type `fri 5pm`, it previews, **Set** sets it; Esc closes it. The panel's own Custom… popover still works (open the panel, Remind Me → Custom…).
- Add Image: the open panel offers images only, multiple selection; the tiles appear (210×140) and the list row gets a thumbnail; 11 images total refuses with "A note can hold 10 images."; a text file cannot be chosen.
- Move chip: lists Notes, then folders alphabetically with the current one checked and disabled, then **New Folder…** (the card, then creates and moves; toast "Moved to …" with **Undo**). Moving inside a folder scope makes the note leave the list and the editor clear.
- Typing then clicking Mark as Done/Move at once never shows "That note changed elsewhere" (our own save does not conflict).
- Screenshots Light and Dark: toolbar with the Move menu open, the pill, the Custom popover: `private/docs/folders-3-shots/t13-*.png`. Run the **Cleanup**.

- [ ] **Step 5: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add apps/macos/Rallo/Notes/CustomRemindPopover.swift apps/macos/Rallo/Notes/NoteRow.swift apps/macos/Rallo/NotesWindow/NoteEditorColumn.swift
git commit -m "feat(app): notes window toolbar, reminder pill and the shared Custom reminder popover"
```

---

### Task 14: README and the whole-feature pass

**Files:**
- Modify: `README.md` (the "In the app" table)

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing docs for the window. (Release notes wait for release time; no version bump.)

- [ ] **Step 1: Document the window in the README**

In `README.md`, Edit: old `| **Screenshot to a note** |` new

```markdown
| **Notes window** | The expand button at the top right of the panel, **Notes Window** in the menu bar menu, or the Dock icon while it is open. A three-column window like Apple Notes: folders, views (All Notes, Due, Done, Deleted) and `#tags` on the left; the notes of the selection, grouped by date, in the middle, with a collapsed "N done" row, search (⌘F) across every folder, and Undo for done, delete and move; the note itself on the right, edited in place (saved as you type) with its reminder, images, and a Move chip. ⌘N starts a note in the current folder, ⇧⌘N a folder; drag a note onto a folder to file it; right-click a folder to rename or delete it (keep its notes in Notes, or delete them too). Rallo shows in the Dock only while this window is open. |
| **Screenshot to a note** |
```

- [ ] **Step 2: Run the full suites**

```bash
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
cd /Users/eyakub/Desktop/Rallo
cargo test --workspace 2>&1 | tail -5
(cd apps/macos && xcodegen generate --quiet) && xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release -derivedDataPath build/DerivedData test 2>&1 | tail -15
```

Expected: `test result: ok` for every crate; `** TEST SUCCEEDED **`.

- [ ] **Step 3: One last end-to-end pass on a fresh scratch run, both appearances**

Follow **Scratch run** from an empty data dir and do the whole story once in Light, then once in Dark: create two folders from the sidebar (inline rename), create notes with ⌘N in each, tag one, drag a note between folders, search, mark one done and reopen it, delete it and restore it from Deleted, delete a folder keeping its notes, delete another deleting them, expand the panel into the window with a note expanded, close the window with ⌘W while Settings is open, reopen from the Dock after minimising, quit with ⌘Q mid-typing and relaunch to find the text saved. Confirm `lsregister -u` and the cleanup ran, and `git status --short` shows only `assets/pet/rallo/launch-kit/` and `marketing/` as untracked.

- [ ] **Step 4: Commit**

```bash
cd /Users/eyakub/Desktop/Rallo
git add README.md
git commit -m "docs: the notes window in the README"
```

---

## Self-Review

**Spec coverage (§11, §12, and §14's third release).**
- Window: `NSWindow` titled "Notes" with titled/closable/miniaturizable/resizable/full-size content/unified toolbar, `isReleasedWhenClosed = false`, min 900×560, 1140×690 centred, frame remembered as `RalloNotesWindow` in the coordinator's scratch-aware defaults (never AppKit autosave), three-column `NavigationSplitView`, surface gradient, system sidebar material, `.tint(Theme.rust)`: Tasks 9, 10, 11, 12.
- Expand button (symbol, help, accessibility label, closes the panel, opens on the panel's scope and expanded row): Task 9. Opening paths (button, status-menu "Notes Window", Window-menu "Notes Window", Dock icon): Task 9. Menus exactly §11 (File: New Note, New Folder, Close; Window: Minimize, Notes Window; Find ⌘F): Task 9. `.regular` on open, `.accessory` on close (switched after the close sequence), Settings and the panel considered, ⌘W, red button, ⌘Q (marked text committed first), Dock reopen of a minimised window: Task 9 (`updateActivationPolicy`, `handleReopen`, `applicationShouldTerminate`).
- Sidebar (Folders with +, Notes then alphabetical with counts, context menu Rename inline and Delete Folder…, footer + New Folder ⌘⇧N, Views with counts, Tags hidden when none, drop targets with id payload and unknown ids ignored): Task 10 (+ the model in Task 8).
- List (header and subtitle from the core's `totalCount`, paged loading through `ItemPage` cursors with the next page on the last row's appearance and reloads that keep the loaded pages, no cap anywhere, date groups, Due flat by deadline, Done by completion, Deleted by deletion (all ordered by the core), row anatomy with 38 pt thumbnail, selected highlight, collapsed "N done" row dimmed when expanded, Deleted rows Restore only, Delete ⌫ and New Note ⌘N disabled in Due/Done/Deleted/search, shared Undo toast, search ⌘F across folders under "Results"): Tasks 3, 8, 9, 11.
- Editor (empty state, toolbar items, date, reminder pill with Cancel Reminder (`cancel_reminder`: state `cancelled`, note open), plain-text `NSTextView`, 24 pt semibold rounded title, tinted tags via `tagRanges`, image tiles 210×140 with Quick Look/drag-out/remove, saving 0.6 s + on selection change/close/quit, `REVISION_CONFLICT` bar with Show Theirs/Keep Mine, emptied-note restore, `TEXT_TOO_LONG` inline, draft "New Note" created on the first non-empty save in the scope's folder with the `#tag ` seed, live reload that never overwrites typing, vanished note clears the selection, deleted scope folder switches to Notes): Tasks 5, 6, 7, 8, 12, 13.
- §12: sheet copy exactly (plural/singular/empty) with the count from `FolderSnapshot.noteCount` (open + done), Keep Notes default, Delete Notes destructive, Cancel; `delete_folder(id, keep_notes)`; no undo beyond Deleted: Tasks 8 and 10.

**Placeholder scan.** The only temporary content is Task 9's three `Text` column bodies, each replaced by an explicit Edit in Tasks 10, 11 and 12 (named in the code comments). No "TBD"/"add handling" steps; every code step has complete code; every test step has complete test code and an exact command.

**Type consistency.** `NotesWindowModel` members used by the views (`header`, `visibleItems`, `doneItems`, `open`, `done`, `found`, `loadMore(done:)`, `doneExpanded`, `listIsGrouped`, `groupTimestamp`, `selectedNoteID`, `selectedItem`, `isDrafting`, `isSearching`, `canCreateNote`, `customRemindOpen`, `renamingFolderID`, `pendingFolderDelete`, `toast`, `errorMessage`, `folders`, `folderName`, `overview`, `tags`, `editor`) are all defined in Task 8; `NoteEditorSession` members used by `NoteTextEditor`/`NoteEditorColumn` (`text`, `showCount`, `focusToken`, `isDraft`, `isEditable`, `note`, `conflict`, `error`, `isComposing`, `textChanged`) in Task 7; `CoreClient` calls from release 2 (`createNote(_:images:folderID:)`, `createFolder(_:)`, `deleteFolder(_ id:keepNotes:)`, `folderOverview()`, `moveItem(_:folderID:)`) and Task 2 (`pageSize`, paged `listItems`/`searchItems` returning `ItemPage`, `listTags`, `renameFolder(_:to:)`, `cancelReminder(_:)`), with no name defined twice; `NotesScope.folderScope` from release 2 only; `FolderNaming.newFolderName(existing:)` in Tasks 4 and 8; `WindowFolderPrompt.newFolder(for:model:) async` in Tasks 11 and 13; `FolderDeleteCopy(folderName:noteCount:)` in Task 10; `DateGrouping.sections(_:timestampMs:now:calendar:locale:)` in Tasks 3 and 11; `ToastBar(message:undoable:undoShortcut:undo:)` in Task 11 and the panel; `Theme.inkNS`/`rustNS` in Task 12; `RemindMenuItems(onPreset:onCustom:)` in Tasks 11 and 13; `CustomRemindPopover(onSet:onCancel:)` in Task 13 and the panel row; `ImageStrip(item:tile:onRemove:onFocusChange:)` in Tasks 12 and the panel's convenience init.

**Review Focus.** Each of the five lines names its tests in the owning tasks (6, 7, 2, 8, 10, 4). The two checks that are manual by nature (IME with a real input method, quit while typing) are Task 12's click-through.
