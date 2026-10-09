import XCTest

final class SaveSchedulerTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private let clock = Clock()

    private func scheduler() -> SaveScheduler {
        SaveScheduler(delay: 0.6, now: { [clock] in clock.now })
    }

    func testASaveFallsDueSixTenthsAfterTheLastKeystroke() {
        var scheduler = scheduler()
        XCTAssertFalse(scheduler.hasUnsavedText)
        scheduler.edited()
        clock.advance(0.5)
        XCTAssertFalse(scheduler.takeDue())
        scheduler.edited()  // typing again pushes the deadline out
        clock.advance(0.5)
        XCTAssertFalse(scheduler.takeDue())
        clock.advance(0.1)
        XCTAssertTrue(scheduler.takeDue())
        XCTAssertEqual(scheduler.phase, .saving(editedMeanwhile: false))
        XCTAssertNil(scheduler.dueAt)
    }

    func testFlushSavesRightAwayOnlyWhenSomethingIsPending() {
        var scheduler = scheduler()
        XCTAssertFalse(scheduler.takeFlush())
        scheduler.edited()
        XCTAssertTrue(scheduler.takeFlush())
        XCTAssertFalse(scheduler.takeFlush(), "already saving")
    }

    func testTypingDuringASaveSavesAgainAfterIt() {
        var scheduler = scheduler()
        scheduler.edited()
        XCTAssertTrue(scheduler.takeFlush())
        scheduler.edited()
        XCTAssertEqual(scheduler.phase, .saving(editedMeanwhile: true))
        scheduler.saved()
        XCTAssertEqual(scheduler.phase, .dirty(lastEdit: clock.now))
        XCTAssertEqual(scheduler.dueAt, clock.now.addingTimeInterval(0.6))
        XCTAssertTrue(scheduler.hasUnsavedText)
    }

    func testASaveWithNoMoreTypingEndsClean() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.saved()
        XCTAssertEqual(scheduler.phase, .clean)
    }

    func testARefusedSaveWaitsForTheNextKeystroke() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.refused()
        XCTAssertEqual(scheduler.phase, .held)
        XCTAssertTrue(scheduler.hasUnsavedText)
        clock.advance(10)
        XCTAssertFalse(scheduler.takeDue(), "a refused save is not retried on a timer")
        scheduler.edited()
        XCTAssertEqual(scheduler.phase, .dirty(lastEdit: clock.now))
    }

    func testARefusalWithTypingMeanwhileTriesAgainOnTheNewText() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.edited()
        scheduler.refused()
        XCTAssertEqual(scheduler.phase, .dirty(lastEdit: clock.now))
    }

    func testAConflictSavesNothingUntilTheBarIsAnswered() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.conflicted()
        scheduler.edited()
        clock.advance(5)
        XCTAssertEqual(scheduler.phase, .conflict)
        XCTAssertFalse(scheduler.takeDue())
        XCTAssertFalse(scheduler.takeFlush())
        scheduler.keepMine()  // Keep Mine: due at once
        XCTAssertTrue(scheduler.takeDue())
    }

    func testShowTheirsAndLeavingGoBackToClean() {
        var scheduler = scheduler()
        scheduler.edited()
        _ = scheduler.takeFlush()
        scheduler.conflicted()
        scheduler.reset()
        XCTAssertEqual(scheduler.phase, .clean)
        XCTAssertFalse(scheduler.hasUnsavedText)
    }

    func testKeepMineOutsideAConflictDoesNothing() {
        var scheduler = scheduler()
        scheduler.keepMine()
        XCTAssertEqual(scheduler.phase, .clean)
    }
}
