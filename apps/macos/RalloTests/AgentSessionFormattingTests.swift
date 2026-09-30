import XCTest

/// Row title/subtitle/relative time and sort order for the panel's "Agents"
/// section (docs/decisions/0007).
final class AgentSessionFormattingTests: XCTestCase {
    private func session(
        agent: String = "claude", sessionId: String = "s1", state: String = "waiting",
        cwd: String? = "/Users/x/code/shop", detail: String? = nil, appPath: String? = nil,
        updatedAtMs: Int64 = 0
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(agent: agent, sessionId: sessionId, state: state, cwd: cwd, detail: detail,
                             appPath: appPath, appPid: nil, updatedAtMs: updatedAtMs)
    }

    // MARK: Title

    func testTitleUsesTheFolderNameAndAgentDisplayName() {
        XCTAssertEqual(AgentSessionFormatting.title(for: session(agent: "claude", cwd: "/Users/x/code/shop")),
                       "Claude Code · shop")
        XCTAssertEqual(AgentSessionFormatting.title(for: session(agent: "codex", cwd: "/Users/x/code/rallo")),
                       "Codex · rallo")
    }

    func testTitleWithoutCwdIsTheAgentNameAlone() {
        XCTAssertEqual(AgentSessionFormatting.title(for: session(cwd: nil)), "Claude Code")
        XCTAssertEqual(AgentSessionFormatting.title(for: session(cwd: "")), "Claude Code")
    }

    // MARK: Subtitle

    func testWaitingWithDetailNamesTheTool() {
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: session(state: "waiting", detail: "Bash")),
                       "Waiting for permission: Bash")
    }

    func testWaitingWithoutDetailIsGeneric() {
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: session(state: "waiting", detail: nil)),
                       "Waiting for you")
    }

    func testDoneIsFinished() {
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: session(state: "done")), "Finished")
    }

    // MARK: Relative time

    func testRelativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(AgentSessionFormatting.relativeTime(updatedAtMs: nowMs, now: now), "now")
        XCTAssertEqual(AgentSessionFormatting.relativeTime(updatedAtMs: nowMs - 45_000, now: now), "now")
        XCTAssertEqual(AgentSessionFormatting.relativeTime(updatedAtMs: nowMs - 2 * 60_000, now: now), "2 min")
        XCTAssertEqual(AgentSessionFormatting.relativeTime(updatedAtMs: nowMs - 90 * 60_000, now: now), "1 h")
    }

    // MARK: Notification title and VoiceOver announcement (0008)

    func testNotificationTitleNamesTheFolder() {
        XCTAssertEqual(AgentSessionFormatting.notificationTitle(for: session(agent: "claude", cwd: "/Users/x/code/shop")),
                       "Claude Code is waiting in shop")
    }

    func testNotificationTitleWithoutCwdOmitsThePlace() {
        XCTAssertEqual(AgentSessionFormatting.notificationTitle(for: session(cwd: nil)), "Claude Code is waiting")
    }

    func testWaitingAnnouncementForAPermissionRequest() {
        let row = session(agent: "claude", cwd: "/Users/x/code/shop", detail: "Bash")
        XCTAssertEqual(AgentSessionFormatting.waitingAnnouncement(for: row),
                       "Claude Code in shop is waiting for permission: Bash.")
    }

    func testWaitingAnnouncementWithoutCwdOrDetail() {
        let row = session(cwd: nil, detail: nil)
        XCTAssertEqual(AgentSessionFormatting.waitingAnnouncement(for: row), "Claude Code is waiting for you.")
    }

    // MARK: Accessibility label

    func testAccessibilityLabelForAWaitingPermissionRow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let row = session(agent: "claude", state: "waiting", cwd: "/Users/x/code/shop", detail: "Bash",
                          updatedAtMs: nowMs - 2 * 60_000)
        XCTAssertEqual(AgentSessionFormatting.accessibilityLabel(for: row, now: now),
                       "Claude Code in shop, waiting for permission: Bash, 2 minutes ago")
    }

    func testAccessibilityLabelWithoutCwdOmitsThePlace() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = session(cwd: nil, detail: nil, updatedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(AgentSessionFormatting.accessibilityLabel(for: row, now: now),
                       "Claude Code, waiting for you, just now")
    }

    func testAccessibilityLabelSingularMinuteAndHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let oneMinute = session(updatedAtMs: nowMs - 60_000)
        XCTAssertTrue(AgentSessionFormatting.accessibilityLabel(for: oneMinute, now: now).hasSuffix("1 minute ago"))
        let oneHour = session(updatedAtMs: nowMs - 60 * 60_000)
        XCTAssertTrue(AgentSessionFormatting.accessibilityLabel(for: oneHour, now: now).hasSuffix("1 hour ago"))
    }

    // MARK: Sorting

    func testSortingPutsWaitingBeforeDoneThenMostRecentFirst() {
        let oldWaiting = session(sessionId: "old-waiting", state: "waiting", updatedAtMs: 100)
        let newDone = session(sessionId: "new-done", state: "done", updatedAtMs: 900)
        let newWaiting = session(sessionId: "new-waiting", state: "waiting", updatedAtMs: 500)
        let oldDone = session(sessionId: "old-done", state: "done", updatedAtMs: 50)

        let sorted = AgentSessionFormatting.sorted([oldWaiting, newDone, newWaiting, oldDone])
        XCTAssertEqual(sorted.map(\.sessionId), ["new-waiting", "old-waiting", "new-done", "old-done"])
    }
}
