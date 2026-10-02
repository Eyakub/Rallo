import XCTest

/// Row title/subtitle/relative time and sort order for the panel's agents
/// section (docs/decisions/0007).
final class AgentSessionFormattingTests: XCTestCase {
    private func session(
        agent: String = "claude", sessionId: String = "s1", state: String = "waiting",
        place: String? = "code/shop", detail: String? = nil, appPath: String? = nil,
        updatedAtMs: Int64 = 0
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(agent: agent, sessionId: sessionId, state: state, place: place, detail: detail,
                             appPath: appPath, appPid: nil, focus: nil, updatedAtMs: updatedAtMs)
    }

    // MARK: ClickUp (0010)

    private func clickUp(who: String? = "Muhsin Ahmed", group: Bool = false, updatedAtMs: Int64 = 0) -> AgentSessionSnapshot {
        AgentSessionSnapshot(agent: "clickup", sessionId: "2kyqzpv9-1", state: "waiting", place: who,
                             detail: group ? "group" : nil, appPath: nil, appPid: nil,
                             focus: "clickup:1:2kyqzpv9-1", updatedAtMs: updatedAtMs)
    }

    func testClickUpRowsNameThePerson() {
        XCTAssertEqual(AgentSessionFormatting.title(for: clickUp()), "Muhsin Ahmed")
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: clickUp()), "Messaged you on ClickUp")
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: clickUp(group: true)), "Group message on ClickUp")
        XCTAssertEqual(AgentSessionFormatting.title(for: clickUp(who: nil)), "ClickUp")
    }

    func testClickUpRowsAreClickableWithoutTheDesktopApp() {
        XCTAssertTrue(clickUp().isActionable)
        XCTAssertFalse(session(appPath: nil).isActionable)
    }

    func testClickUpSpokenText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = clickUp(updatedAtMs: Int64(now.timeIntervalSince1970 * 1000) - 3 * 60_000)
        XCTAssertEqual(AgentSessionFormatting.waitingAnnouncement(for: row), "Muhsin Ahmed messaged you on ClickUp.")
        XCTAssertEqual(AgentSessionFormatting.accessibilityLabel(for: row, now: now),
                       "Muhsin Ahmed messaged you on ClickUp, 3 minutes ago")
    }

    // MARK: Title

    func testTitleUsesThePlaceAndAgentDisplayName() {
        XCTAssertEqual(AgentSessionFormatting.title(for: session(agent: "claude", place: "code/shop")),
                       "Claude Code · code/shop")
        XCTAssertEqual(AgentSessionFormatting.title(for: session(agent: "codex", place: "~")), "Codex · ~")
        XCTAssertEqual(AgentSessionFormatting.title(for: session(agent: "grok", place: "~")), "Grok · ~")
    }

    func testTitleWithoutAPlaceIsTheAgentNameAlone() {
        XCTAssertEqual(AgentSessionFormatting.title(for: session(place: nil)), "Claude Code")
        XCTAssertEqual(AgentSessionFormatting.title(for: session(place: "")), "Claude Code")
    }

    // MARK: Subtitle

    func testWaitingWithDetailNamesTheTool() {
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: session(state: "waiting", detail: "Bash")),
                       "Asks to use Bash")
    }

    func testWaitingWithoutDetailWaitsForAnAnswer() {
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: session(state: "waiting", detail: nil)),
                       "Waiting for your answer")
    }

    func testAskUserQuestionIsAQuestion() {
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: session(state: "waiting", detail: "AskUserQuestion")),
                       "Has a question for you")
    }

    func testSubtitleNamesTheTerminalWhenKnown() {
        let row = session(detail: "Bash", appPath: "/Applications/cmux.app")
        XCTAssertEqual(AgentSessionFormatting.subtitle(for: row), "Asks to use Bash · cmux")
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
        XCTAssertEqual(AgentSessionFormatting.notificationTitle(for: session(agent: "claude", place: "code/shop")),
                       "Claude Code is waiting in code/shop")
    }

    func testNotificationTitleWithoutAPlaceOmitsThePlace() {
        XCTAssertEqual(AgentSessionFormatting.notificationTitle(for: session(place: nil)), "Claude Code is waiting")
    }

    func testWaitingAnnouncementForAPermissionRequest() {
        let row = session(agent: "claude", place: "code/shop", detail: "Bash")
        XCTAssertEqual(AgentSessionFormatting.waitingAnnouncement(for: row),
                       "Claude Code in code/shop is asking to use Bash.")
    }

    func testWaitingAnnouncementWithoutAPlaceOrDetail() {
        let row = session(place: nil, detail: nil)
        XCTAssertEqual(AgentSessionFormatting.waitingAnnouncement(for: row), "Claude Code is waiting for your answer.")
    }

    // MARK: Accessibility label

    func testAccessibilityLabelForAWaitingPermissionRow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let row = session(agent: "claude", state: "waiting", place: "code/shop", detail: "Bash",
                          updatedAtMs: nowMs - 2 * 60_000)
        XCTAssertEqual(AgentSessionFormatting.accessibilityLabel(for: row, now: now),
                       "Claude Code in code/shop, asking to use Bash, 2 minutes ago")
    }

    func testAccessibilityLabelWithoutAPlaceOmitsThePlace() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = session(place: nil, detail: nil, updatedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(AgentSessionFormatting.accessibilityLabel(for: row, now: now),
                       "Claude Code, waiting for your answer, just now")
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
