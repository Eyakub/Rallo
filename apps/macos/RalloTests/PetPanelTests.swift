import XCTest

@MainActor
final class PetPanelTests: XCTestCase {
    func testPetStaysWhenRalloIsHidden() {
        let panel = PetPanel()
        XCTAssertFalse(panel.canHide)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }
}
