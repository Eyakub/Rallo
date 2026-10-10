import XCTest

/// What the controller does on each change of phase, and the eye-break copy (0022 §3-§7).
final class EyeBreakEffectsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func planner(allowSkip: Bool = true) -> EyeBreakPlanner {
        EyeBreakPlanner(settings: .init(enabled: true, interval: 1200, length: 20, warning: 10,
                                        allowSkip: allowSkip, holdOnCall: true), now: t0)
    }

    private func breaking(allowSkip: Bool = false) -> EyeBreakPlanner {
        var p = planner(allowSkip: allowSkip)
        p.startNow(at(100))
        return p
    }

    // MARK: Effects

    func testTheWarningShowsThePillAndNudgesThePetThenTheBreakReplacesIt() {
        let counting = planner()
        var warning = counting
        warning.tick(now: at(1190), idle: 0, hold: .init())
        XCTAssertEqual(EyeBreakEffects.between(counting, warning), [.nudgePet(true), .showPill(until: at(1200))])
        var breaking = warning
        breaking.tick(now: at(1200), idle: 0, hold: .init())
        XCTAssertEqual(EyeBreakEffects.between(warning, breaking),
                       [.hidePill, .nudgePet(false), .showOverlay(until: at(1220))], "the pill goes before the overlay comes")
    }

    func testEveryExitFromABreakClosesTheOverlayRestoresFocusAndResumesAlerts() {
        let start = breaking()
        var completed = start
        completed.tick(now: at(120), idle: 0, hold: .init())
        let skippable = breaking(allowSkip: true)
        var escaped = skippable
        escaped.escHeld(at(104))
        var away = start
        away.setScreenAvailable(false, now: at(105))
        var off = start
        var settings = off.settings
        settings.enabled = false
        off.apply(settings, now: at(106))
        var postponed = planner()
        postponed.startNow(at(100))
        let postponedStart = postponed
        postponed.postpone(at(101))

        for (old, new) in [(start, completed), (skippable, escaped), (start, away), (start, off), (postponedStart, postponed)] {
            let effects = EyeBreakEffects.between(old, new)
            XCTAssertTrue(effects.contains(.closeOverlay), "\(new.phase)")
            XCTAssertTrue(effects.contains(.restoreFocus), "\(new.phase): focus comes back even if activation failed")
            XCTAssertTrue(effects.contains(.resumeAlerts), "\(new.phase): a waiting reminder round runs")
            XCTAssertLessThan(effects.firstIndex(of: .closeOverlay)!, effects.firstIndex(of: .restoreFocus)!)
        }
    }

    func testOnlyABreakThatEndsShowsTheToast() {
        let start = breaking()
        var completed = start
        completed.tick(now: at(120), idle: 0, hold: .init())
        XCTAssertTrue(EyeBreakEffects.between(start, completed).contains(.toast(nextIn: 1200)))
        let skippable = breaking(allowSkip: true)
        var escaped = skippable
        escaped.escHeld(at(104))
        XCTAssertTrue(EyeBreakEffects.between(skippable, escaped).contains(.toast(nextIn: 1200)))

        var postponed = planner()
        postponed.startNow(at(100))
        let before = postponed
        postponed.postpone(at(101))
        XCTAssertFalse(EyeBreakEffects.between(before, postponed).contains { if case .toast = $0 { true } else { false } })

        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: .init())
        var skipped = warning
        skipped.skip(at(1192))
        XCTAssertEqual(EyeBreakEffects.between(warning, skipped), [.hidePill, .nudgePet(false)], "no toast: no break happened")
    }

    func testGoingAwayMidBreakClosesWithoutAToast() {
        let start = breaking()
        var away = start
        away.setScreenAvailable(false, now: at(105))
        XCTAssertEqual(EyeBreakEffects.between(start, away), [.closeOverlay, .restoreFocus, .resumeAlerts])

        var warning = planner()
        warning.tick(now: at(1190), idle: 0, hold: .init())
        var awayFromWarning = warning
        awayFromWarning.setScreenAvailable(false, now: at(1192))
        XCTAssertEqual(EyeBreakEffects.between(warning, awayFromWarning), [.hidePill, .nudgePet(false)])
    }

    func testNoChangeNoEffects() {
        let p = planner()
        XCTAssertEqual(EyeBreakEffects.between(p, p), [])
    }

    // MARK: Text

    func testClockAndPillRoundUpSoTheyNeverShowZeroEarly() {
        XCTAssertEqual(EyeBreakText.clock(754), "12:34")
        XCTAssertEqual(EyeBreakText.clock(11.2), "0:12")
        XCTAssertEqual(EyeBreakText.clock(-3), "0:00")
        XCTAssertEqual(EyeBreakText.pill(7.4), "Eye break in 8 s")
    }

    func testStatusLines() {
        let utc = TimeZone(identifier: "UTC")!
        let enUS = Locale(identifier: "en_US")
        XCTAssertNil(EyeBreakText.statusLine(.off))
        XCTAssertEqual(EyeBreakText.statusLine(.due(in: 754)), "Eye break in 12:34")
        XCTAssertEqual(EyeBreakText.statusLine(.waiting), "Eye break when you’re free")
        let base: TimeInterval = 1_800_000_000
        let midnight: TimeInterval = base - base.truncatingRemainder(dividingBy: 86_400)
        let fiveThirty = Date(timeIntervalSince1970: midnight + 17 * 3600 + 30 * 60)
        let paused = EyeBreakText.statusLine(.paused(until: fiveThirty), locale: enUS, timeZone: utc)
        XCTAssertEqual(paused?.replacingOccurrences(of: "\u{202F}", with: " "), "Eye breaks paused until 5:30 PM")
    }

    func testToastAndAnnouncement() {
        XCTAssertEqual(EyeBreakText.toast(nextIn: 1200), "Eyes rested · next in 20 min")
        XCTAssertEqual(EyeBreakText.toast(nextIn: 40), "Eyes rested · next in 40 s")
        XCTAssertEqual(EyeBreakText.announcement(length: 20), "Eye break, 20 seconds")
    }

    // MARK: Pause times, main screen

    func testPauseEndTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 10:00 local is the spring-forward day: that day has 23 hours.
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 10))!
        XCTAssertEqual(EyeBreakPause.thirtyMinutes.until(now: now, calendar: calendar), now.addingTimeInterval(1800))
        XCTAssertEqual(EyeBreakPause.oneHour.until(now: now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(EyeBreakPause.untilTomorrow.until(now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0)))
        XCTAssertEqual(EyeBreakPause.allCases.map(\.title), ["For 30 Minutes", "For 1 Hour", "Until Tomorrow"])
    }

    func testTheCountdownGoesToTheScreenUnderTheMouse() {
        let screens = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: 1728, y: 0, width: 2560, height: 1440)]
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: screens, mouse: CGPoint(x: 2000, y: 500)), 1)
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: screens, mouse: CGPoint(x: 100, y: 100)), 0)
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: screens, mouse: CGPoint(x: 2000, y: 1440)), 1, "the top edge belongs to the screen, like the pill")
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: screens, mouse: CGPoint(x: -500, y: 9000)), 0, "off every screen: the first")
        XCTAssertEqual(EyeBreakLayout.mainIndex(screens: [screens[1]], mouse: CGPoint(x: 100, y: 100)), 0, "a display unplugged mid-break")
    }
}
