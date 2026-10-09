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

    func testItemReadsOneNoteByIDEvenWhenDeleted() async throws {
        let note = try await core.createNote("Find me", images: [], folderID: nil)
        let found = try await core.item(note.id)
        XCTAssertEqual(found.text, "Find me")
        _ = try await core.deleteItem(found)
        let deleted = try await core.item(note.id)
        XCTAssertNotNil(deleted.deletedAtMs)
        do {
            _ = try await core.item(UUID().uuidString.lowercased())
            XCTFail("an unknown id is NotFound")
        } catch let error as RalloError {
            guard case .NotFound = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
