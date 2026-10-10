import Foundation
import UserNotifications

/// Posts the opt-in long-wait notification (0008): one `UNNotificationRequest`
/// per waiting period once a session has waited `thresholdSeconds`, withdrawn
/// as soon as it leaves `waiting` or is dismissed. Decisions are
/// `AgentWaitPlanner`'s; this only performs the native effect and re-arms a
/// timer for the next threshold crossing.
@MainActor
final class AgentWaitNotifier {
    /// Hidden testing aid (0008): `-RalloAgentLongWaitSeconds 5` shortens the
    /// wait for a scratch instance. Honoured only with an explicit
    /// `--data-dir`, never for the user's real data directory.
    static let overrideDefaultsKey = "RalloAgentLongWaitSeconds"
    private static let defaultThresholdSeconds: Double = 300

    private let adapter: NotificationAdapter
    private let log: DiagnosticsLog
    private let allowThresholdOverride: Bool
    private var notified: [String: Int64] = [:]
    private var wakeTimer: Timer?
    private var lastSessions: [AgentSessionSnapshot] = []
    private var lastScope: String?

    /// The `agents.notify_long_wait` preference.
    var isEnabled: () -> Bool = { false }
    /// Whether macOS will actually show what's posted (0005's authorization).
    var isAuthorized: () -> Bool = { false }
    /// The chosen chime (0021 §6), read at each post.
    var alertSound: () -> AlertSound = { .ralloChime }
    /// 0021 §2, §4: every post and withdrawal also reaches the attention coordinator.
    var onPost: (AgentSessionSnapshot, String) -> Void = { _, _ in }
    var onWithdraw: ([String]) -> Void = { _ in }

    init(adapter: NotificationAdapter, log: DiagnosticsLog, allowThresholdOverride: Bool) {
        self.adapter = adapter
        self.log = log
        self.allowThresholdOverride = allowThresholdOverride
    }

    private var thresholdSeconds: Double {
        guard allowThresholdOverride else { return Self.defaultThresholdSeconds }
        let value = UserDefaults.standard.double(forKey: Self.overrideDefaultsKey)
        return value > 0 ? value : Self.defaultThresholdSeconds
    }

    /// Called from the same reload path the panel and pet use
    /// (`AppCoordinator.reloadFromCore`), with sessions and the reminder
    /// identifier prefix it has already fetched this pass.
    func reload(sessions: [AgentSessionSnapshot], reminderPrefix: String) {
        lastSessions = sessions
        lastScope = AgentNotificationIdentifier.scope(fromReminderPrefix: reminderPrefix)
        apply()
    }

    /// The preference just turned off, or a session was dismissed/finished
    /// between reloads: nothing here waits for the next scheduled wake.
    private func apply() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard let scope = lastScope else { return }
        guard isEnabled() else {
            withdrawAll()
            return
        }
        let plan = AgentWaitPlanner.plan(
            sessions: lastSessions, scope: scope, thresholdSeconds: thresholdSeconds, now: Date(), notified: notified)
        if !plan.toWithdraw.isEmpty {
            adapter.removePending(plan.toWithdraw)
            adapter.removeDelivered(plan.toWithdraw)
            onWithdraw(plan.toWithdraw)
        }
        notified = plan.notified
        for (session, identifier) in plan.toPost {
            post(session: session, identifier: identifier)
        }
        if let nextWakeAtMs = AgentWaitPlanner.nextWakeAtMs(
            sessions: lastSessions, scope: scope, thresholdSeconds: thresholdSeconds, notified: notified
        ) {
            armWake(at: nextWakeAtMs)
        }
    }

    /// The preference turned off: every outstanding long-wait notification
    /// is withdrawn immediately, pending and delivered.
    func withdrawAll() {
        guard !notified.isEmpty else { return }
        let identifiers = Array(notified.keys)
        adapter.removePending(identifiers)
        adapter.removeDelivered(identifiers)
        notified.removeAll()
        onWithdraw(identifiers)
    }

    private func armWake(at ms: Int64) {
        let interval = max(0.5, TimeInterval(ms) / 1000 - Date().timeIntervalSince1970 + 0.05)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    private func post(session: AgentSessionSnapshot, identifier: String) {
        // Before the permission guard: the summon needs no notification permission.
        onPost(session, identifier)
        guard isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = AgentSessionFormatting.notificationTitle(for: session)
        content.body = AgentSessionFormatting.subtitle(for: session)
        content.sound = alertSound().notificationSound
        content.userInfo = ["agent": session.agent, "session_id": session.sessionId]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            do {
                try await adapter.add(request)
                log.record("agent_wait_notified", ["identifier": identifier])
            } catch {
                log.record("agent_wait_notify_failed", ["identifier": identifier, "error": "\(error)"])
            }
        }
    }
}
