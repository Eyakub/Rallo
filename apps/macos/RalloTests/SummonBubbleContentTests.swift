import XCTest

/// 0021 §3, §8: what the bubble says, and what it hides in a call.
final class SummonBubbleContentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let time: (Date) -> String = { _ in "4:30 PM" }

    private func reminder(_ text: String) -> AttentionAlert {
        AttentionAlert(id: "n1", kind: .reminder(deadline: now), text: text, nags: true)
    }

    private func agent(waitedSeconds: TimeInterval) -> AttentionAlert {
        AttentionAlert(id: "a1", kind: .agent(waitingSince: now.addingTimeInterval(-waitedSeconds)),
                       text: "Claude Code needs you in rallo", nags: true)
    }

    func testAReminderShowsItsTimeAndText() {
        XCTAssertEqual(SummonBubbleContent.make(for: reminder("Send the invoice to Acme"), showsDetails: true, moreCount: 2, now: now, timeText: time),
                       SummonBubbleContent(kindLine: "⏰ Reminder · 4:30 PM", text: "Send the invoice to Acme", isAgent: false, moreCount: 2))
    }

    /// Review Focus 5.
    func testACallShowsNoTextRepoOrTime() {
        XCTAssertEqual(SummonBubbleContent.make(for: reminder("Salary review with Sam"), showsDetails: false, moreCount: 0, now: now, timeText: time),
                       SummonBubbleContent(kindLine: "⏰ Reminder", text: nil, isAgent: false, moreCount: 0))
        XCTAssertEqual(SummonBubbleContent.make(for: agent(waitedSeconds: 720), showsDetails: false, moreCount: 0, now: now, timeText: time),
                       SummonBubbleContent(kindLine: "🤖 An agent is waiting", text: nil, isAgent: true, moreCount: 0))
    }

    func testAnAgentShowsHowLongItHasWaited() {
        XCTAssertEqual(SummonBubbleContent.make(for: agent(waitedSeconds: 12 * 60 + 30), showsDetails: true, moreCount: 0, now: now, timeText: time),
                       SummonBubbleContent(kindLine: "🤖 Agent waiting · 12 min", text: "Claude Code needs you in rallo", isAgent: true, moreCount: 0))
        XCTAssertEqual(SummonBubbleContent.make(for: agent(waitedSeconds: 5), showsDetails: true, moreCount: 0, now: now, timeText: time).kindLine,
                       "🤖 Agent waiting · 1 min")
    }

    func testTheAgentLineNamesTheAgentAndItsPlace() {
        let session = AgentSessionSnapshot(agent: "claude", sessionId: "s1", state: "waiting", place: "code/rallo", detail: "Bash",
                                           appPath: "/Applications/Terminal.app", appPid: nil, focus: nil, updatedAtMs: 0)
        let name = AgentSessionFormatting.agentName("claude")
        let place = AgentSessionFormatting.place(for: session)
        XCTAssertEqual(SummonBubbleContent.agentText(for: session), place.map { "\(name) needs you in \($0)" } ?? "\(name) needs you")
    }

    func testTheExcerptFlattensLinesAndStopsAt160Characters() {
        XCTAssertEqual(SummonBubbleContent.excerpt("Call the dentist\n\n  about Thursday \n"), "Call the dentist about Thursday")
        let cut = SummonBubbleContent.excerpt(String(repeating: "🦊", count: 200))
        XCTAssertEqual(cut.count, 160)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(SummonBubbleContent.excerpt(String(repeating: "a", count: 160)).count, 160, "exactly 160 stays whole")
    }
}
