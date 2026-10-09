import XCTest

final class SidebarOrderTests: XCTestCase {
    private let rows = SidebarOrder.rows(folderIDs: ["a", "b"], tagNames: ["x"])

    func testOrderIsNotesFoldersViewsTags() {
        XCTAssertEqual(rows, [
            .scope(.unfiled), .scope(.folder("a")), .scope(.folder("b")),
            .scope(.all), .due, .done, .deleted, .tag("x"),
        ])
    }

    func testMovesThroughTheMiddle() {
        XCTAssertEqual(SidebarOrder.next(after: .scope(.folder("b")), in: rows, direction: .down), .scope(.all))
        XCTAssertEqual(SidebarOrder.next(after: .scope(.folder("b")), in: rows, direction: .up), .scope(.folder("a")))
    }

    func testStopsAtTheEnds() {
        XCTAssertNil(SidebarOrder.next(after: .scope(.unfiled), in: rows, direction: .up))
        XCTAssertNil(SidebarOrder.next(after: .tag("x"), in: rows, direction: .down))
    }

    func testMissingCurrentEntersFromTheMatchingEnd() {
        XCTAssertEqual(SidebarOrder.next(after: .tag("gone"), in: rows, direction: .down), .scope(.unfiled))
        XCTAssertEqual(SidebarOrder.next(after: nil, in: rows, direction: .up), .tag("x"))
        XCTAssertNil(SidebarOrder.next(after: nil, in: [], direction: .down))
    }
}
