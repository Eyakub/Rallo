import XCTest

/// 0021 §2-§5, §8: what one round does, when the nag comes back, and when
/// an alert stops being pending. Pure; the coordinator only performs it.
final class AttentionPlannerTests: XCTestCase {
    private let settings = AlertSettings.initial
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func reminder(_ id: String, nags: Bool = true, repeats: Int = 0) -> AttentionAlert {
        AttentionAlert(id: id, kind: .reminder(deadline: t0), text: "Note \(id)", nags: nags, repeats: repeats)
    }

    private func agent(_ id: String, nags: Bool = true, repeats: Int = 0) -> AttentionAlert {
        AttentionAlert(id: id, kind: .agent(waitingSince: t0), text: "Agent \(id)", nags: nags, repeats: repeats)
    }

    private func round(_ decision: AttentionPlanner.Decision) -> AttentionRound? {
        if case let .run(round) = decision { return round }
        return nil
    }

    // MARK: Defaults

    func testTheSwiftDefaultsMatchTheSpec() {
        XCTAssertEqual(settings, AlertSettings(summon: true, sound: .ralloChime, nag: true, nagIntervalMinutes: 2,
                                               nagMaxRounds: 5, glow: false, agents: true))
    }

    // MARK: One round (§3, §8)

    func testTheFirstRoundSummonsWithoutAChimeBecauseTheBannerRings() {
        let run = round(AttentionPlanner.decide(.first, settings: settings, signals: AttentionSignals(), alerts: [reminder("a")]))
        XCTAssertEqual(run, AttentionRound(summon: true, glow: false, chime: false, showsDetails: true, fades: false, alertIDs: ["a"]))
    }

    func testNagAndResumedRoundsChime() {
        for kind in [AttentionPlanner.RoundKind.nag, .resumed] {
            XCTAssertEqual(round(AttentionPlanner.decide(kind, settings: settings, signals: AttentionSignals(), alerts: [reminder("a")]))?.chime, true, "\(kind)")
        }
        var silent = settings
        silent.sound = .none
        XCTAssertEqual(round(AttentionPlanner.decide(.nag, settings: silent, signals: AttentionSignals(), alerts: [reminder("a")]))?.chime, false)
    }

    func testTheGlowFollowsItsSwitch() {
        var glowing = settings
        glowing.glow = true
        XCTAssertEqual(round(AttentionPlanner.decide(.first, settings: glowing, signals: AttentionSignals(), alerts: [reminder("a")]))?.glow, true)
    }

    func testFocusAndAnEyeBreakHoldTheRound() {
        XCTAssertEqual(AttentionPlanner.decide(.first, settings: settings, signals: AttentionSignals(focusOn: true), alerts: [reminder("a")]), .hold)
        XCTAssertEqual(AttentionPlanner.decide(.nag, settings: settings, signals: AttentionSignals(eyeBreakActive: true), alerts: [reminder("a")]), .hold)
    }

    /// Review Focus 5.
    func testACallHidesDetailsAndSilencesTheNagButKeepsTheGlow() {
        var glowing = settings
        glowing.glow = true
        let run = round(AttentionPlanner.decide(.nag, settings: glowing, signals: AttentionSignals(cameraOrMicInUse: true), alerts: [reminder("a")]))
        XCTAssertEqual(run, AttentionRound(summon: true, glow: true, chime: false, showsDetails: false, fades: false, alertIDs: ["a"]))
    }

    func testReduceMotionFades() {
        XCTAssertEqual(round(AttentionPlanner.decide(.first, settings: settings, signals: AttentionSignals(reduceMotion: true), alerts: [reminder("a")]))?.fades, true)
    }

    func testNothingRunsWithEveryEffectOffOrNoAlerts() {
        var off = settings
        off.summon = false
        off.glow = false
        off.nag = false
        XCTAssertEqual(AttentionPlanner.decide(.first, settings: off, signals: AttentionSignals(), alerts: [reminder("a")]), .nothing)
        XCTAssertEqual(AttentionPlanner.decide(.first, settings: settings, signals: AttentionSignals(), alerts: []), .nothing)
    }

    func testSeveralAlertsShareOneRoundNewestFirst() {
        let run = round(AttentionPlanner.decide(.first, settings: settings, signals: AttentionSignals(), alerts: [reminder("old"), reminder("new")]))
        XCTAssertEqual(run?.alertIDs, ["new", "old"])
    }

    // MARK: Nag (§4)

    func testTheNagComesBackAfterTheInterval() {
        XCTAssertEqual(AttentionPlanner.nextNag(after: t0, settings: settings, alerts: [reminder("a")]), t0.addingTimeInterval(120))
        var fast = settings
        fast.nagIntervalMinutes = 1
        XCTAssertEqual(AttentionPlanner.nextNag(after: t0, settings: fast, alerts: [reminder("a")]), t0.addingTimeInterval(60))
    }

    func testNoNagWhenItIsOffOrEveryRepeatIsUsed() {
        var off = settings
        off.nag = false
        XCTAssertNil(AttentionPlanner.nextNag(after: t0, settings: off, alerts: [reminder("a")]))
        XCTAssertNil(AttentionPlanner.nextNag(after: t0, settings: settings, alerts: [reminder("a", repeats: 5)]))
        XCTAssertNotNil(AttentionPlanner.nextNag(after: t0, settings: settings, alerts: [reminder("a", repeats: 5), reminder("b", repeats: 4)]))
    }

    func testCountingANagStopsAtTheCapPerAlert() {
        var queue = AttentionQueue()
        queue.add(reminder("a", repeats: 4))
        queue.add(reminder("b"))
        queue.countNag(maxRounds: 5)
        queue.countNag(maxRounds: 5)
        XCTAssertEqual(queue.alerts.map(\.repeats), [5, 2])
    }

    // MARK: What a nag round re-rings (§2, §4, §9 fallback)

    /// Wake: A came due before sleep and nags; B came due during sleep, newer, in the one grouped round.
    func testAWakeNagReringsTheReminderThatNagsNotTheNewerGroupedOne() {
        var queue = AttentionQueue()
        queue.add(reminder("a", repeats: 1))
        queue.add(reminder("b", nags: false))
        XCTAssertEqual(queue.drivingAlert(maxRounds: 5)?.id, "a")
    }

    /// Launch: a grouped reminder never re-rings, even while an agent alert nags.
    func testAnAgentNagReringsTheAgentNotALaunchGroupedReminder() {
        var launchFirst = AttentionQueue()
        launchFirst.add(reminder("launch", nags: false))
        launchFirst.add(agent("agent"))
        XCTAssertEqual(launchFirst.drivingAlert(maxRounds: 5)?.id, "agent")
        var agentFirst = AttentionQueue()
        agentFirst.add(agent("agent"))
        agentFirst.add(reminder("launch", nags: false))
        XCTAssertEqual(agentFirst.drivingAlert(maxRounds: 5)?.id, "agent")
    }

    /// Agent-only: nag rounds chime for agents too (§4).
    func testAnAgentOnlyQueueReringsTheAgent() {
        var queue = AttentionQueue()
        queue.add(agent("agent"))
        XCTAssertEqual(queue.drivingAlert(maxRounds: 5), agent("agent"))
    }

    /// Read before `countNag`: an alert's last repeat still re-rings it.
    func testTheLastRepeatStillReringsAndThenNothingDoes() {
        var queue = AttentionQueue()
        queue.add(reminder("a", repeats: 4))
        queue.add(reminder("b", repeats: 5))
        XCTAssertEqual(queue.drivingAlert(maxRounds: 5)?.id, "a", "b, newer, has no repeat left")
        queue.countNag(maxRounds: 5)
        XCTAssertNil(queue.drivingAlert(maxRounds: 5))
    }

    // MARK: Pending and handled (§2, §4)

    func testANewDueReminderIsNewOnceAndAHandledOneLeaves() {
        var queue = AttentionQueue()
        XCTAssertEqual(queue.dueListChanged(["a", "b"]), ["a", "b"])
        queue.add(reminder("a"))
        queue.add(reminder("b"))
        XCTAssertEqual(queue.dueListChanged(["a", "b"]), [], "already alerted")
        XCTAssertEqual(queue.dueListChanged(["b"]), [], "a was done or snoozed")
        XCTAssertEqual(queue.alerts.map(\.id), ["b"])
    }

    /// Review Focus 1.
    func testASnoozedReminderThatComesDueAgainAlertsAgain() {
        var queue = AttentionQueue()
        _ = queue.dueListChanged(["a"])
        queue.add(reminder("a"))
        _ = queue.dueListChanged([])          // snoozed: no longer due
        XCTAssertFalse(queue.alertedReminders.contains("a"))
        XCTAssertEqual(queue.dueListChanged(["a"]), ["a"], "due again is a new alert")
    }

    func testOnlyHandlingRemovesAnAlertNeverARoundOrATimeout() {
        var queue = AttentionQueue()
        queue.add(reminder("a"))
        queue.countNag(maxRounds: 5)
        XCTAssertEqual(queue.alerts.map(\.id), ["a"], "a nag round or a timed-out bubble leaves it pending")
        queue.handle("a")
        XCTAssertTrue(queue.alerts.isEmpty)
        queue.add(reminder("a"))
        queue.add(reminder("a"))
        XCTAssertEqual(queue.alerts.count, 1, "adding twice keeps one")
    }

    // MARK: Launch and wake (§2)

    func testALaunchGroupGetsOneRoundAndNeverNags() {
        let due = [(id: "recent", deadline: t0.addingTimeInterval(-3_600)), (id: "old", deadline: t0.addingTimeInterval(-13 * 3_600))]
        let group = AttentionPlanner.grouped(due, cutoff: t0.addingTimeInterval(-AttentionPlanner.launchWindow))
        XCTAssertEqual(group, ["recent"])
        let alerts = [reminder("recent", nags: false)]
        XCTAssertNotNil(round(AttentionPlanner.decide(.first, settings: settings, signals: AttentionSignals(), alerts: alerts)))
        XCTAssertNil(AttentionPlanner.nextNag(after: t0, settings: settings, alerts: alerts))
    }

    func testAWakeGroupIsWhatCameDueDuringSleep() {
        let sleptAt = t0.addingTimeInterval(-600)
        let due = [(id: "during", deadline: t0.addingTimeInterval(-60)), (id: "before", deadline: t0.addingTimeInterval(-900))]
        XCTAssertEqual(AttentionPlanner.grouped(due, cutoff: sleptAt), ["during"])
    }
}
