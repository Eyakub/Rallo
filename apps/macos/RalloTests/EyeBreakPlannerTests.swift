import XCTest

/// The 20-20-20 cycle (0022 §2-§7) as a pure value, on an injected clock.
final class EyeBreakPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let free = EyeBreakPlanner.Hold()
    private let onCall = EyeBreakPlanner.Hold(callActive: true)
    private let bubble = EyeBreakPlanner.Hold(bubbleVisible: true)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Enabled, 20 min / 20 s / 10 s warning, skipping allowed, hold on call.
    private func planner(_ edit: (inout EyeBreakPlanner.Settings) -> Void = { _ in }) -> EyeBreakPlanner {
        var settings = EyeBreakPlanner.Settings(enabled: true, interval: 1200, length: 20, warning: 10,
                                                allowSkip: true, holdOnCall: true)
        edit(&settings)
        return EyeBreakPlanner(settings: settings, now: t0)
    }

    // MARK: Counting

    func testOffByDefaultNothingHappens() {
        var p = EyeBreakPlanner(settings: .init(), now: t0)
        XCTAssertEqual(p.phase, .off)
        XCTAssertNil(p.nextCheck(now: t0))
        p.tick(now: at(5000), idle: 0, hold: free)
        p.startNow(at(5000))
        XCTAssertEqual(p.phase, .off)
    }

    func testCountingReachesTheWarningThenTheBreakThenANewCycle() {
        var p = planner()
        XCTAssertEqual(p.nextCheck(now: t0), at(60), "never more than a minute between ticks")
        XCTAssertEqual(p.nextCheck(now: at(1170)), at(1190))
        p.tick(now: at(1189), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        p.tick(now: at(1190), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1200)))
        XCTAssertEqual(p.nextCheck(now: at(1190)), at(1200))
        p.tick(now: at(1200), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .breaking(until: at(1220)))
        p.tick(now: at(1220), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.cycleStart, at(1220))
        XCTAssertEqual(p.breaksTaken, 1)
        XCTAssertEqual(p.tip, "Blink slowly", "the tip rotates each break")
    }

    func testIdleFiveMinutesRestartsTheCycleWhenTheUserIsBack() {
        var p = planner()
        p.tick(now: at(600), idle: 300, hold: free)
        XCTAssertTrue(p.awaitingReturn)
        p.tick(now: at(1190), idle: 890, hold: free)
        XCTAssertEqual(p.phase, .counting, "no warning while the user is away from the keyboard")
        p.tick(now: at(1250), idle: 20, hold: free)
        XCTAssertFalse(p.awaitingReturn)
        XCTAssertEqual(p.cycleStart, at(1230), "the cycle starts when input came back")
        XCTAssertEqual(p.breakDue, at(2430))
    }

    func testIdleUnderFiveMinutesDoesNotRestart() {
        var p = planner()
        p.tick(now: at(600), idle: 299, hold: free)
        XCTAssertFalse(p.awaitingReturn)
        p.tick(now: at(1190), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1200)))
    }

    func testLockOrSleepPausesAndUnlockStartsAFreshCycle() {
        let counting = planner()
        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: free)
        var breaking = planner()
        breaking.startNow(at(1190))
        for (name, start) in [("counting", counting), ("warning", warning), ("breaking", breaking)] {
            var p = start
            p.setScreenAvailable(false, now: at(1195))
            XCTAssertEqual(p.phase, .away, name)
            XCTAssertNil(p.nextCheck(now: at(1195)), name)
            p.tick(now: at(6000), idle: 0, hold: free)
            XCTAssertEqual(p.phase, .away, name)
            p.setScreenAvailable(true, now: at(6000))
            XCTAssertEqual(p.phase, .counting, name)
            XCTAssertEqual(p.breakDue, at(7200), "\(name): a full fresh cycle, never an instant break")
        }
    }

    func testWarningOffGoesStraightToTheBreak() {
        var p = planner { $0.warning = 0 }
        p.tick(now: at(1200), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .breaking(until: at(1220)))
    }

    // MARK: User actions

    func testStartNowBeginsTheBreakAtOnce() {
        var counting = planner()
        counting.startNow(at(100))
        XCTAssertEqual(counting.phase, .breaking(until: at(120)))

        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: free)
        warning.startNow(at(1192))
        XCTAssertEqual(warning.phase, .breaking(until: at(1212)))

        var paused = planner()
        paused.pause(until: at(3600), now: at(100))
        paused.startNow(at(200))
        XCTAssertEqual(paused.phase, .breaking(until: at(220)))

        var away = planner()
        away.setScreenAvailable(false, now: at(10))
        away.startNow(at(20))
        XCTAssertEqual(away.phase, .away)
    }

    func testPostponeBringsTheWarningBackInFiveMinutes() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: free)
        XCTAssertTrue(p.postpone(at(1195)))
        XCTAssertEqual(p.phase, .counting)
        p.tick(now: at(1494), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        p.tick(now: at(1495), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1505)))

        var breaking = planner()
        breaking.startNow(at(100))
        XCTAssertTrue(breaking.postpone(at(105)))
        XCTAssertEqual(breaking.phase, .counting)
        XCTAssertEqual(breaking.breakDue, at(415))
        XCTAssertEqual(breaking.breaksTaken, 0)
    }

    func testSkipCountsAsABreakTaken() {
        var p = planner()
        p.startNow(at(100))
        XCTAssertTrue(p.skip(at(103)))
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.breaksTaken, 1)
        XCTAssertEqual(p.breakDue, at(1303), "next in a full cycle")
    }

    func testStrictModeKeepsThePillButtonsButNoEscEndsTheBreak() {
        var warning = planner { $0.allowSkip = false }
        warning.tick(now: at(1190), idle: 0, hold: free)
        var skipped = warning
        XCTAssertTrue(skipped.skip(at(1192)), "the pill's Skip works in strict mode (0022 §4)")
        XCTAssertEqual(skipped.phase, .counting)
        XCTAssertEqual(skipped.breaksTaken, 1)
        XCTAssertTrue(warning.postpone(at(1192)), "so does +5 min")
        XCTAssertEqual(warning.phase, .counting)

        var p = planner { $0.allowSkip = false }
        p.startNow(at(100))
        XCTAssertFalse(p.skip(at(101)), "a short Esc does nothing in strict mode")
        XCTAssertFalse(p.postpone(at(101)))
        XCTAssertEqual(p.phase, .breaking(until: at(120)))
        p.escHeld(at(104))
        XCTAssertEqual(p.phase, .breaking(until: at(120)), "a held Esc does nothing either")
        p.tick(now: at(120), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting, "only the countdown ends it")
        XCTAssertEqual(p.breaksTaken, 1)
    }

    func testTheCountdownAlwaysEndsTheBreak() {
        for hold in [free, onCall, bubble, EyeBreakPlanner.Hold(callActive: true, bubbleVisible: true)] {
            var p = planner { $0.allowSkip = false }
            p.startNow(at(100))
            p.tick(now: at(110), idle: 400, hold: hold)
            XCTAssertEqual(p.phase, .breaking(until: at(120)), "\(hold)")
            p.tick(now: at(120), idle: 400, hold: hold)
            XCTAssertEqual(p.phase, .counting, "\(hold)")
        }
    }

    // MARK: Holds

    func testACallHoldsTheBreakUntilItEnds() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .held)
        XCTAssertEqual(p.nextCheck(now: at(1190)), at(1250))
        p.tick(now: at(1250), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .held)
        p.tick(now: at(1310), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1320)), "the warning starts once the call is over")
    }

    func testACallStartingDuringTheWarningCancelsIt() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: free)
        p.tick(now: at(1195), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .held)
    }

    func testHoldOnCallOffIgnoresTheCall() {
        var p = planner { $0.holdOnCall = false }
        p.tick(now: at(1190), idle: 0, hold: onCall)
        XCTAssertEqual(p.phase, .warning(until: at(1200)))
    }

    func testABubbleOnScreenHoldsTheBreakUntilItCloses() {
        var p = planner { $0.holdOnCall = false }
        p.tick(now: at(1190), idle: 0, hold: bubble)
        XCTAssertEqual(p.phase, .held)
        p.tick(now: at(1215), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .warning(until: at(1225)))
    }

    func testABubbleAppearingMidBreakNeitherEndsNorExtendsIt() {
        var p = planner()
        p.startNow(at(100))
        p.tick(now: at(110), idle: 0, hold: bubble)
        XCTAssertEqual(p.phase, .breaking(until: at(120)))
        XCTAssertEqual(p.nextCheck(now: at(110)), at(120))
    }

    func testIdleWhileHeldIsANaturalBreak() {
        var p = planner()
        p.tick(now: at(1190), idle: 0, hold: onCall)
        p.tick(now: at(1550), idle: 330, hold: onCall)
        XCTAssertEqual(p.phase, .counting)
        XCTAssertTrue(p.awaitingReturn)
    }

    // MARK: Pause, settings, clock

    func testPauseUntilATimeThenAFreshCycle() {
        var p = planner()
        p.pause(until: at(1800), now: at(100))
        XCTAssertEqual(p.phase, .paused(until: at(1800)))
        XCTAssertEqual(p.nextCheck(now: at(1790)), at(1800))
        p.tick(now: at(1799), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .paused(until: at(1800)))
        p.tick(now: at(1800), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.breakDue, at(3000))
    }

    func testChangingTheIntervalRestartsTheCycleAndOtherChangesDoNot() {
        var p = planner()
        var settings = p.settings
        settings.length = 60
        p.apply(settings, now: at(600))
        XCTAssertEqual(p.cycleStart, t0, "a new length doesn't restart the cycle")
        settings.interval = 1800
        p.apply(settings, now: at(700))
        XCTAssertEqual(p.cycleStart, at(700))
        XCTAssertEqual(p.breakDue, at(2500))
    }

    func testTurningOffEndsEverythingAndTurningOnStartsFresh() {
        var p = planner()
        p.startNow(at(100))
        var settings = p.settings
        settings.enabled = false
        p.apply(settings, now: at(105))
        XCTAssertEqual(p.phase, .off)
        settings.enabled = true
        p.apply(settings, now: at(500))
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.breakDue, at(1700))
    }

    func testALateTickNeverShortensTheWarningOrShowsAnExpiredBreak() {
        var late = planner()
        late.tick(now: at(1800), idle: 0, hold: free)      // timer 10 min late
        XCTAssertEqual(late.phase, .warning(until: at(1810)), "the full warning, not an instant break")
        late.tick(now: at(2400), idle: 0, hold: free)      // late again
        XCTAssertEqual(late.phase, .breaking(until: at(2420)), "a full break, never one that already ended")
        late.tick(now: at(9000), idle: 0, hold: free)
        XCTAssertEqual(late.phase, .counting)

        // The clock moved back by an hour mid-break: the break still lasts at most its length.
        var back = planner()
        back.startNow(at(5000))
        back.tick(now: at(1400), idle: 0, hold: free)
        XCTAssertEqual(back.phase, .counting)
        XCTAssertEqual(back.cycleStart, at(1400))
    }

    // MARK: Menu status, settings from the preference

    func testMenuStatus() {
        var p = planner()
        XCTAssertEqual(p.menuStatus(now: at(446)), .due(in: 754))
        p.tick(now: at(1190), idle: 0, hold: onCall)
        XCTAssertEqual(p.menuStatus(now: at(1190)), .waiting)
        p.pause(until: at(4000), now: at(1200))
        XCTAssertEqual(p.menuStatus(now: at(1200)), .paused(until: at(4000)))
        XCTAssertEqual(EyeBreakPlanner(settings: .init(), now: t0).menuStatus(now: t0), .off)
    }

    func testSettingsFromThePreferenceAndTheScratchOnlyOverride() {
        let stored = EyeBreakSettings(enabled: true, intervalMinutes: 30, lengthSeconds: 60, warnSeconds: 0,
                                      allowSkip: false, holdOnCall: false)
        XCTAssertEqual(EyeBreakPlanner.Settings(stored),
                       .init(enabled: true, interval: 1800, length: 60, warning: 0, allowSkip: false, holdOnCall: false))
        XCTAssertEqual(EyeBreakPlanner.Settings(stored, intervalOverride: 40).interval, 40)

        let env = ["RALLO_EYE_BREAK_SECONDS": "40"]
        XCTAssertEqual(EyeBreakPlanner.Settings.intervalOverride(environment: env, isScratch: true), 40)
        XCTAssertNil(EyeBreakPlanner.Settings.intervalOverride(environment: env, isScratch: false), "the installed app can't be sped up")
        XCTAssertNil(EyeBreakPlanner.Settings.intervalOverride(environment: ["RALLO_EYE_BREAK_SECONDS": "5"], isScratch: true))
        XCTAssertNil(EyeBreakPlanner.Settings.intervalOverride(environment: [:], isScratch: true))
    }

    // MARK: Screen availability outlives the phase

    func testAPauseThatExpiresWhileLockedGoesAwayThenUnlockStartsAFreshCycle() {
        var p = planner()
        p.pause(until: at(600), now: at(10))
        p.setScreenAvailable(false, now: at(100))
        XCTAssertEqual(p.phase, .paused(until: at(600)), "the pause still runs while locked")
        p.tick(now: at(600), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .away, "nothing counts while locked")
        XCTAssertNil(p.nextCheck(now: at(600)))
        p.setScreenAvailable(true, now: at(900))
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.cycleStart, at(900))
    }

    func testUnlockDuringAPauseKeepsThePause() {
        var p = planner()
        p.pause(until: at(600), now: at(10))
        p.setScreenAvailable(false, now: at(100))
        p.setScreenAvailable(true, now: at(200))
        XCTAssertEqual(p.phase, .paused(until: at(600)))
        p.tick(now: at(600), idle: 0, hold: free)
        XCTAssertEqual(p.phase, .counting)
    }

    func testTurningOnWhileLockedWaitsAwayUntilUnlock() {
        var p = EyeBreakPlanner(settings: .init(), now: t0)
        p.setScreenAvailable(false, now: at(5))
        var on = p.settings
        on.enabled = true
        p.apply(on, now: at(10))
        XCTAssertEqual(p.phase, .away)
        p.setScreenAvailable(true, now: at(50))
        XCTAssertEqual(p.phase, .counting)
        XCTAssertEqual(p.cycleStart, at(50))
    }
}
