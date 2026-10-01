import Foundation
import UserNotifications

/// Opt-in daily update check (0011): the embedded CLI's read-only
/// `rallo update --check --json`, at most once a day. It only tells the user
/// (menu item, one notification per version); installing stays in Settings →
/// About behind its confirmation.
@MainActor
final class UpdateChecker {
    nonisolated static let notificationPrefix = "rallo.update."
    static let enabledKey = "updateCheckEnabled"
    static let lastAtKey = "updateCheckLastAt"
    static let latestKey = "updateLatestVersion"
    static let notifiedKey = "updateNotifiedVersion"

    private static let interval: TimeInterval = 24 * 60 * 60

    private let log: DiagnosticsLog
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var checking = false

    /// False for a scratch instance: it never checks.
    var allowed = true
    var onChange: () -> Void = {}

    init(log: DiagnosticsLog) {
        self.log = log
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The stored latest version, only while it is newer than this app.
    var available: String? {
        guard allowed, let latest = defaults.string(forKey: Self.latestKey),
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              CLIReports.isNewer(latest, than: current) else { return nil }
        return latest
    }

    func start() {
        guard allowed, isEnabled, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        armTimer()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            guard allowed else { return }
            armTimer()
            checkIfDue()
        } else {
            timer?.invalidate()
            timer = nil
            defaults.removeObject(forKey: Self.latestKey)
            onChange()
        }
    }

    private func armTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        guard allowed, isEnabled, !checking else { return }
        let last = defaults.double(forKey: Self.lastAtKey)
        guard Date().timeIntervalSince1970 - last >= Self.interval else { return }
        Task { await check() }
    }

    func check() async {
        checking = true
        defer { checking = false }
        let outcome = CLIReports.updateOutcome(await EmbeddedCLI.run(["update", "--check", "--json"]))
        // Switched off while the check ran: keep it off.
        guard isEnabled else { return }
        let now = Date().timeIntervalSince1970
        switch outcome {
        case let .available(_, latest):
            defaults.set(latest, forKey: Self.latestKey)
            defaults.set(now, forKey: Self.lastAtKey)
            log.record("update_check", ["outcome": "available", "latest": latest])
            await notifyOnce(latest)
            onChange()
        case .upToDate:
            defaults.removeObject(forKey: Self.latestKey)
            defaults.set(now, forKey: Self.lastAtKey)
            log.record("update_check", ["outcome": "up_to_date"])
            onChange()
        case .failed:
            // lastAt stays, so the next hourly tick retries.
            log.record("update_check", ["outcome": "failed"])
        }
    }

    private func notifyOnce(_ latest: String) async {
        guard defaults.string(forKey: Self.notifiedKey) != latest else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rallo \(latest) is available"
        content.body = "Choose “Update to Rallo \(latest)…” in Rallo’s menu, or open Settings → About."
        let request = UNNotificationRequest(identifier: Self.notificationPrefix + latest, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            defaults.set(latest, forKey: Self.notifiedKey)
        } catch {
            log.record("update_notification_failed", ["error": "\(error)"])
        }
    }
}
