import Foundation

/// Identifiers for the long-wait notification (0008): `rallo.agent.<scope>.
/// <agent>.<session>`, a namespace the reminder reconciler's
/// `rallo.reminder.<scope>.` prefix (0005) never touches. `<scope>` is
/// shared with the reminder prefix rather than fetched separately: both are
/// the same per-data-directory scope `NotificationDrainer` already asks the
/// core for via `notificationIdentifierPrefix()`.
enum AgentNotificationIdentifier {
    static let prefix = "rallo.agent."

    /// Extracts `<scope>` from a reminder prefix shaped
    /// `rallo.reminder.<scope>.`.
    static func scope(fromReminderPrefix reminderPrefix: String) -> String {
        String(reminderPrefix.dropFirst(NotificationAdapter.reminderPrefix.count).dropLast())
    }

    static func make(scope: String, agent: String, sessionId: String) -> String {
        "\(prefix)\(scope).\(agent).\(sessionId)"
    }
}
