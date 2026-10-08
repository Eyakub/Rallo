# Review: docs/plans/2026-10-08-folders-3-window.md (HEAD 855c1b1)

Read against: spec 0019 §9–§12 (latest), mockup §2–§3, release 1 plan Task 7, release 2 plan Tasks 1–6, and the real code the plan edits (AppDelegate, AppCoordinator, StatusMenuController, NotesPanel, NotesView, NoteRow, CustomRemindPopover, ImageStrip, Thumbnails, QuickLookPresenter, SettingsWindowController, WindowReport, CoreClient/CoreWorker, ChangeObserver, project.yml, Generated/rallo_ffi.swift, PetPanel + 0002, core repository.rs). Every "old" anchor in the plan's Edits was checked against the current files; all match except the one named in M4.

Counts: BLOCKER 2 · MAJOR 9 · MINOR 10.

---

## BLOCKER 1 — Paging (`ItemPage`/cursor) is not consumed; the plan hard-codes a 200 cap the spec forbids
**Location:** Global Constraints (bullet "The core's lists take limit 1…200 and the FFI has no cursor…"), header "Swift API this plan assumes" (line 19), Task 1 Step 1, Task 2 (wrappers + `nonDeletedNoteCount`), Task 3 (`CountLabel`, `testAFullPageReadsAsMoreThanItShows`), Task 8 (`items/doneItems/results`, `load`, `header`, `openTotal`, `openAndDone`, `syncSelectedNote`), Task 11 (`doneRow`, header), File Structure row for `DateGrouping.swift`, Self-Review.
**Problem:** Release 1 Task 7 (and §9) produce `listItems(kind:scope:tag:limit:cursor:) -> ItemPage` and `searchItems(query:limit:cursor:) -> ItemPage` (`{items, nextCursor, totalCount}`). The plan compiles against `-> [ItemSnapshot]` with no cursor (won't compile), shows "200+" (spec: no cap; "the window loads the next page when its last row appears"), and derives counts from capped lists. Also, once lists page, `reload()` as written would drop a selected note that lives on page 2+ (`syncSelectedNote` → `letGoOfNote`) on every change signal — the selection must survive a reload, so a reload has to re-fetch as many pages as were loaded.
**Fix (spec wins):**
1. Delete the Global-Constraints cap bullet; in the header list replace the two signatures with the paged ones, add `ItemPage { items: [ItemSnapshot], nextCursor: String?, totalCount: UInt32 }`, `cancelReminder(id:ifRevision:) -> ItemSnapshot`, and `FolderSnapshot { id, name, openCount, noteCount: UInt32, revision }`.
2. Task 1 test: 
```swift
XCTAssertEqual(try store.listItems(kind: kinds[0], scope: scopes[2], tag: nil, limit: 200, cursor: nil).items.map(\.id), [note.id])
XCTAssertEqual(try store.listItems(kind: kinds[0], scope: scopes[0], tag: "release", limit: 200, cursor: nil).totalCount, 1)
let page: ItemPage = try store.searchItems(query: "release", limit: 200, cursor: nil)
XCTAssertEqual(page.items.map(\.id), [note.id]); XCTAssertNil(page.nextCursor)
XCTAssertEqual(overview.folders.first?.noteCount, 1)
```
3. Task 2 wrappers (replace `listItems`/`searchItems`, delete `listLimit` and `nonDeletedNoteCount`):
```swift
    /// One page per call (`limit` 1…200); pass the previous page's `nextCursor` for the next.
    static let pageSize: UInt32 = 100

    func listItems(
        _ kind: ItemListKind, scope: FolderScope = .all, tag: String? = nil, cursor: String? = nil,
        limit: UInt32 = CoreClient.pageSize
    ) async throws -> ItemPage {
        try await worker.perform { try $0.listItems(kind: kind, scope: scope, tag: tag, limit: limit, cursor: cursor) }
    }

    /// Open and done notes in every folder.
    func searchItems(_ query: String, cursor: String? = nil, limit: UInt32 = CoreClient.pageSize) async throws -> ItemPage {
        try await worker.perform { try $0.searchItems(query: query, limit: limit, cursor: cursor) }
    }
```
   Task 2 test: `core.listItems(.open, scope: .folder(id: work.id)).items`, etc.; add a paging round trip (`limit: 2` → `nextCursor` → second page → `nextCursor == nil`).
4. Task 3: delete `CountLabel` and its test (`DateGrouping.swift` then no longer references `CoreClient`); fix the File Structure row.
5. Task 8 model — replace the three arrays with paged lists and page-aware reload:
```swift
/// The loaded pages of one list and how to get the next (0019 §9).
struct PagedItems {
    var items: [ItemSnapshot] = []
    var nextCursor: String?
    var totalCount = 0
    /// Pages fetched so far: a reload fetches the same number again, so a selected note on page 3 stays loaded.
    var pages = 0
    var hasMore: Bool { nextCursor != nil }
}
```
```swift
    @Published private(set) var open = PagedItems()
    @Published private(set) var done = PagedItems()
    @Published private(set) var found = PagedItems()
    var items: [ItemSnapshot] { open.items }
    var doneItems: [ItemSnapshot] { done.items }
    var results: [ItemSnapshot] { found.items }
    let pageSize: UInt32   // init(core:saveDelay:pageSize: UInt32 = CoreClient.pageSize); tests pass 2

    /// One page of the selection's open (or done) list.
    private func page(_ selection: NotesWindowSelection, done: Bool, cursor: String?) async throws -> ItemPage {
        switch selection {
        case let .scope(scope): try await core.listItems(done ? .done : .open, scope: scope.folderScope, cursor: cursor, limit: pageSize)
        case let .tag(name): try await core.listItems(done ? .done : .open, tag: name, cursor: cursor, limit: pageSize)
        case .due: try await core.listItems(.due, cursor: cursor, limit: pageSize)
        case .done: try await core.listItems(.done, cursor: cursor, limit: pageSize)
        case .deleted: try await core.listItems(.deleted, cursor: cursor, limit: pageSize)
        }
    }

    /// Folders, Notes, All Notes and tags have the second "N done" list; Due, Done, Deleted don't.
    private static func hasDoneList(_ selection: NotesWindowSelection) -> Bool {
        switch selection { case .scope, .tag: true; default: false }
    }

    /// `pages` pages (at least one) of one list, following the core's cursors.
    private func fetch(pages: Int, _ page: (String?) async throws -> ItemPage) async throws -> PagedItems {
        var loaded = PagedItems()
        var cursor: String?
        repeat {
            let next = try await page(cursor)
            loaded.items += next.items
            loaded.totalCount = Int(next.totalCount)
            loaded.pages += 1
            cursor = next.nextCursor
        } while cursor != nil && loaded.pages < max(1, pages)
        loaded.nextCursor = cursor
        return loaded
    }

    /// The last loaded row of a list came into view: the next page.
    func loadMore(done wantDone: Bool = false) async {
        let list = isSearching ? found : (wantDone ? done : open)
        guard let cursor = list.nextCursor else { return }
        let mine = generation
        do {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = isSearching
                ? try await core.searchItems(text, cursor: cursor, limit: pageSize)
                : try await page(selection, done: wantDone, cursor: cursor)
            guard mine == generation else { return }
            var updated = list
            updated.items += next.items
            updated.nextCursor = next.nextCursor
            updated.totalCount = Int(next.totalCount)
            updated.pages += 1
            if isSearching { found = updated } else if wantDone { done = updated } else { open = updated }
        } catch {
            await report(error)
        }
    }
```
   In `reload()` replace `let lists = try await load(target) … items = …; doneItems = …; results = found` with:
```swift
            let keep = target == selection  // a fallback starts over on page 1
            let openList = try await fetch(pages: keep ? open.pages : 1) { try await page(target, done: false, cursor: $0) }
            let doneList = Self.hasDoneList(target)
                ? try await fetch(pages: keep ? done.pages : 1) { try await page(target, done: true, cursor: $0) } : PagedItems()
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let foundList = text.isEmpty ? PagedItems() : try await fetch(pages: found.pages) { try await core.searchItems(text, cursor: $0, limit: pageSize) }
            guard mine == generation else { return }
            …
            open = openList; done = doneList; found = foundList
```
   `select()` resets `open = PagedItems(); done = PagedItems(); found = PagedItems()` before `reload()`. `loaded` becomes `isSearching ? found.items : open.items + done.items`. Delete `load(_:)`, `sorted(_:in:done:)` (the core already orders every list; see repository.rs `simple_page`/`due_page`), `openTotal`, `openAndDone`; `header` becomes:
```swift
        if isSearching { return Header(title: "Results", subtitle: Self.notes(found.totalCount)) }
        switch selection {
        case let .scope(scope): return Header(title: …, subtitle: "\(open.totalCount) open · \(done.totalCount) done")
        case let .tag(name): return Header(title: "#\(name)", subtitle: "\(open.totalCount) open · \(done.totalCount) done")
        case .due: return Header(title: "Due", subtitle: Self.notes(open.totalCount))
        case .done: return Header(title: "Done", subtitle: Self.notes(open.totalCount))
        case .deleted: return Header(title: "Deleted", subtitle: Self.notes(open.totalCount))
        }
```
   Add a test: `model = NotesWindowModel(core: core, saveDelay: 0.05, pageSize: 2)`; 5 notes; `reload()` → `open.items.count == 2`, `open.totalCount == 5`, `open.hasMore`; `loadMore()` twice → 5 and `!hasMore`; `selectNote(fifth)`; `other.createNote(…)`; `reload()` → `open.items.count == 6` and `selectedNoteID == fifth` (the selection survives a reload).
6. Task 11: `doneRow` text `"\(model.done.totalCount) done"`; empty-state `isEmpty` uses `model.done.totalCount == 0`; and in `row(_:dimmed:)` add
```swift
            .onAppear {
                let list = dimmed ? model.done : (model.isSearching ? model.found : model.open)
                if item.id == list.items.last?.id, list.hasMore { Task { await model.loadMore(done: dimmed) } }
            }
```
   Task 11's click-through gains: seed 250 notes (`for i in $(seq 1 250); do "$CLI" note "Idea $i"; done`), scroll All Notes to the bottom, the rest load; the header reads `250 open`, never `200+`.

## BLOCKER 2 — Task 2 overwrites release 2's test file
**Location:** Task 2 "Create: `apps/macos/RalloTests/CoreClientFoldersTests.swift`" + class `CoreClientFoldersTests`.
**Problem:** Release 2 Task 2 already creates exactly that path and class (`testMoveWithAStaleRevisionIsAConflict`, `testFolderNameErrorsKeepTheirCodes`, …). "Create" here silently replaces those tests; a duplicate class name would not even compile if the executor appends instead.
**Fix:** Name release 3's file `apps/macos/RalloTests/CoreClientWindowTests.swift`, class `CoreClientWindowTests`; update Task 2 Steps 1/2/4/5 and the commit paths accordingly.

---

## MAJOR 1 — Cancel Reminder uses `acknowledgeReminder`; §9 exposes `cancel_reminder`
**Location:** Task 8 `NotesWindowModel+Notes.cancelReminder` (and its doc comment "The FFI has no cancel (0019 §9)"), Task 8 test `testRemindAndCancelReminder`, Task 2, Task 13 `ReminderPill.onCancel`, Task 9 Step 6 expectation text.
**Problem:** Release 1 Task 7 generates `cancelReminder(id:ifRevision:)` (state `.cancelled`, note stays open). Acknowledging yields `.acknowledged` (a different state the CLI's `cancel-reminder` never produces) and is the "I saw the alert" path.
**Fix:** Task 2 adds
```swift
    /// The CLI's `cancel-reminder`: the reminder's state becomes `cancelled`; the note stays open.
    func cancelReminder(_ item: ItemSnapshot) async throws -> ItemSnapshot {
        try await worker.perform { try $0.cancelReminder(id: item.id, ifRevision: item.revision) }
    }
```
Task 8: `await run { _ = try await $0.cancelReminder(item) }`, comment "The reminder pill's Cancel Reminder (0019 §9)". Test: `XCTAssertEqual(model.loadedItem(item.id)?.reminder?.state, .cancelled)`. Task 1 test adds `let cancelled = try store.cancelReminder(id: reminded.id, ifRevision: reminded.revision); XCTAssertEqual(cancelled.reminder?.state, .cancelled)` after a `createReminderWithImages(text:when:images:folderId:)`.

## MAJOR 2 — "It holds N notes" sums two capped lists instead of `FolderSnapshot.noteCount`
**Location:** Task 2 `nonDeletedNoteCount(inFolder:)` + `testNonDeletedNoteCountIncludesDoneNotes`; Task 8 `PendingFolderDelete.noteCount`, `requestDelete` (async + core call); Task 10 `Button("Delete Folder…") { Task { await model.requestDelete(folder) } }`; Review Focus 4 text.
**Problem:** §9 added `note_count` (open + done, nondeleted) precisely for §12. The plan's count is two extra core reads and wrong past one page (with B1 fixed it would have to walk every page).
**Fix:**
```swift
struct PendingFolderDelete: Identifiable {
    let folder: FolderSnapshot
    /// Open + done, nondeleted: the core's `note_count` (0019 §9).
    var noteCount: Int { Int(folder.noteCount) }
    var id: String { folder.id }
}
    /// Delete Folder…: the sheet asks (0019 §12).
    func requestDelete(_ folder: FolderSnapshot) { pendingFolderDelete = PendingFolderDelete(folder: folder) }
```
Sidebar: `Button("Delete Folder…", role: .destructive) { model.requestDelete(folder) }`. Tests: drop `await` on `requestDelete`; Task 2's test becomes `XCTAssertEqual(overview.folders.first?.noteCount, 1, "the sheet must still say it holds a note")`. Review Focus 4 now pins `noteCount` from `folderOverview` (Task 8 `testDeletingAFolderOfOnlyDoneNotesKeepsThem` keeps `XCTAssertEqual(snapshot.openCount, 0)` and adds `XCTAssertEqual(snapshot.noteCount, 1)`).

## MAJOR 3 — Wrapper names collide with / diverge from release 2's `CoreClient`
**Location:** Task 1 Step 3 (grep-and-guess), Task 2 Interfaces + Step 3, Task 8 (`core.moveItem(item, toFolder:)` ×2, `createNote(_:images:folderID:)`), Task 2 test (`moveItem(note, toFolder: nil)`), Task 4 (`extension NotesScope { var folderScope }` + `testTheScopeMapsToTheFFIScope`).
**Problem:** Release 2 Task 2 already defines `folderOverview()`, `createFolder(_:)`, `moveItem(_ item:, folderID:)`, `createNote(_:images:folderID: = nil)`, `createReminder(_:when:images:folderID: = nil)`, `openItems(scope:limit:)`; release 2 Task 3 defines `NotesScope.folderScope` and tests it (`testMapsToTheCoreScope`). Release 3 re-adds `createNote(_:images:folderID:)` (invalid redeclaration: a default argument doesn't change the signature), `folderScope` (invalid redeclaration), and a second `moveItem` spelling (`toFolder:`) while telling the executor to "skip what exists" — so Task 8 then fails to compile against `moveItem(_:folderID:)`. Plans must not leave naming to a grep at execution time.
**Fix:** Task 2 adds only `listTags`, `renameFolder(_:to:)`, `deleteFolder(_:keepNotes:)`, paged `listItems`/`searchItems` (B1), `cancelReminder` (M1). Delete Task 1 Step 3's wrapper grep loop and Step 2's temporary file. Task 8 uses `core.moveItem(item, folderID: folderID)` and `$0.moveItem(moved, folderID: before)`; Task 2's test uses `folderID:`. Task 4 deletes the `NotesScope` extension and `testTheScopeMapsToTheFFIScope` (keep `NotesWindowSelection` + `SelectionFallback`).

## MAJOR 4 — Task 9 Edit 2's anchor no longer exists after release 2
**Location:** Task 9 Step 6, AppCoordinator Edit 2 (old text `notesModel = NotesViewModel(core: core)` / `notes = NotesPanelController(model: notesModel)`).
**Problem:** Release 2 Task 5 Step 6 rewrites the first line to `notesModel = NotesViewModel(core: core, defaults: isScratch ? UserDefaults(suiteName: "com.razlio.rallo.scratch")! : .standard)`. The Edit's "old" block won't match; the step can't pass as written.
**Fix:** Anchor on the unchanged line only: old `        notes = NotesPanelController(model: notesModel)` → new that line plus `notesWindowModel = …` / `notesWindow = …` (see M5 for the `defaults:` argument).

## MAJOR 5 — Scratch builds write the window frame into the installed app's defaults
**Location:** Task 9 `makeWindow()` (`setFrameAutosaveName("RalloNotesWindow")`), Global Constraints "Scratch run" (`defaults read com.razlio.rallo …`, `defaults delete com.razlio.rallo "NSWindow Frame RalloNotesWindow"`), Task 14 Step 3.
**Problem:** The scratch build shares bundle id `com.razlio.rallo`, so `NSWindow` autosave writes `~/Library/Preferences/com.razlio.rallo.plist` — the real app's domain — and the plan then has the executor `defaults delete` a key in that domain by hand. Release 2 resolved the same problem for the panel scope with a scratch suite (its Spec note 4); the window must follow it (repo rule: never touch the user's real data/defaults).
**Fix:** Persist the frame through the injected defaults instead of AppKit autosave (the key name stays `RalloNotesWindow`):
```swift
    init(model: NotesWindowModel, defaults: UserDefaults) { … }
    private static let frameKey = "RalloNotesWindow"
    // makeWindow(), in place of center()+setFrameAutosaveName:
        if let saved = defaults.string(forKey: Self.frameKey) { window.setFrame(from: saved) } else { window.center() }
    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }
    func windowDidMove(_ notification: Notification) { rememberFrame() }
    private func rememberFrame() { if let window { defaults.set(window.frameDescriptor, forKey: Self.frameKey) } }   // also from windowWillClose
```
AppCoordinator: hoist release 2's expression into `private let defaults: UserDefaults` (set in `init` before `notesModel`), pass it to both `NotesViewModel(core:defaults:)` and `NotesWindowController(model:defaults:)`. Delete the two `defaults read/delete` lines from Scratch run and the "defaults has no new keys beyond…" clause in Task 14 Step 3; Task 9 Step 8's relaunch check stays valid (the scratch suite remembers the frame).

## MAJOR 6 — Programmatic text replacement leaves the NSTextView undo stack pointing at stale ranges
**Location:** Task 12 `NoteTextEditor.updateNSView` (`view.string = session.text` for `sync`/`leave`-restore/`showTheirs`).
**Problem:** Undo actions are cleared only when `showCount` changes. `sync(_:)` (a reload after the CLI edited the note while the editor was idle) and `leave()` (putting the saved text back after the user emptied the note) replace the string without clearing undo; ⌘Z afterwards replays ranges against a different string — NSTextView raises `NSRangeException`.
**Fix:**
```swift
        if !view.hasMarkedText(), view.string != session.text {
            let kept = view.selectedRange()
            view.string = session.text
            view.undoManager?.removeAllActions()  // undo across a programmatic replace would hit stale ranges
            view.setSelectedRange(NSRange(location: min(kept.location, (session.text as NSString).length), length: 0))
        }
```
Add to Task 12's click-through: "`"$CLI" edit <id> …` while the editor is idle, then ⌘Z: nothing crashes (undo is empty)".

## MAJOR 7 — ⌘W / ⌘Q mid-composition can save marked (half-composed) text
**Location:** Task 9 `windowWillClose` and `AppDelegate.applicationShouldTerminate` → `flushNotesWindow()`; Task 7 `flush()`.
**Problem:** `flush()` ignores `isComposing` (only the timer path waits), and nothing ends the IME session before `leave()`/`flush()` run, so `view.string` still contains the underlined, uncommitted text when the window closes or the app quits (Review Focus 1 says never save it).
**Fix:** End editing first so the input method commits and `textDidChange` delivers the final text:
```swift
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)   // commits any marked text before the editor saves
        rememberFrame()
        onPresenceChange(false)
        Task { await model.closed() }
    }
    // AppCoordinator
    func flushNotesWindow() async {
        notesWindow.nsWindow?.makeFirstResponder(nil)
        await notesWindowModel.editor.flush()
    }
```
Add to Task 12's click-through: "start a Japanese/Bangla composition, press ⌘W: the committed text is what the CLI shows, never the underlined form".

## MAJOR 8 — Release 2's plan is stale against the same §9 change (cross-plan, release 2 must change)
**Location:** `docs/plans/2026-10-08-folders-2-panel.md` lines 17 (`FolderSnapshot(id:name:openCount:revision:)`), 32–33 (`listItems(kind:scope:tag:limit:) -> [ItemSnapshot]`, `searchItems(query:limit:)`), 216, 247–249, 257 (`FolderFFIContractTests`), 479 (`openItems(scope:limit:)` body), 537 (`FolderFixtures.testFolder`).
**Problem:** Release 1 Task 7 (updated) emits `noteCount` on `FolderSnapshot` (uniffi's memberwise init then requires it), and paged `listItems`/`searchItems` returning `ItemPage`. Every one of those release 2 lines fails to compile; release 3 Task 1 "stop if release 1 differs" would then trip on release 2, not release 1.
**Fix (release 2 side):** `testFolder` → `FolderSnapshot(id: id, name: name, openCount: open, noteCount: open, revision: 1)` (line 216 likewise with `noteCount: 5`); `openItems(scope:limit:)` → `try $0.listItems(kind: .open, scope: scope, tag: nil, limit: limit, cursor: nil).items`; contract tests → `listItems(…, limit: 50, cursor: nil).items` / `searchItems(query: "plan", limit: 10, cursor: nil).items`; header lines 32–33 → the paged signatures. Release 3's Task 1 then only pins release 3's own needs (B1 item 2).

## MAJOR 9 — Menus: "Close Window" ≠ spec "Close", and "Notes Window" is left to `NSApp.windowsMenu` auto-population
**Location:** Task 9 Step 6, AppDelegate Edit 3; Global Constraints "Copy is exact".
**Problem:** §11 pins File (New Note ⌘N, New Folder ⇧⌘N, Close ⌘W) and Window (Minimize ⌘M, Notes Window). The plan titles the item "Close Window" and relies on `NSApp.windowsMenu` to list open windows, which yields "Rallo Notes" (the window's title — identical to the panel's title, so Mission Control and `WindowReport` can't tell them apart either) and also auto-adds the Settings window under its tab title; when the window is closed there is no "Notes Window" item at all.
**Fix:** 
```swift
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        …
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let notesWindowItem = windowMenu.addItem(withTitle: "Notes Window", action: #selector(openNotesWindow), keyEquivalent: "")
        notesWindowItem.target = self
        // No NSApp.windowsMenu: AppKit would add "Rallo Notes" (also the panel's title) and the Settings tab title.
```
plus `@objc private func openNotesWindow() { coordinator?.openNotesWindow() }` and a non-private `AppCoordinator.openNotesWindow() { notesWindow.show() }` (reuse it for the status-menu action in Edit 3). Give the window its own title, `window.title = "Notes"`, so diagnostics and Mission Control distinguish it from the panel's "Rallo Notes".

---

## MINOR 1 — Activation-policy switching inside `windowWillClose`
**Location:** Task 9 `windowWillClose`, `AppCoordinator.updateActivationPolicy`, `show()`.
**Problem:** `setActivationPolicy(.accessory)` during AppKit's close sequence (and `.regular` + `activate` + `makeKeyAndOrderFront` in one turn on first open) are the two places the known LSUIElement glitches show up (menu bar not painted until the next activation; the closing window briefly stuck). Not a logic error; the click-through would reveal it.
**Fix:** In `windowWillClose` wrap the policy change: `DispatchQueue.main.async { [weak self] in self?.onPresenceChange(false) }`. In `show()`, if Step 8 shows a blank menu bar on first open, follow `NSApp.setActivationPolicy(.regular)` with `DispatchQueue.main.async { NSApp.activate(); window.makeKeyAndOrderFront(nil) }`.

## MINOR 2 — ⌘F has nothing to bind to
**Location:** Task 9 `NotesWindowView.searchable`, Task 11 Step 5 ("⌘F focuses the toolbar search field").
**Problem:** The main menu is built in AppKit and has no Find item; SwiftUI's `.searchable` in an `NSHostingController` gets ⌘F only through a Find menu command. The check step may fail with nothing in the plan to fix it.
**Fix:** Add to the Edit menu `edit.addItem(withTitle: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")` with `tag = NSTextFinder.Action.showFindInterface.rawValue`; if the field still doesn't focus, point the item at an AppDelegate action that does `(NSApp.keyWindow?.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first)?.beginSearchInteraction()`.

## MINOR 3 — An empty draft survives closing the window
**Location:** Task 8 `closed()`.
**Problem:** `closed()` only `leave()`s; `isDrafting` stays true and the "New Note" row is still there on reopen, contradicting "Leaving it empty discards it".
**Fix:** `func closed() async { if let message = await editor.leave() { errorMessage = message }; if isDrafting { isDrafting = false; editor.show(.none) } }` (a draft that got created has already cleared `isDrafting` via `draftCreated`).

## MINOR 4 — A refused save with typing meanwhile never re-arms the timer
**Location:** Task 7 `save()` (`return scheduler.refused()` in the blank-note and seed-only-draft branches).
**Problem:** `refused()` moves `.saving(editedMeanwhile: true)` to `.dirty(now)` but these two branches skip `armTimer()`, so the text waits for the next keystroke or a flush.
**Fix:** `if blank, note.images.isEmpty { scheduler.refused(); return armTimer() }` (same for the draft branch).

## MINOR 5 — `selectAll` sent to whoever is first responder
**Location:** Task 10 `FolderRow` rename `TextField.onAppear` (`NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)` on the next turn).
**Problem:** If focus hasn't moved yet, the action lands on the note editor's `NSTextView` and selects the whole note. An `NSTextField` selects its text when it becomes first responder anyway.
**Fix:** Delete the `DispatchQueue.main.async { … selectAll … }` block.

## MINOR 6 — `FolderNaming.key` re-implements the core's `name_key`
**Location:** Task 4 `FolderNaming.key`, `testTheKeyTrimsComposesAndFoldsCaseLikeTheCore`; Task 8 `newFolderInline` retry cap of 3.
**Problem:** §10: "Swift never re-implements the name rules (§3)". The core already answers `FOLDER_EXISTS`, and `newFolderInline` retries on it.
**Fix:** `newFolderName(existing:)` compares with `lowercased()` only (keep the "New Folder N" tests, drop the key test), and raise the retry loop to `0..<20` so the local guess is a hint, not a rule.

## MINOR 7 — YAGNI cuts (plan bloat)
**Location:** Task 9 `ActivationPolicyPlanner.swift` + tests; Task 1 Step 2 (`ReleaseAssumptionsCheck.swift`, deleted before commit); Task 8 `sorted(_:in:done:)`; Task 12 `NoteTextStyler.Palette.theme(for:)` + `PlainTextView.onAppearanceChange`; Task 11 `WindowToastBar`.
**Problem/Fix:** (a) The planner is six lines of policy; inline them in `updateActivationPolicy` (`let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory; guard wanted != NSApp.activationPolicy() …; if wanted == .accessory, settings.isOpen || notes.isOpen { reactivate }`) and drop the file, its test and the Task 9 Steps 1–4. (b) Task 9 compiles the same release 2 names; delete Step 2. (c) The core orders every list (`created_at_ms DESC`, `completed_at_ms DESC`, `deleted_at_ms DESC`, due `deadline_ms ASC`); drop `sorted` (and with paging it must not re-sort anyway). (d) `Theme` colours are already dynamic `NSColor(name:nil)` providers; expose `Theme.inkNS`/`rustNS` (the `NSColor` the `Color` wraps) and style with them — no appearance observer, no colour-space freezing. (e) Make the panel's `ToastBar` take `(message: String, undoable: Bool, undo:)` and reuse it instead of a second copy (keep the panel's ⌘Z binding behind a flag, false in the window). Net: ~250 lines and one task-step cluster less.

## MINOR 8 — Search field prompt
**Location:** Task 9 `.searchable(…, prompt: "Search")`.
**Problem:** Mockup §2 shows "Search all notes".
**Fix:** `prompt: "Search all notes"`.

## MINOR 9 — Plan header and Self-Review still describe the capped design
**Location:** Header line 19, Global Constraints, File Structure (`"200+" count label`), Self-Review "List (…)".
**Fix:** Update alongside B1/M1/M2 so an executor reading only the header gets the paged API, `noteCount` and `cancelReminder`.

## MINOR 10 — Tests that depend on wall-clock pauses
**Location:** Task 7 (`pause 0.4`, delay 0.05), Task 8 (`Task.sleep(300_000_000)`, `400_000_000`).
**Problem:** Known-flaky shape on a loaded CI/laptop; the plan admits it. Acceptable for now.
**Fix:** Where possible await the effect instead of sleeping: `await session.flush()` already exists; for timer paths poll `while session.hasUnsavedText { try await Task.sleep(nanoseconds: 10_000_000) }` with a 2 s bound.

---

### Checked and found sound (no finding)
- 0002: the plan never touches `PetPanel`; policy switching doesn't alter levels/collection behaviour.
- `applicationShouldTerminate` `.terminateLater` + `reply(toApplicationShouldTerminate:)`; SIGTERM path still goes through it.
- Dock reopen (`handleReopen` → `show()` deminiaturises); `isOpen` counts minimised windows.
- `ImageStrip`/`Thumbnails`/`NoteRow`/`CustomRemindPopover`/`SettingsWindowController`/`WindowReport`/`StatusMenuController`/`AppDelegate` Edit anchors all match the current files (release 2 leaves them intact).
- §12 copy and button roles; Keep Notes default; `delete_folder(id, keep_notes:)` mapping; empty folder passes `keepNotes: true`.
- `RalloError.code` pattern over the 3-value `IncompatibleSchema` case compiles.
- `NoteParts` title range in UTF-16 incl. CRLF and surrogate pairs; tag-in-title keeps title size.
- Save/flush/leave sequencing (`leave()` awaits the running save before `show()` switches notes).
- `sqlite3 "$RALLO_DATA_DIR/rallo.sqlite3"` and `diagnostics/events.jsonl` paths in the check steps are right.
