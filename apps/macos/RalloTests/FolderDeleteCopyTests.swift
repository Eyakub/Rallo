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
