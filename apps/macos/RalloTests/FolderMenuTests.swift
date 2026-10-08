import XCTest

/// 0019 §10: the chip menu and the Move menu list the same folders in the
/// order the core gave (alphabetical), mark the current choice, and never
/// re-sort.
final class FolderMenuTests: XCTestCase {
    private let folders = [testFolder("i", "Ideas", open: 4), testFolder("p", "Personal", open: 3), testFolder("w", "Work", open: 5)]
    private var overview: FolderOverview { testOverview(all: 24, unfiled: 12, folders: folders) }

    func testChipMenuOrderAndCounts() {
        let items = FolderMenus.scopeItems(current: .all, overview: overview)
        XCTAssertEqual(items.map(\.title), ["All Notes (24)", "Notes (12)", "Ideas (4)", "Personal (3)", "Work (5)"])
        XCTAssertEqual(items.map(\.scope), [.all, .unfiled, .folder("i"), .folder("p"), .folder("w")])
    }

    func testChipMenuChecksExactlyTheCurrentScope() {
        func checked(_ scope: NotesScope) -> [String] {
            FolderMenus.scopeItems(current: scope, overview: overview).filter(\.checked).map(\.title)
        }
        XCTAssertEqual(checked(.all), ["All Notes (24)"])
        XCTAssertEqual(checked(.unfiled), ["Notes (12)"])
        XCTAssertEqual(checked(.folder("p")), ["Personal (3)"])
        XCTAssertEqual(checked(.folder("gone")), ["All Notes (24)"], "a vanished folder checks its fallback")
    }

    func testMoveMenuListsNotesThenFoldersInGivenOrder() {
        let items = FolderMenus.moveItems(currentFolderID: nil, folders: folders)
        XCTAssertEqual(items.map(\.title), ["Notes", "Ideas", "Personal", "Work"])
        XCTAssertEqual(items.map(\.folderID), [nil, "i", "p", "w"])
    }

    func testMoveMenuChecksTheCurrentFolder() {
        func checked(_ id: String?) -> [String] {
            FolderMenus.moveItems(currentFolderID: id, folders: folders).filter(\.checked).map(\.title)
        }
        XCTAssertEqual(checked(nil), ["Notes"])
        XCTAssertEqual(checked("w"), ["Work"])
        XCTAssertEqual(checked("gone"), [], "a note whose folder just vanished has no checked row")
    }

    func testMoveMenuKeepsUnicodeNamesUntouched() {
        let items = FolderMenus.moveItems(currentFolderID: "b", folders: [testFolder("b", "কাজ 🦊")])
        XCTAssertEqual(items.map(\.title), ["Notes", "কাজ 🦊"])
        XCTAssertEqual(items.last?.checked, true)
    }
}
