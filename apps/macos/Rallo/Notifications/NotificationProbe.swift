import Foundation
import UserNotifications

/// Developer characterization of native notification behaviour, run as
/// `Rallo.app/Contents/MacOS/Rallo --probe <command> ...` so requests use the
/// installed app identity. Prints one JSON document and exits.
///
/// Probe requests use the `rallo.probe.` prefix and never touch reminders.
/// Content is generic test text; no user data is involved.
enum NotificationProbe {
    static func run(arguments: [String]) -> Int32 {
        var exitCode: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let (code, report) = await execute(arguments)
            exitCode = code
            emit(report)
            done.signal()
        }
        done.wait()
        return exitCode
    }

    private static let adapter = NotificationAdapter()
    private static let prefix = NotificationAdapter.probePrefix

    private static func execute(_ arguments: [String]) async -> (Int32, [String: Any]) {
        let command = arguments.first ?? ""
        let rest = Array(arguments.dropFirst())
        // Over the pending limit macOS silently evicts arbitrary requests, so
        // bulk probes must never share the queue with real reminders.
        if ["capacity", "deliver"].contains(command),
           !(await adapter.pending(prefix: NotificationAdapter.reminderPrefix)).isEmpty {
            return (4, ["error": "refusing bulk probe: Rallo reminders are pending and could be evicted"])
        }
        switch command {
        case "status":
            return (0, await status())
        case "capacity" where (1...2).contains(rest.count) && Int(rest[0]) != nil:
            return (0, await capacity(count: Int(rest[0])!, reverseDeadlines: rest.count == 2 && rest[1] == "reverse"))
        case "deliver" where rest.count == 2 && Int(rest[0]) != nil && Double(rest[1]) != nil:
            return (0, await deliver(count: Int(rest[0])!, delay: Double(rest[1])!))
        case "min-delay":
            return (0, await minimumDelay())
        case "schedule" where rest.count >= 2 && Double(rest[1]) != nil:
            return (0, await schedule(tag: rest[0], delay: Double(rest[1])!, itemID: rest.count > 2 ? rest[2] : nil))
        case "inspect":
            return (0, await inspect())
        case "inspect-reminders" where rest.count <= 1:
            return (0, await inspectReminders(prefix: rest.first ?? NotificationAdapter.reminderPrefix))
        case "remove-reminders" where !rest.isEmpty && rest.allSatisfy({ $0.hasPrefix(NotificationAdapter.reminderPrefix) }):
            adapter.removePending(rest)
            adapter.removeDelivered(rest)
            return (0, ["removed": rest])
        case "cancel" where rest.count == 1:
            return (0, await cancel(tag: rest[0]))
        case "cleanup":
            return (0, await cleanup(prefix: prefix))
        default:
            return (2, ["error": "usage: --probe status | capacity N | deliver N DELAY_S | min-delay | schedule TAG DELAY_S [ITEM_ID] | inspect | inspect-reminders [PREFIX] | remove-reminders ID... | cancel TAG | cleanup"])
        }
    }

    // MARK: Commands

    private static func status() async -> [String: Any] {
        let settings = await adapter.settings()
        return [
            "bundle_identifier": Bundle.main.bundleIdentifier ?? "",
            "bundle_path": Bundle.main.bundlePath,
            "authorization_status": settings.authorizationStatus.name,
            "alert_setting": settings.alertSetting.name,
            "notification_center_setting": settings.notificationCenterSetting.name,
            "sound_setting": settings.soundSetting.name,
            "alert_style": settings.alertStyle.rawValue,
            "pending_rallo_owned": await adapter.pending(prefix: "rallo.").count,
            "delivered_rallo_owned": await adapter.delivered(prefix: "rallo.").count,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    /// Submits N far-future requests, reads them back, verifies each trigger
    /// instant, then removes them and confirms removal. With
    /// `reverseDeadlines`, later submissions get earlier deadlines, which
    /// shows whether an over-limit drop is by submission order or deadline.
    private static func capacity(count: Int, reverseDeadlines: Bool) async -> [String: Any] {
        let group = prefix + "capacity."
        _ = await cleanup(prefix: group)
        let base = Date().addingTimeInterval(3600).timeIntervalSince1970.rounded(.up)
        var addErrors: [String] = []
        let started = Date()
        func slot(_ index: Int) -> Double { Double((reverseDeadlines ? count - 1 - index : index) * 60) }
        for index in 0..<count {
            let deadline = Date(timeIntervalSince1970: base + slot(index))
            do {
                try await adapter.add(request(id: "\(group)\(index)", deadline: deadline, body: "Capacity probe \(index + 1)/\(count)"))
            } catch {
                addErrors.append("\(index): \(error.localizedDescription)")
            }
        }
        let addMs = Date().timeIntervalSince(started) * 1000
        let readStarted = Date()
        let pending = await adapter.pending(prefix: group)
        let readMs = Date().timeIntervalSince(readStarted) * 1000
        var mismatches: [String] = []
        for request in pending {
            guard let index = Double(request.identifier.dropFirst(group.count)),
                  let trigger = request.trigger as? UNCalendarNotificationTrigger else { continue }
            let expected = base + slot(Int(index))
            let actual = trigger.nextTriggerDate()?.timeIntervalSince1970
            if actual != expected { mismatches.append("\(request.identifier): expected \(expected) got \(actual.map { "\($0)" } ?? "nil")") }
        }
        let surviving = pending.compactMap { Int($0.identifier.dropFirst(group.count)) }.sorted()
        adapter.removePending(pending.map(\.identifier))
        try? await Task.sleep(nanoseconds: 500_000_000)
        let remaining = await adapter.pending(prefix: group).count
        return [
            "reverse_deadlines": reverseDeadlines,
            "surviving_submission_index_min": surviving.first ?? NSNull(),
            "surviving_submission_index_max": surviving.last ?? NSNull(),
            "dropped_submission_indices": Array(Set(0..<count).subtracting(surviving)).sorted(),
            "requested": count,
            "add_errors": addErrors.count,
            "add_error_samples": Array(addErrors.prefix(5)),
            "pending_after_add": pending.count,
            "trigger_mismatches": mismatches.count,
            "trigger_mismatch_samples": Array(mismatches.prefix(5)),
            "add_total_ms": round(addMs),
            "readback_ms": round(readMs),
            "pending_after_remove": remaining,
        ]
    }

    /// Schedules N requests for one instant and checks actual delivery.
    private static func deliver(count: Int, delay: Double) async -> [String: Any] {
        let group = prefix + "deliver."
        _ = await cleanup(prefix: group)
        let deadline = Date().addingTimeInterval(delay)
        let whole = deadline.timeIntervalSince1970.rounded(.up)
        var addErrors = 0
        for index in 0..<count {
            do {
                try await adapter.add(request(id: "\(group)\(index)", deadline: deadline, body: "Delivery probe \(index + 1)/\(count)"))
            } catch {
                addErrors += 1
            }
        }
        let pendingAfterAdd = await adapter.pending(prefix: group).count
        try? await Task.sleep(nanoseconds: UInt64((delay + 10) * 1_000_000_000))
        let delivered = await adapter.delivered(prefix: group)
        let pendingAfter = await adapter.pending(prefix: group).count
        let lateness = delivered.map { $0.date.timeIntervalSince1970 - whole }.sorted()
        _ = await cleanup(prefix: group)
        return [
            "requested": count,
            "add_errors": addErrors,
            "pending_after_add": pendingAfterAdd,
            "delivered": delivered.count,
            "pending_after_deadline": pendingAfter,
            "delivery_lateness_s_min": lateness.first ?? NSNull(),
            "delivery_lateness_s_max": lateness.last ?? NSNull(),
        ]
    }

    /// Characterises very short and already-elapsed deadlines.
    private static func minimumDelay() async -> [String: Any] {
        let group = prefix + "mindelay."
        _ = await cleanup(prefix: group)
        let offsets: [Double] = [-10, -1, 0, 0.25, 0.5, 1, 2, 5]
        let now = Date()
        var rows: [[String: Any]] = []
        for (index, offset) in offsets.enumerated() {
            let deadline = now.addingTimeInterval(offset)
            let id = "\(group)\(index)"
            let built = request(id: id, deadline: deadline, body: "Minimum-delay probe \(offset)s")
            let next = (built.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            var row: [String: Any] = [
                "offset_s": offset,
                "next_trigger_minus_now_s": next.map { $0.timeIntervalSince(now) } ?? NSNull(),
            ]
            do {
                try await adapter.add(built)
                row["accepted"] = true
            } catch {
                row["accepted"] = false
                row["error"] = error.localizedDescription
            }
            row["id"] = id
            rows.append(row)
        }
        let pendingNow = Set(await adapter.pending(prefix: group).map(\.identifier))
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        let delivered = Dictionary(uniqueKeysWithValues: await adapter.delivered(prefix: group).map { ($0.request.identifier, $0.date) })
        let pendingLater = Set(await adapter.pending(prefix: group).map(\.identifier))
        for index in rows.indices {
            let id = rows[index]["id"] as! String
            rows[index]["pending_right_after_add"] = pendingNow.contains(id)
            rows[index]["delivered_within_12s"] = delivered[id] != nil
            rows[index]["delivered_after_start_s"] = delivered[id].map { $0.timeIntervalSince(now) } ?? NSNull()
            rows[index]["pending_after_12s"] = pendingLater.contains(id)
        }
        _ = await cleanup(prefix: group)
        return ["results": rows]
    }

    private static func schedule(tag: String, delay: Double, itemID: String?) async -> [String: Any] {
        let id = prefix + "persist." + tag
        let deadline = Date().addingTimeInterval(delay)
        let built = request(id: id, deadline: deadline, body: "Test reminder “\(tag)”", itemID: itemID)
        do {
            try await adapter.add(built)
        } catch {
            return ["identifier": id, "accepted": false, "error": error.localizedDescription]
        }
        let pending = await adapter.pending(prefix: id).first
        let next = (pending?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        return [
            "identifier": id,
            "accepted": true,
            "deadline_epoch_s": deadline.timeIntervalSince1970.rounded(.up),
            "pending_readback": pending != nil,
            "next_trigger_epoch_s": next?.timeIntervalSince1970 ?? NSNull(),
        ]
    }

    private static func inspect() async -> [String: Any] {
        let pending = await adapter.pending(prefix: prefix).map { request -> [String: Any] in
            let next = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            return ["identifier": request.identifier, "next_trigger_epoch_s": next?.timeIntervalSince1970 ?? NSNull()]
        }
        let delivered = await adapter.delivered(prefix: prefix).map { notification -> [String: Any] in
            ["identifier": notification.request.identifier, "delivered_epoch_s": notification.date.timeIntervalSince1970]
        }
        return ["now_epoch_s": Date().timeIntervalSince1970, "pending": pending, "delivered": delivered]
    }

    /// Read-only view of reminder requests for end-to-end checks: identifiers,
    /// generation, and trigger instants only — never notification text.
    private static func inspectReminders(prefix: String) async -> [String: Any] {
        func fields(_ request: UNNotificationRequest) -> [String: Any] {
            let native = request.native
            return [
                "identifier": request.identifier,
                "generation": native.generation ?? NSNull(),
                "trigger_ms": native.triggerMs ?? NSNull(),
            ]
        }
        let pending = await adapter.pending(prefix: prefix).map(fields)
        let delivered = await adapter.delivered(prefix: prefix).map { notification -> [String: Any] in
            var entry = fields(notification.request)
            entry["delivered_ms"] = Int64(notification.date.timeIntervalSince1970 * 1000)
            return entry
        }
        return ["now_ms": Int64(Date().timeIntervalSince1970 * 1000), "pending": pending, "delivered": delivered]
    }

    private static func cancel(tag: String) async -> [String: Any] {
        let id = prefix + "persist." + tag
        adapter.removePending([id])
        adapter.removeDelivered([id])
        try? await Task.sleep(nanoseconds: 500_000_000)
        return [
            "identifier": id,
            "pending_after_cancel": await adapter.pending(prefix: id).count,
            "delivered_after_cancel": await adapter.delivered(prefix: id).count,
        ]
    }

    private static func cleanup(prefix: String) async -> [String: Any] {
        let pending = await adapter.pending(prefix: prefix).map(\.identifier)
        let delivered = await adapter.delivered(prefix: prefix).map(\.request.identifier)
        adapter.removePending(pending)
        adapter.removeDelivered(delivered)
        return ["removed_pending": pending.count, "removed_delivered": delivered.count]
    }

    // MARK: Helpers

    private static func request(id: String, deadline: Date, body: String, itemID: String? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Rallo test notification"
        content.body = body
        content.threadIdentifier = "rallo.probe"
        var info: [String: Any] = ["probe": id]
        if let itemID { info["item_id"] = itemID }
        content.userInfo = info
        return UNNotificationRequest(identifier: id, content: content, trigger: NotificationAdapter.trigger(at: deadline))
    }

    private static func round(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func emit(_ report: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
