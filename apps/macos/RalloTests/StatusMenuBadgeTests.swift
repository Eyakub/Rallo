import XCTest

@MainActor
final class StatusMenuBadgeTests: XCTestCase {
    func testBadgedPawKeepsHeightAndIsTemplate() throws {
        let plain = try XCTUnwrap(StatusMenuController.pawImage(updateAvailable: false))
        let badged = try XCTUnwrap(StatusMenuController.pawImage(updateAvailable: true))
        XCTAssertTrue(badged.isTemplate)
        XCTAssertEqual(badged.size.height, plain.size.height)
        XCTAssertGreaterThanOrEqual(badged.size.width, plain.size.width)
    }
}
