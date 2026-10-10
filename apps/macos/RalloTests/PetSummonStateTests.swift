import XCTest

/// 0021 §3, §8, §11: a summon borrows the pet panel, never its saved
/// placement or the user's Show/Hide choice.
final class PetSummonStateTests: XCTestCase {
    func testAVisiblePetGoesHomeAfterwards() {
        var state = PetSummonState()
        state.begin(panelVisible: true)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.end(), .returnHome)
        XCTAssertFalse(state.isActive)
    }

    func testAHiddenPetHidesAgainAndStillReadsAsHidden() {
        var state = PetSummonState()
        state.begin(panelVisible: false)
        XCTAssertFalse(state.isVisible(panelVisible: true), "the menu still offers Show Pet")
        XCTAssertEqual(state.end(), .hide)
    }

    func testShowOrHideDuringASummonWinsAtTheEnd() {
        var state = PetSummonState()
        state.begin(panelVisible: true)
        state.userSetVisible(false)
        XCTAssertEqual(state.end(), .hide)
        state.begin(panelVisible: false)
        state.userSetVisible(true)
        XCTAssertEqual(state.end(), .returnHome)
    }

    /// Review Focus 4.
    func testASummonNeverSavesADragOrFollowsPlacementChanges() {
        var state = PetSummonState()
        XCTAssertTrue(state.savesDrag)
        XCTAssertTrue(state.followsPlacement)
        state.begin(panelVisible: true)
        XCTAssertFalse(state.savesDrag)
        XCTAssertFalse(state.followsPlacement)
        _ = state.end()
        XCTAssertTrue(state.savesDrag)
        XCTAssertTrue(state.followsPlacement)
    }

    func testASecondBeginKeepsTheFirstAndEndingTwiceIsANoOp() {
        var state = PetSummonState()
        state.begin(panelVisible: false)
        state.begin(panelVisible: true)     // showing now only because of the summon
        XCTAssertEqual(state.end(), .hide)
        XCTAssertNil(state.end())
    }

    func testOutsideASummonVisibleIsThePanels() {
        let state = PetSummonState()
        XCTAssertTrue(state.isVisible(panelVisible: true))
        XCTAssertFalse(state.isVisible(panelVisible: false))
    }
}
