import Foundation
import UserNotifications

/// The single drainer of notification intents (docs/decisions/0005). The core
/// decides what to do; this only reports native evidence, performs the one
/// effect it is handed, reads it back, and reports the outcome.
///
/// Passes never overlap: `requestDrain` while a pass runs only asks for one
/// more pass afterwards. An actor would not be enough, since its awaits could
/// interleave two passes.
@MainActor
final class NotificationDrainer {
    static let categoryIdentifier = "rallo.reminder"
    static let doneAction = "rallo.done"
    static let snoozeAction = "rallo.snooze.10m"

    private let core: CoreClient
    private let adapter: NotificationAdapter
    private let log: DiagnosticsLog
    private let fault: FaultInjection?
    private var isDraining = false
    private var needsAnotherPass = false
    private var wakeTimer: Timer?
    /// This store's identifier prefix (0005): other data directories share
    /// the notification center, and their requests are never touched.
    private var prefix: String?

    /// Bounds a single pass; the core never hands out more than one piece of
    /// work per intent, so this is only a guard against a logic loop.
    private let maxWorkPerPass = 128

    init(core: CoreClient, adapter: NotificationAdapter, log: DiagnosticsLog, fault: FaultInjection?) {
        self.core = core
        self.adapter = adapter
        self.log = log
        self.fault = fault
    }

    static func registerCategories(on center: UNUserNotificationCenter) {
        let done = UNNotificationAction(identifier: doneAction, title: "Mark as Done")
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze 10 Minutes")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryIdentifier, actions: [done, snooze], intentIdentifiers: []),
        ])
    }

    func requestDrain(_ reason: String) {
        if isDraining {
            needsAnotherPass = true
            return
        }
        isDraining = true
        Task {
            repeat {
                needsAnotherPass = false
                await pass(reason)
            } while needsAnotherPass
            isDraining = false
        }
    }

    private func pass(_ reason: String) async {
        do {
            try await reconcile()
            for _ in 0..<maxWorkPerPass {
                switch try await core.nextPlatformWork() {
                case let .idle(nextWakeAtMs):
                    armWake(at: nextWakeAtMs)
                    return
                case let .work(work):
                    try await perform(work)
                }
            }
            log.record("drain_work_limit_reached", ["reason": reason])
        } catch {
            log.record("drain_failed", ["reason": reason, "error": "\(error)"])
            armWake(at: Int64(Date().timeIntervalSince1970 * 1000) + 5_000)
        }
    }

    /// Evidence first, then cleanup, so orphans are gone before new capacity
    /// is used.
    private func reconcile() async throws {
        let prefix = try await storePrefix()
        let settings = await adapter.settings()
        let pending = await adapter.pending(prefix: prefix)
        let delivered = await adapter.delivered(prefix: prefix)
        let plan = try await core.recordNativeObservations(
            authorization: settings.authorizationStatus.platform,
            pending: pending.map(\.native),
            delivered: delivered.map(\.request.native)
        )
        if !plan.removePending.isEmpty {
            adapter.removePending(plan.removePending)
            log.record("notification_cleanup_pending", ["count": plan.removePending.count])
        }
        if !plan.removeDelivered.isEmpty {
            adapter.removeDelivered(plan.removeDelivered)
            log.record("notification_cleanup_delivered", ["count": plan.removeDelivered.count])
        }
    }

    private func perform(_ work: PlatformWork) async throws {
        switch work {
        case let .schedule(intentId, reminderId, itemId, generation, deadlineMs, identifier, title, body):
            guard case let .started(token) = try await core.beginPlatformAttempt(intentId: intentId, generation: generation)
            else { return }
            fault?.hit(.afterBegin)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = await alertSound(reminderId: reminderId).notificationSound
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "reminder_id": reminderId, "item_id": itemId, "generation": generation, "deadline_ms": deadlineMs,
            ]
            let deadline = Date(timeIntervalSince1970: TimeInterval(deadlineMs) / 1000)
            let request = UNNotificationRequest(
                identifier: identifier, content: content, trigger: NotificationAdapter.trigger(at: deadline))
            let outcome: NativeOutcome
            do {
                try await adapter.add(request)
                fault?.hit(.afterAdd)
                // add() success is not acceptance: macOS can silently evict.
                let readback = await adapter.pending(prefix: identifier)
                    .first { $0.identifier == identifier && $0.native.generation == generation }
                if let triggerMs = readback?.native.triggerMs {
                    outcome = .accepted(readbackTriggerMs: triggerMs)
                } else {
                    // Missing, or listed without a future trigger: not accepted.
                    outcome = .notConfirmed
                }
            } catch {
                outcome = Self.outcome(for: error)
            }
            let finished = try await core.finishPlatformAttempt(token: token, outcome: outcome)
            log.record("notification_schedule", [
                "reminder_id": reminderId, "generation": generation, "outcome": "\(outcome)",
                "applied": finished.applied, "superseded": finished.superseded,
            ])
        case let .cancel(intentId, reminderId, generation, identifier):
            guard case let .started(token) = try await core.beginPlatformAttempt(intentId: intentId, generation: generation)
            else { return }
            adapter.removePending([identifier])
            adapter.removeDelivered([identifier])
            fault?.hit(.afterRemove)
            let stillPending = await adapter.pending(prefix: identifier).contains { $0.identifier == identifier }
            let outcome: NativeOutcome = stillPending ? .transientFailure(code: "still_pending") : .removed
            let finished = try await core.finishPlatformAttempt(token: token, outcome: outcome)
            log.record("notification_cancel", [
                "reminder_id": reminderId, "generation": generation, "outcome": "\(outcome)",
                "applied": finished.applied, "superseded": finished.superseded,
            ])
        }
    }

    /// The chosen chime (0021 §6), read from the core as each request is
    /// built. The core worker is FIFO, so the work a sound change queued is
    /// built with that sound, never the one from before it.
    private func alertSound(reminderId: String) async -> AlertSound {
        do {
            return try await core.alertSettings().sound
        } catch {
            log.record("drain_alert_sound_failed", ["reminder_id": reminderId, "error": "\(error)"])
            return .ralloChime
        }
    }

    private func storePrefix() async throws -> String {
        if let prefix { return prefix }
        let value = try await core.notificationIdentifierPrefix()
        prefix = value
        return value
    }

    private static func outcome(for error: Error) -> NativeOutcome {
        if let error = error as? UNError, error.code == .notificationsNotAllowed {
            return .permissionDenied
        }
        let nsError = error as NSError
        return .transientFailure(code: "\(nsError.domain)#\(nsError.code)")
    }

    /// With no retry due, a slow heartbeat still notices deliveries and
    /// authorization changes made in System Settings, which send no signal.
    private let heartbeat: TimeInterval = 60

    private func armWake(at ms: Int64?) {
        wakeTimer?.invalidate()
        let due = ms.map { TimeInterval($0) / 1000 - Date().timeIntervalSince1970 } ?? heartbeat
        let interval = min(max(0.05, due), heartbeat)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requestDrain("wake") }
        }
        timer.tolerance = min(1, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }
}

extension UNNotificationRequest {
    /// Rallo's native evidence: identifiers and generation from `userInfo`,
    /// and the trigger instant macOS will actually use. The core parses the
    /// identifier itself when `userInfo` lacks the reminder ID.
    var native: NativeRequest {
        let generation = (content.userInfo["generation"] as? NSNumber)?.int64Value
        let trigger = (trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        return NativeRequest(
            identifier: identifier,
            reminderId: content.userInfo["reminder_id"] as? String,
            generation: generation,
            triggerMs: trigger.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        )
    }
}

extension UNAuthorizationStatus {
    var platform: NotificationAuthorization {
        switch self {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .notDetermined
        }
    }
}
