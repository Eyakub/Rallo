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

    /// Loading the done list must not block loading the open list (the dedupe is per list).
    func testLoadingTheDoneListDoesNotBlockTheOpenList() async throws {
        model = NotesWindowModel(core: core, saveDelay: 0.05, pageSize: 2)
        let made = try await notes(6)
        for item in made.prefix(3) { _ = try other.completeItem(id: item.id, ifRevision: nil) }
        await model.reload()
        XCTAssertTrue(model.open.hasMore)
        XCTAssertTrue(model.done.hasMore)
        async let moreDone: Void = model.loadMore(done: true)
        async let moreOpen: Void = model.loadMore()
        _ = await (moreDone, moreOpen)
        XCTAssertEqual(model.open.items.count, 3)
        XCTAssertEqual(model.done.items.count, 3)
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

    func testSwitchingNotesRightAfterAChangeElsewhereStaysOnTheBar() async throws {
        let first = try note("First")
        let second = try note("Second")
        await model.reload()
        await model.selectNote(first.id)
        _ = try other.editItemText(id: first.id, text: "theirs", ifRevision: nil)
        model.editor.textChanged("mine")
        await model.selectNote(second.id)
        XCTAssertEqual(model.selectedNoteID, first.id)
        XCTAssertTrue(model.editor.conflict)
        XCTAssertEqual(model.editor.text, "mine")
        await model.showTheirs()
        await model.selectNote(second.id)
        XCTAssertEqual(model.selectedNoteID, second.id)
    }

    // MARK: A row leaving the list keeps the open note (fix round 1)

    func testANoteWhoseTagIsEditedOutStaysOpenInTheTagScope() async throws {
        let tagged = try note("a #bug")
        try note("b #bug")  // keeps the tag, so the scope stays
        await model.select(.tag("bug"))
        await model.selectNote(tagged.id)
        model.editor.textChanged("a #auth")
        await model.editor.flush()
        await eventually { model.items.count == 1 }
        XCTAssertEqual(model.items.map(\.text), ["b #bug"], "the row left the #bug list")
        XCTAssertEqual(model.selection, .tag("bug"))
        XCTAssertEqual(model.selectedNoteID, tagged.id)
        XCTAssertEqual(model.editor.note?.id, tagged.id)
        XCTAssertEqual(model.selectedItem?.id, tagged.id)
        model.editor.textChanged("a #auth more")
        XCTAssertEqual(model.editor.text, "a #auth more")
        await model.editor.flush()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(try other.listOpenItems(limit: 50).contains { $0.text == "a #auth more" })
    }

    func testASearchResultEditedToNoLongerMatchStaysOpen() async throws {
        let item = try note("budget plan")
        model.query = "budget"
        await model.reload()
        await model.selectNote(item.id)
        model.editor.textChanged("plan")
        await model.editor.flush()
        await eventually { model.results.isEmpty }
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.selectedNoteID, item.id)
        XCTAssertEqual(model.editor.note?.id, item.id)
    }

    func testANoteMovedAwayElsewhereKeepsTheTypingAndRaisesTheConflictBar() async throws {
        let work = try folder("Work")
        let item = try note("v1", in: work)
        await model.select(.scope(.folder(work.id)))
        await model.selectNote(item.id)
        _ = try other.moveItem(id: item.id, folderId: nil, ifRevision: nil)
        model.editor.textChanged("mine")
        await model.reload()
        XCTAssertEqual(model.selectedNoteID, item.id, "unsaved typing is never dropped by a reload")
        XCTAssertEqual(model.editor.text, "mine")
        await model.editor.flush()
        XCTAssertTrue(model.editor.conflict)
        XCTAssertEqual(model.editor.text, "mine")
    }

    // MARK: Undo on the latest revision (fix round 1)

    func testUndoMarkAsDoneAfterTypingAndSavingReopensWithoutAnError() async throws {
        let item = try note("Finish me")
        await model.reload()
        await model.selectNote(item.id)
        await model.toggleDone(item)
        model.editor.textChanged("Finish me, typed")
        await model.editor.flush()
        await model.undo()
        XCTAssertNil(model.errorMessage)
        let stored = try XCTUnwrap(other.listOpenItems(limit: 50).first)
        XCTAssertEqual(stored.text, "Finish me, typed")
    }

    func testUndoMoveAfterTypingAndSavingMovesBackWithoutAnError() async throws {
        let work = try folder("Work")
        let item = try note("Move me")
        await model.reload()
        await model.selectNote(item.id)
        await model.move(item, toFolder: work.id)
        model.editor.textChanged("Move me, typed")
        await model.editor.flush()
        await model.undo()
        XCTAssertNil(model.errorMessage)
        let stored = try XCTUnwrap(other.listOpenItems(limit: 50).first)
        XCTAssertEqual(stored.text, "Move me, typed")
        XCTAssertNil(stored.folderId)
    }

    func testUndoMoveBeforeTheTypingSavesDoesNotConflictWithIt() async throws {
        let work = try folder("Work")
        let item = try note("v1")
        await model.reload()
        await model.selectNote(item.id)
        await model.move(item, toFolder: work.id)
        model.editor.textChanged("v2")
        await model.undo()
        await model.editor.flush()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.editor.conflict)
        let stored = try XCTUnwrap(other.listOpenItems(limit: 50).first)
        XCTAssertEqual(stored.text, "v2")
        XCTAssertNil(stored.folderId)
    }

    /// Round 2: a lookup of the note that left the list must not close the note picked meanwhile.
    /// The interleaving can't be forced without hooks (the guard is what's pinned: whichever order
    /// the two run in, the picked note and its typing survive), so this test never depends on timing.
    func testALateLookupNeverClosesTheNotePickedMeanwhile() async throws {
        let a = try note("A")
        let b = try note("B")
        await model.reload()
        await model.selectNote(a.id)
        _ = try other.deleteItem(id: a.id, ifRevision: nil)
        let reload = Task { await model.reload() }
        await model.selectNote(b.id)
        model.editor.textChanged("B typed")
        await reload.value
        await model.reload()
        XCTAssertEqual(model.selectedNoteID, b.id)
        XCTAssertEqual(model.editor.note?.id, b.id)
        XCTAssertEqual(model.editor.text, "B typed")
    }
}
