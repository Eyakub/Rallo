import AppKit
import UserNotifications

/// Receives native notification callbacks for the running app.
///
/// M0 prototype: presents banners while running and routes clicks to the
/// notes panel. The durable intent/attempt protocol arrives in M2. Actions
/// carry IDs only; the item is always reloaded before anything is shown.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    let adapter = NotificationAdapter()
    private let log: DiagnosticsLog

    /// Called on the main thread with the item ID from the notification, if any.
    var onOpenItem: (String?) -> Void = { _ in }

    init(log: DiagnosticsLog) {
        self.log = log
    }

    /// Only ever called from an explicit GUI action.
    func requestAuthorization() async -> Result<Bool, Error> {
        do {
            let granted = try await adapter.requestAuthorization()
            log.record("notification_authorization_requested", ["granted": granted])
            return .success(granted)
        } catch {
            log.record("notification_authorization_failed", ["error": "\(error)"])
            return .failure(error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        log.record("notification_will_present", Self.ids(notification.request))
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        var fields = Self.ids(response.notification.request)
        fields["action"] = response.actionIdentifier
        log.record("notification_response", fields)
        let itemID = response.notification.request.content.userInfo["item_id"] as? String
        DispatchQueue.main.async { [onOpenItem] in
            onOpenItem(itemID)
            completionHandler()
        }
    }

    /// Identifiers only: notification content may contain note text.
    private static func ids(_ request: UNNotificationRequest) -> [String: Any] {
        var fields: [String: Any] = ["identifier": request.identifier]
        for key in ["item_id", "reminder_id", "generation", "probe"] {
            if let value = request.content.userInfo[key] { fields[key] = value }
        }
        return fields
    }
}
