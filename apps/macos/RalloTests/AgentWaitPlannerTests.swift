import XCTest

/// The long-wait notification's "once per waiting period" and withdraw
/// decisions (0008), and the identifier namespace's separation from the
/// reminder reconciler's (0005).
final class AgentWaitPlannerTests: XCTestCase {
    private let scope = "abc123"
    private let threshold: Double = 300

    private func session(
        sessionId: String = "s1", agent: String = "claude", state: String = "waiting", updatedAtMs: Int64
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(agent: agent, sessionId: sessionId, state: state, cwd: "/tmp/shop", detail: "Bash",
                             appPath: "/Applications/Terminal.app", appPid: nil, updatedAtMs: updatedAtMs)
    }

    private func identifier(sessionId: String = "s1", agent: String = "claude") -> String {
        AgentNotificationIdentifier.make(scope: scope, agent: agent, sessionId: sessionId)
    }

    // MARK: Posting

    func testASessionWaitingPastTheThresholdIsPosted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let waiting = session(updatedAtMs: nowMs - Int64(threshold * 1000))
        let plan = AgentWaitPlanner.plan(sessions: [waiting], scope: scope, thresholdSeconds: threshold, now: now, notified: [:])
        XCTAssertEqual(plan.toPost.map(\.identifier), [identifier()])
        XCTAssertEqual(plan.notified, [identifier(): waiting.updatedAtMs])
    }

    func testASessionWaitingLessThanTheThresholdIsNotPosted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let waiting = session(updatedAtMs: nowMs - 60_000)
        let plan = AgentWaitPlanner.plan(sessions: [waiting], scope: scope, thresholdSeconds: threshold, now: now, notified: [:])
        XCTAssertTrue(plan.toPost.isEmpty)
        XCTAssertTrue(plan.notified.isEmpty)
    }

    func testAnAlreadyNotifiedPeriodIsNeverPostedTwice() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let waiting = session(updatedAtMs: nowMs - Int64(threshold * 1000) - 60_000)
        let notified = [identifier(): waiting.updatedAtMs]
        let plan = AgentWaitPlanner.plan(sessions: [waiting], scope: scope, thresholdSeconds: threshold, now: now, notified: notified)
        XCTAssertTrue(plan.toPost.isEmpty, "the same waiting period never notifies twice")
        XCTAssertTrue(plan.toWithdraw.isEmpty)
        XCTAssertEqual(plan.notified, notified)
    }

    // MARK: Withdrawal

    func testASessionThatLeftWaitingIsWithdrawn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let notified = [identifier(): Int64(0)]
        let done = session(state: "done", updatedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        let plan = AgentWaitPlanner.plan(sessions: [done], scope: scope, thresholdSeconds: threshold, now: now, notified: notified)
        XCTAssertEqual(plan.toWithdraw, [identifier()])
        XCTAssertTrue(plan.notified.isEmpty)
    }

    func testADismissedSessionMissingEntirelyIsWithdrawn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let notified = [identifier(): Int64(0)]
        let plan = AgentWaitPlanner.plan(sessions: [], scope: scope, thresholdSeconds: threshold, now: now, notified: notified)
        XCTAssertEqual(plan.toWithdraw, [identifier()])
        XCTAssertTrue(plan.notified.isEmpty)
    }

    func testANewWaitingPeriodWithdrawsTheStaleNotificationAndCanRenotifyLater() {
        // The tool changed (a new `updated_at_ms`) while still waiting: the
        // old notification's text is stale, and this new period hasn't yet
        // reached the threshold.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let notified = [identifier(): nowMs - 400_000]
        let stillWaiting = session(updatedAtMs: nowMs - 10_000)
        let plan = AgentWaitPlanner.plan(sessions: [stillWaiting], scope: scope, thresholdSeconds: threshold, now: now, notified: notified)
        XCTAssertEqual(plan.toWithdraw, [identifier()])
        XCTAssertTrue(plan.toPost.isEmpty, "the new period hasn't reached the threshold yet")
        XCTAssertTrue(plan.notified.isEmpty)
    }

    // MARK: Next wake

    func testNextWakeIsTheEarliestUnnotifiedWaitingSessionsThreshold() {
        let older = session(sessionId: "older", updatedAtMs: 1_000)
        let newer = session(sessionId: "newer", updatedAtMs: 5_000)
        let nextWake = AgentWaitPlanner.nextWakeAtMs(
            sessions: [older, newer], scope: scope, thresholdSeconds: threshold, notified: [:])
        XCTAssertEqual(nextWake, 1_000 + Int64(threshold * 1000))
    }

    func testNextWakeIgnoresAlreadyNotifiedSessions() {
        let session1 = session(sessionId: "s1", updatedAtMs: 1_000)
        let notified = [identifier(sessionId: "s1"): Int64(1_000)]
        let nextWake = AgentWaitPlanner.nextWakeAtMs(
            sessions: [session1], scope: scope, thresholdSeconds: threshold, notified: notified)
        XCTAssertNil(nextWake)
    }

    // MARK: Identifier prefix separation (0005/0008 seam)

    func testAgentIdentifiersNeverShareTheReminderPrefix() {
        let agentIdentifier = identifier()
        XCTAssertTrue(agentIdentifier.hasPrefix(AgentNotificationIdentifier.prefix))
        XCTAssertFalse(agentIdentifier.hasPrefix(NotificationAdapter.reminderPrefix))
    }

    func testReminderIdentifiersNeverShareTheAgentPrefix() {
        let reminderIdentifier = "\(NotificationAdapter.reminderPrefix)\(scope).\(UUID().uuidString)"
        XCTAssertFalse(reminderIdentifier.hasPrefix(AgentNotificationIdentifier.prefix))
    }

    /// Mirrors `NotificationDrainer.reconcile()`'s prefix filter: whatever it
    /// hands the core is already narrowed to `rallo.reminder.<scope>.`, so an
    /// agent-wait identifier can never reach — or be removed by — the
    /// reminder reconciler.
    func testReminderPrefixFilteringExcludesAgentIdentifiers() {
        let reminderPrefix = "\(NotificationAdapter.reminderPrefix)\(scope)."
        let mixed = [identifier(), "\(reminderPrefix)\(UUID().uuidString)"]
        let filtered = mixed.filter { $0.hasPrefix(reminderPrefix) }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertFalse(filtered[0].hasPrefix(AgentNotificationIdentifier.prefix))
    }

    func testScopeExtractionRoundTripsThroughTheReminderPrefix() {
        let reminderPrefix = "\(NotificationAdapter.reminderPrefix)\(scope)."
        XCTAssertEqual(AgentNotificationIdentifier.scope(fromReminderPrefix: reminderPrefix), scope)
    }
}
