import XCTest

final class VoiceKeyGestureTests: XCTestCase {
    private var g = VoiceKeyGesture()

    override func setUp() { g = VoiceKeyGesture() }

    private func down(_ t: TimeInterval, listening: Bool = false, hold: Bool = true, doubleTap: Bool = true) -> VoiceKeyAction? {
        g.keyDown(at: t, listening: listening, hold: hold, doubleTap: doubleTap)
    }

    func testHoldStartsAtDeadlineAndEndsOnRelease() {
        XCTAssertNil(down(0))
        XCTAssertEqual(g.holdDeadline(at: 0.3), .startHold)
        XCTAssertEqual(g.keyUp(at: 2), .endHold)
    }

    func testQuickTapDoesNothing() {
        XCTAssertNil(down(0))
        XCTAssertNil(g.keyUp(at: 0.1))
        XCTAssertNil(g.holdDeadline(at: 0.3))
    }

    func testDoubleTapStartsHandsFree() {
        XCTAssertNil(down(0))
        XCTAssertNil(g.keyUp(at: 0.1))
        XCTAssertEqual(down(0.5), .startHandsFree)
        XCTAssertNil(g.holdDeadline(at: 0.8))
        XCTAssertNil(g.keyUp(at: 1.0))
    }

    func testSecondPressTooLateDoesNothingButCanBeginNewDoubleTap() {
        XCTAssertNil(down(0))
        XCTAssertNil(g.keyUp(at: 0.1))
        XCTAssertNil(down(0.7))
        XCTAssertNil(g.keyUp(at: 0.8))
        XCTAssertEqual(down(1.0), .startHandsFree)
    }

    func testPressWhileListeningStopsAndItsReleaseDoesNothing() {
        XCTAssertEqual(down(0, listening: true), .stop)
        XCTAssertNil(g.holdDeadline(at: 0.3))
        XCTAssertNil(g.keyUp(at: 0.1))
        // The stopping press's release is not half of a double-tap.
        XCTAssertNil(down(0.2))
        XCTAssertNil(g.keyUp(at: 0.25))
    }

    func testOtherModifierCancelsPendingPress() {
        XCTAssertNil(down(0))
        g.otherModifierChanged()
        XCTAssertNil(g.holdDeadline(at: 0.3))
        XCTAssertNil(g.keyUp(at: 0.4))
        // No tap was counted either.
        XCTAssertNil(down(0.5))
    }

    func testOtherModifierDuringQuickTapCancelsTap() {
        XCTAssertNil(down(0))
        g.otherModifierChanged()
        XCTAssertNil(g.keyUp(at: 0.1))
        XCTAssertNil(down(0.2))
    }

    func testHoldDisabledLongPressDoesNothingAndIsNotATap() {
        XCTAssertNil(down(0, hold: false))
        XCTAssertNil(g.holdDeadline(at: 0.3))
        XCTAssertNil(g.keyUp(at: 1))
        XCTAssertNil(down(1.1, hold: false))
    }

    func testDoubleTapDisabledNeverStartsHandsFree() {
        XCTAssertNil(down(0, doubleTap: false))
        XCTAssertNil(g.keyUp(at: 0.1))
        XCTAssertNil(down(0.3, doubleTap: false))
    }

    func testDeadlineAfterReleaseDoesNothing() {
        XCTAssertNil(down(0))
        XCTAssertNil(g.keyUp(at: 0.1))
        XCTAssertNil(g.holdDeadline(at: 0.3))
    }
}
