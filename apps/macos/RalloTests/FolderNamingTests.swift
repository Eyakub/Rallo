import XCTest

final class FolderNamingTests: XCTestCase {
    func testTheFirstFreeNewFolderName() {
        XCTAssertEqual(FolderNaming.newFolderName(existing: []), "New Folder")
        XCTAssertEqual(FolderNaming.newFolderName(existing: ["Work", "Ideas"]), "New Folder")
        XCTAssertEqual(FolderNaming.newFolderName(existing: ["Work", "new folder"]), "New Folder 2", "case does not matter")
        XCTAssertEqual(FolderNaming.newFolderName(existing: ["New Folder", "New Folder 2", "NEW FOLDER 4"]), "New Folder 3")
    }
}
