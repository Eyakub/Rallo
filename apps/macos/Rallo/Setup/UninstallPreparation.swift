import Foundation
import ServiceManagement
import UserNotifications

/// Undoes what macOS ties to the bundle ID rather than to a data directory:
/// the Login Item, scheduled notifications and the ClickUp Keychain token and voice API keys.
/// `rallo uninstall` quits the app, then runs
/// `Rallo.app/Contents/MacOS/Rallo --prepare-uninstall` as a child and reads
/// the one JSON object this prints. It runs before NSApplication starts (like
/// `--probe`), so no window, pet or database is ever opened.
enum UninstallPreparation {
    static func run() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            emit(await prepare())
            done.signal()
        }
        done.wait()
        return 0
    }

    private static func prepare() async -> [String: Any] {
        // Every request in this bundle's center is Rallo's. Notes are kept,
        // and a reinstall reschedules future reminders (missing_from_readback).
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().count
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        // The removals are asynchronous and this process exits right after;
        // a read on the same connection returns only once they are done.
        _ = await center.pendingNotificationRequests()

        var loginItem = "not_registered"
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            do {
                try await SMAppService.mainApp.unregister()
                loginItem = "removed"
            } catch {
                loginItem = "failed"
            }
        default:
            break
        }

        let token: String
        switch ClickUpToken.delete() {
        case errSecSuccess: token = "removed"
        case errSecItemNotFound: token = "none"
        default: token = "failed"
        }
        let voiceKeys: String
        switch KeychainSecret(service: CloudVoiceProvider.keychainService, label: "").delete() {
        case errSecSuccess: voiceKeys = "removed"
        case errSecItemNotFound: voiceKeys = "none"
        default: voiceKeys = "failed"
        }
        return ["login_item": loginItem, "notifications_removed": pending, "clickup_token": token, "voice_api_keys": voiceKeys]
    }

    private static func emit(_ report: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
