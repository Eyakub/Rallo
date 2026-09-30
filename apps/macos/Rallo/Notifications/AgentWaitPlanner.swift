import Foundation

/// Pure "once per waiting period" decisions for the long-wait notification
/// (0008), so `AgentWaitNotifier` is a thin native-effect shell around a
/// unit-testable planner. `notified` maps an identifier to the
/// `updatedAtMs` of the session at the moment it was posted: `state_seq`
/// isn't exposed over FFI, but a session's `updated_at_ms` already advances
/// on every waiting-period boundary the 5-minute countdown itself is
/// anchored to (a new detail restarts both), so it's an equally good key.
enum AgentWaitPlanner {
    struct Plan {
        var toPost: [(session: AgentSessionSnapshot, identifier: String)] = []
        var toWithdraw: [String] = []
        var notified: [String: Int64] = [:]
    }

    /// Sessions that have waited at least `thresholdSeconds` and have not
    /// already been notified for their current waiting period get `toPost`;
    /// identifiers whose session left `waiting` (done, dismissed, or a new
    /// waiting period started) get `toWithdraw`.
    static func plan(
        sessions: [AgentSessionSnapshot],
        scope: String,
        thresholdSeconds: Double,
        now: Date,
        notified: [String: Int64]
    ) -> Plan {
        let waiting = sessions.filter { $0.state == "waiting" }
        var waitingByIdentifier: [String: AgentSessionSnapshot] = [:]
        for session in waiting {
            waitingByIdentifier[identifier(scope: scope, session: session)] = session
        }

        var result = notified
        var toWithdraw: [String] = []
        for (identifier, notifiedAtUpdatedMs) in notified {
            guard waitingByIdentifier[identifier]?.updatedAtMs == notifiedAtUpdatedMs else {
                // Gone, done, dismissed, or a new waiting period started
                // (a different tool): the delivered notification is stale.
                toWithdraw.append(identifier)
                result.removeValue(forKey: identifier)
                continue
            }
        }

        var toPost: [(AgentSessionSnapshot, String)] = []
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        for session in waiting {
            let sessionIdentifier = identifier(scope: scope, session: session)
            guard result[sessionIdentifier] == nil else { continue }
            guard Double(nowMs - session.updatedAtMs) / 1000 >= thresholdSeconds else { continue }
            toPost.append((session, sessionIdentifier))
            result[sessionIdentifier] = session.updatedAtMs
        }

        return Plan(toPost: toPost, toWithdraw: toWithdraw, notified: result)
    }

    /// The next moment a currently-waiting, not-yet-notified session crosses
    /// the threshold, or `nil` if there is nothing to wait for (the next
    /// `reload()` — a store change — is what picks up a new candidate).
    static func nextWakeAtMs(
        sessions: [AgentSessionSnapshot], scope: String, thresholdSeconds: Double, notified: [String: Int64]
    ) -> Int64? {
        let thresholdMs = Int64((thresholdSeconds * 1000).rounded())
        return sessions
            .filter { $0.state == "waiting" }
            .compactMap { session -> Int64? in
                guard notified[identifier(scope: scope, session: session)] == nil else { return nil }
                return session.updatedAtMs + thresholdMs
            }
            .min()
    }

    private static func identifier(scope: String, session: AgentSessionSnapshot) -> String {
        AgentNotificationIdentifier.make(scope: scope, agent: session.agent, sessionId: session.sessionId)
    }
}
