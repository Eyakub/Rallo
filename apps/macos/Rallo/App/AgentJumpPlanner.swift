import Foundation

/// Which session ⌃⌥⌘J last brought forward, and when, so a press within
/// `AgentJumpPlanner.repeatWindow` advances the cycle instead of restarting
/// it (0008).
struct AgentJumpState: Equatable {
    var rowID: String?
    var pressedAt: Date?

    init(rowID: String? = nil, pressedAt: Date? = nil) {
        self.rowID = rowID
        self.pressedAt = pressedAt
    }
}

/// Pure ordering/cycling for the "jump to waiting agent" shortcut (0008), so
/// it's unit-testable without Carbon or a running app.
enum AgentJumpPlanner {
    static let repeatWindow: TimeInterval = 5

    /// Longest-waiting first (oldest `updatedAtMs`), then finished sessions
    /// most-recent first. A session Rallo can't bring forward (no known
    /// terminal, `appPath` nil) is never in the cycle.
    static func order(_ sessions: [AgentSessionSnapshot]) -> [AgentSessionSnapshot] {
        let actionable = sessions.filter { $0.appPath != nil }
        let waiting = actionable.filter { $0.state == "waiting" }.sorted { $0.updatedAtMs < $1.updatedAtMs }
        let done = actionable.filter { $0.state == "done" }.sorted { $0.updatedAtMs > $1.updatedAtMs }
        return waiting + done
    }

    /// The session to bring forward for this press, and the state to
    /// remember for the next one. `nil` with no actionable sessions.
    static func next(
        sessions: [AgentSessionSnapshot], previous: AgentJumpState, now: Date = Date()
    ) -> (session: AgentSessionSnapshot?, state: AgentJumpState) {
        let ordered = order(sessions)
        guard !ordered.isEmpty else { return (nil, AgentJumpState()) }
        let withinWindow = previous.pressedAt.map { now.timeIntervalSince($0) < repeatWindow } ?? false
        let index: Int
        if withinWindow, let rowID = previous.rowID, let previousIndex = ordered.firstIndex(where: { $0.rowID == rowID }) {
            index = (previousIndex + 1) % ordered.count
        } else {
            index = 0
        }
        let chosen = ordered[index]
        return (chosen, AgentJumpState(rowID: chosen.rowID, pressedAt: now))
    }
}
