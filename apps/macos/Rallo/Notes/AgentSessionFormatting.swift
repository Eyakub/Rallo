import Foundation

extension AgentSessionSnapshot {
    /// Unique across agents: `sessionId` alone repeats between Claude Code
    /// and Codex.
    var rowID: String { "\(agent)#\(sessionId)" }
}

/// Formats an `AgentSessionSnapshot` for the panel's "Agents" section
/// (docs/decisions/0007). Pure and UI-free so it's unit-testable.
enum AgentSessionFormatting {
    /// Waiting rows first, most recently updated within each group. (The
    /// core lists only waiting rows now; the order still holds for any.)
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

    /// Where the agent runs: the last two path components of `cwd`
    /// ("haat/raw" and "circuit/raw" stay apart), "~" for the home folder,
    /// or nil for a nil or empty `cwd`.
    static func place(cwd: String?, home: String = NSHomeDirectory()) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if cwd == home { return "~" }
        let parts = (cwd as NSString).pathComponents.filter { $0 != "/" }
        return parts.isEmpty ? nil : parts.suffix(2).joined(separator: "/")
    }

    /// The terminal app Rallo found for the session ("cmux"), if any.
    static func appName(appPath: String?) -> String? {
        guard let appPath, !appPath.isEmpty else { return nil }
        return ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// "Claude Code · code/rallo", or "Claude Code" alone when `cwd` is nil.
    static func title(for session: AgentSessionSnapshot) -> String {
        let name = agentName(session.agent)
        guard let place = place(cwd: session.cwd) else { return name }
        return "\(name) · \(place)"
    }

    /// What the agent is asking, plus its terminal when known: "Asks to use
    /// Bash · cmux", "Has a question for you", "Waiting for your answer".
    static func subtitle(for session: AgentSessionSnapshot) -> String {
        let ask: String
        switch (session.state, session.detail ?? "") {
        case ("waiting", "AskUserQuestion"): ask = "Has a question for you"
        case ("waiting", ""): ask = "Waiting for your answer"
        case let ("waiting", tool): ask = "Asks to use \(tool)"
        default: ask = session.state.capitalized
        }
        guard let app = appName(appPath: session.appPath) else { return ask }
        return "\(ask) · \(app)"
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
        let location = place(cwd: session.cwd).map { " in \($0)" } ?? ""
        return "\(name)\(location), \(accessibleState(for: session)), \(accessibleTime(updatedAtMs: session.updatedAtMs, now: now))"
    }

    /// "Claude Code is waiting in shop", for the long-wait notification's
    /// title (0008). Its body is `subtitle(for:)`.
    static func notificationTitle(for session: AgentSessionSnapshot) -> String {
        let name = agentName(session.agent)
        guard let place = place(cwd: session.cwd) else { return "\(name) is waiting" }
        return "\(name) is waiting in \(place)"
    }

    /// "Claude Code in shop is waiting for permission: Bash.", for the
    /// VoiceOver announcement when a session enters `waiting` (0008).
    static func waitingAnnouncement(for session: AgentSessionSnapshot) -> String {
        let name = agentName(session.agent)
        let location = place(cwd: session.cwd).map { " in \($0)" } ?? ""
        return "\(name)\(location) is \(accessibleState(for: session))."
    }

    /// Reads after "is": "asking to use Bash", "asking you a question".
    static func accessibleState(for session: AgentSessionSnapshot) -> String {
        switch (session.state, session.detail ?? "") {
        case ("waiting", "AskUserQuestion"): "asking you a question"
        case ("waiting", ""): "waiting for your answer"
        case let ("waiting", tool): "asking to use \(tool)"
        default: session.state
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
