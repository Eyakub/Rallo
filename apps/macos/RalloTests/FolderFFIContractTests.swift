import XCTest

/// Release 1 (0019 §9) as Swift sees it. This file is the contract the
/// folders panel (release 2) compiles against; it creates no production code.
final class FolderFFIContractTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-folders-ffi-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testRecordsHavePublicMemberwiseInits() {
        let folder = FolderSnapshot(id: "f1", name: "Work", openCount: 5, noteCount: 7, revision: 1)
        let overview = FolderOverview(allOpen: 24, unfiledOpen: 12, due: 1, done: 2, deleted: 3, folders: [folder])
        XCTAssertEqual(overview.folders.first?.name, "Work")
        XCTAssertEqual(overview.unfiledOpen, 12)
        _ = TagSnapshot(name: "bug", openCount: 2)
        XCTAssertEqual(TagRange(utf16Start: 1, utf16Len: 4, name: "bug"), TagRange(utf16Start: 1, utf16Len: 4, name: "bug"))
        XCTAssertEqual(FolderScope.folder(id: "f1"), FolderScope.folder(id: "f1"))
        XCTAssertNotEqual(FolderScope.all, FolderScope.unfiled)
        _ = [ItemListKind.open, .done, .due, .deleted]
    }

    func testFoldersFilingMovingAndListing() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let work = try store.createFolder(name: "Work")
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(work.openCount, 0)

        let note = try store.createNoteWithImages(text: "Plan #bug", images: [], folderId: work.id)
        XCTAssertEqual(note.folderId, work.id)
        XCTAssertEqual(note.folderName, "Work")
        XCTAssertEqual(note.tags, ["bug"])
        let loose = try store.createNoteWithImages(text: "Loose", images: [], folderId: nil)
        XCTAssertNil(loose.folderId)
        XCTAssertNil(loose.folderName)

        let overview = try store.folderOverview()
        XCTAssertEqual(overview.allOpen, 2)
        XCTAssertEqual(overview.unfiledOpen, 1)
        XCTAssertEqual(overview.folders.map(\.name), ["Work"])
        XCTAssertEqual(overview.folders.first?.openCount, 1)

        XCTAssertEqual(try store.listItems(kind: .open, scope: .folder(id: work.id), tag: nil, limit: 50, cursor: nil).items.map(\.id), [note.id])
        XCTAssertEqual(try store.listItems(kind: .open, scope: .unfiled, tag: nil, limit: 50, cursor: nil).items.map(\.id), [loose.id])
        XCTAssertEqual(Set(try store.listItems(kind: .open, scope: .all, tag: nil, limit: 50, cursor: nil).items.map(\.id)), [note.id, loose.id])
        // The panel reads page 1 only; release 3 pages with the cursor.
        let page = try store.listItems(kind: .open, scope: .all, tag: nil, limit: 1, cursor: nil)
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertNotNil(page.nextCursor)

        let moved = try store.moveItem(id: note.id, folderId: nil, ifRevision: note.revision)
        XCTAssertNil(moved.folderId)
        XCTAssertGreaterThan(moved.revision, note.revision)

        XCTAssertEqual(try store.renameFolder(id: work.id, name: "Work 2").name, "Work 2")
        XCTAssertEqual(try store.listTags().map(\.name), ["bug"])
        XCTAssertEqual(try store.searchItems(query: "plan", limit: 10, cursor: nil).items.map(\.id), [note.id])
        let deleted = try store.deleteFolder(id: work.id, keepNotes: true)
        XCTAssertEqual(deleted.moved, 0)

        // Referenced so a missing label or parameter fails the build.
        _ = store.createReminderWithImages(text:when:images:folderId:)
        _ = store.cancelReminder(id:ifRevision:)   // release 3 consumes it; pinned here too
    }

    func testFolderErrorsMapToTheRalloErrorCases() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let work = try store.createFolder(name: "Work")
        XCTAssertThrowsError(try store.createFolder(name: "notes")) { error in
            guard case let RalloError.InvalidInput(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "FOLDER_NAME_INVALID")
        }
        XCTAssertThrowsError(try store.createFolder(name: "work")) { error in
            guard case let RalloError.Conflict(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "FOLDER_EXISTS")
        }
        let note = try store.createNoteWithImages(text: "x", images: [], folderId: work.id)
        XCTAssertThrowsError(try store.moveItem(id: note.id, folderId: "no-such-folder", ifRevision: nil)) { error in
            guard case let RalloError.NotFound(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "FOLDER_NOT_FOUND")
        }
    }

    /// Offsets are UTF-16 and cover the `#`; a trailing `-` is not part of the tag.
    func testTagRangesCoverTheHashInUTF16() {
        XCTAssertEqual(tagRanges(text: "fix #Bug- now"), [TagRange(utf16Start: 4, utf16Len: 4, name: "bug")])
        XCTAssertEqual(tagRanges(text: "🦊 #bug"), [TagRange(utf16Start: 3, utf16Len: 4, name: "bug")])
        XCTAssertEqual(tagRanges(text: "কাজ #কাজ"), [TagRange(utf16Start: 4, utf16Len: 4, name: "কাজ")])
        XCTAssertEqual(tagRanges(text: "Review PR #482, C#, a#b"), [])
    }
}
