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
