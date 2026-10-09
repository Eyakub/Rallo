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
