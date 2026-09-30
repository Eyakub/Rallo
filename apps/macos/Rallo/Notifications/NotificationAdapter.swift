import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter. Only the installed app submits,
/// queries, or removes native requests, and it manages only Rallo-owned
/// identifiers.
struct NotificationAdapter {
    static let reminderPrefix = "rallo.reminder."
    static let probePrefix = "rallo.probe."
    static let agentPrefix = AgentNotificationIdentifier.prefix

    let center = UNUserNotificationCenter.current()

    /// One-shot trigger for a fixed UTC instant. Uses full date components in
    /// an explicit UTC calendar, never local hour/minute alone, and rounds up
    /// to a whole second so an alert is never early.
    static func trigger(at deadline: Date) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let whole = Date(timeIntervalSince1970: deadline.timeIntervalSince1970.rounded(.up))
        let components = calendar.dateComponents(
            [.calendar, .timeZone, .era, .year, .month, .day, .hour, .minute, .second], from: whole)
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    func settings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func pending(prefix: String) async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
    }

    func delivered(prefix: String) async -> [UNNotification] {
        await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix(prefix) }
    }

    func removePending(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

extension UNAuthorizationStatus {
    var name: String {
        switch self {
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown_\(rawValue)"
        }
    }
}

extension UNNotificationSetting {
    var name: String {
        switch self {
        case .notSupported: "not_supported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown_\(rawValue)"
        }
    }
}
