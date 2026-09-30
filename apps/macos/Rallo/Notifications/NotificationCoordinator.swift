import AppKit
import UserNotifications

/// Receives native notification callbacks for the running app. Presents
/// banners while running, routes clicks to the notes panel, and hands the
/// Done/Snooze actions to the core, which checks them against the current
/// generation (0005). Dismissal is never acknowledgement.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    let adapter = NotificationAdapter()
    private let log: DiagnosticsLog

    /// Called on the main thread with the item ID from the notification, if any.
    var onOpenItem: (String?) -> Void = { _ in }
    /// Called on the main thread for an explicit Done/Snooze action.
    var onAction: (_ reminderID: String, _ generation: Int64, _ action: NotificationAction, _ itemID: String?) -> Void
        = { _, _, _, _ in }
    /// Called on the main thread for a click on a long-wait notification
    /// (0008): its identifier has `AgentNotificationIdentifier.prefix`.
    var onActivateAgent: (_ agent: String, _ sessionId: String) -> Void = { _, _ in }

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
        let request = response.notification.request
        if request.identifier.hasPrefix(NotificationAdapter.agentPrefix) {
            let userInfo = request.content.userInfo
            let agent = userInfo["agent"] as? String
            let sessionId = userInfo["session_id"] as? String
            DispatchQueue.main.async { [onActivateAgent] in
                if response.actionIdentifier != UNNotificationDismissActionIdentifier, let agent, let sessionId {
                    onActivateAgent(agent, sessionId)
                }
                completionHandler()
            }
            return
        }
        let userInfo = request.content.userInfo
        let itemID = userInfo["item_id"] as? String
        let reminderID = userInfo["reminder_id"] as? String
        let generation = (userInfo["generation"] as? NSNumber)?.int64Value
        let action: NotificationAction? = switch response.actionIdentifier {
        case NotificationDrainer.doneAction: .done
        case NotificationDrainer.snoozeAction: .snooze10m
        default: nil
        }
        DispatchQueue.main.async { [onOpenItem, onAction] in
            if let action, let reminderID, let generation {
                onAction(reminderID, generation, action, itemID)
            } else if response.actionIdentifier != UNNotificationDismissActionIdentifier {
                onOpenItem(itemID)
            }
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
