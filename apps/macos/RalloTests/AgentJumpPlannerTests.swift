import XCTest

/// Ordering and cycling for ⌃⌥⌘J, "jump to waiting agent" (0008).
final class AgentJumpPlannerTests: XCTestCase {
    private func session(
        sessionId: String, state: String = "waiting", updatedAtMs: Int64 = 0, appPath: String? = "/Applications/Terminal.app"
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(agent: "claude", sessionId: sessionId, state: state, place: "tmp", detail: nil,
                             appPath: appPath, appPid: nil, focus: nil, updatedAtMs: updatedAtMs)
    }

    // MARK: Order

    func testOrderPutsLongestWaitingFirstThenMostRecentlyFinished() {
        let sessions = [
            session(sessionId: "waiting-new", state: "waiting", updatedAtMs: 500),
            session(sessionId: "waiting-old", state: "waiting", updatedAtMs: 100),
            session(sessionId: "done-new", state: "done", updatedAtMs: 900),
            session(sessionId: "done-old", state: "done", updatedAtMs: 300),
        ]
        let ordered = AgentJumpPlanner.order(sessions).map(\.sessionId)
        XCTAssertEqual(ordered, ["waiting-old", "waiting-new", "done-new", "done-old"])
    }

    func testOrderExcludesSessionsWithoutAKnownTerminal() {
        let sessions = [
            session(sessionId: "no-app", state: "waiting", updatedAtMs: 0, appPath: nil),
            session(sessionId: "has-app", state: "waiting", updatedAtMs: 100),
        ]
        XCTAssertEqual(AgentJumpPlanner.order(sessions).map(\.sessionId), ["has-app"])
    }

    // MARK: Cycling

    func testFirstPressPicksTheLongestWaitingSession() {
        let sessions = [session(sessionId: "a", updatedAtMs: 200), session(sessionId: "b", updatedAtMs: 100)]
        let now = Date()
        let (chosen, _) = AgentJumpPlanner.next(sessions: sessions, previous: AgentJumpState(), now: now)
        XCTAssertEqual(chosen?.sessionId, "b")
    }

    func testAPressWithinFiveSecondsAdvancesToTheNext() {
        let sessions = [session(sessionId: "a", updatedAtMs: 200), session(sessionId: "b", updatedAtMs: 100)]
        let now = Date()
        let (first, state1) = AgentJumpPlanner.next(sessions: sessions, previous: AgentJumpState(), now: now)
        XCTAssertEqual(first?.sessionId, "b")
        let (second, _) = AgentJumpPlanner.next(sessions: sessions, previous: state1, now: now.addingTimeInterval(3))
        XCTAssertEqual(second?.sessionId, "a")
    }

    func testCyclingWrapsAroundToTheStart() {
        let sessions = [session(sessionId: "a", updatedAtMs: 200), session(sessionId: "b", updatedAtMs: 100)]
        let now = Date()
        let (_, state1) = AgentJumpPlanner.next(sessions: sessions, previous: AgentJumpState(), now: now)
        let (_, state2) = AgentJumpPlanner.next(sessions: sessions, previous: state1, now: now.addingTimeInterval(1))
        let (third, _) = AgentJumpPlanner.next(sessions: sessions, previous: state2, now: now.addingTimeInterval(2))
        XCTAssertEqual(third?.sessionId, "b", "a third press within the window wraps back to the first")
    }

    func testAPressAfterFiveSecondsRestartsFromTheLongestWaiting() {
        let sessions = [session(sessionId: "a", updatedAtMs: 200), session(sessionId: "b", updatedAtMs: 100)]
        let now = Date()
        let (_, state1) = AgentJumpPlanner.next(sessions: sessions, previous: AgentJumpState(), now: now)
        let (second, _) = AgentJumpPlanner.next(sessions: sessions, previous: state1, now: now.addingTimeInterval(5.5))
        XCTAssertEqual(second?.sessionId, "b", "outside the repeat window, the cycle restarts")
    }

    func testEmptySessionsDoNothing() {
        let (chosen, state) = AgentJumpPlanner.next(sessions: [], previous: AgentJumpState())
        XCTAssertNil(chosen)
        XCTAssertNil(state.rowID)
    }

    func testWaitingSessionsComeBeforeDoneEvenWhenPressedWithinTheWindow() {
        let sessions = [session(sessionId: "waiting", state: "waiting", updatedAtMs: 0),
                        session(sessionId: "done", state: "done", updatedAtMs: 1000)]
        let now = Date()
        let (first, state1) = AgentJumpPlanner.next(sessions: sessions, previous: AgentJumpState(), now: now)
        XCTAssertEqual(first?.sessionId, "waiting")
        let (second, _) = AgentJumpPlanner.next(sessions: sessions, previous: state1, now: now.addingTimeInterval(1))
        XCTAssertEqual(second?.sessionId, "done")
    }
}
