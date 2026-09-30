import Foundation

extension AgentSessionSnapshot {
    /// Unique across agents: `sessionId` alone repeats between Claude Code
    /// and Codex.
    var rowID: String { "\(agent)#\(sessionId)" }
}

/// Formats an `AgentSessionSnapshot` for the panel's "Agents" section
/// (docs/decisions/0007). Pure and UI-free so it's unit-testable.
enum AgentSessionFormatting {
    /// Waiting rows first, most recently updated within each group.
    static func sorted(_ sessions: [AgentSessionSnapshot]) -> [AgentSessionSnapshot] {
        sessions.sorted { a, b in
            let waiting = (a.state == "waiting", b.state == "waiting")
            if waiting.0 != waiting.1 { return waiting.0 }
            return a.updatedAtMs > b.updatedAtMs
        }
    }

    /// "Claude Code" / "Codex"; anything else shows as-is rather than crash,
    /// in case a future agent lands before this switch does.
    static func agentName(_ agent: String) -> String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: agent
        }
    }

    /// The last path component of `cwd`, or nil for a nil or empty `cwd`.
    static func folder(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// "Claude Code · rallo", or "Claude Code" alone when `cwd` is nil.
    static func title(for session: AgentSessionSnapshot) -> String {
        let name = agentName(session.agent)
        guard let folder = folder(cwd: session.cwd) else { return name }
        return "\(name) · \(folder)"
    }

    /// "Waiting for permission: Bash" / "Waiting for you" / "Finished".
    static func subtitle(for session: AgentSessionSnapshot) -> String {
        switch session.state {
        case "waiting":
            if let detail = session.detail, !detail.isEmpty { return "Waiting for permission: \(detail)" }
            return "Waiting for you"
        case "done":
            return "Finished"
        default:
            return session.state.capitalized
        }
    }

    /// Compact, for the row: "now", "2 min", "1 h".
    static func relativeTime(updatedAtMs: Int64, now: Date = Date()) -> String {
        let minutes = minutesElapsed(updatedAtMs: updatedAtMs, now: now)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }

    /// The row's single accessibility label, e.g. "Claude Code in rallo,
    /// waiting for permission: Bash, 2 minutes ago".
    static func accessibilityLabel(for session: AgentSessionSnapshot, now: Date = Date()) -> String {
        let name = agentName(session.agent)
        let place = folder(cwd: session.cwd).map { " in \($0)" } ?? ""
        return "\(name)\(place), \(accessibleState(for: session)), \(accessibleTime(updatedAtMs: session.updatedAtMs, now: now))"
    }

    /// "Claude Code is waiting in shop", for the long-wait notification's
    /// title (0008). Its body is `subtitle(for:)`.
    static func notificationTitle(for session: AgentSessionSnapshot) -> String {
        let name = agentName(session.agent)
        guard let folder = folder(cwd: session.cwd) else { return "\(name) is waiting" }
        return "\(name) is waiting in \(folder)"
    }

    /// "Claude Code in shop is waiting for permission: Bash.", for the
    /// VoiceOver announcement when a session enters `waiting` (0008).
    static func waitingAnnouncement(for session: AgentSessionSnapshot) -> String {
        let name = agentName(session.agent)
        let place = folder(cwd: session.cwd).map { " in \($0)" } ?? ""
        return "\(name)\(place) is \(accessibleState(for: session))."
    }

    static func accessibleState(for session: AgentSessionSnapshot) -> String {
        switch session.state {
        case "waiting":
            if let detail = session.detail, !detail.isEmpty { return "waiting for permission: \(detail)" }
            return "waiting for you"
        case "done":
            return "finished"
        default:
            return session.state
        }
    }

    private static func minutesElapsed(updatedAtMs: Int64, now: Date) -> Int {
        let seconds = max(0, now.timeIntervalSince1970 - TimeInterval(updatedAtMs) / 1000)
        return Int(seconds / 60)
    }

    private static func accessibleTime(updatedAtMs: Int64, now: Date) -> String {
        let minutes = minutesElapsed(updatedAtMs: updatedAtMs, now: now)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    }
}
