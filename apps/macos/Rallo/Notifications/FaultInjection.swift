import Foundation

/// End-to-end crash windows for the notification protocol (0005). The app
/// exits abruptly at the chosen point so a relaunch has to recover from the
/// real UserNotifications state. Accepted only for an explicit, non-default
/// data directory, so it can never affect a user's own reminders.
struct FaultInjection {
    enum Point: String {
        case afterBegin = "after_begin"
        case afterAdd = "after_add"
        case afterRemove = "after_remove"
    }

    let point: Point
    let log: DiagnosticsLog

    init?(argument: String?, explicitDataDir: String?, log: DiagnosticsLog) {
        guard let argument, let point = Point(rawValue: argument), let explicitDataDir else { return nil }
        let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Razlio/Rallo").standardizedFileURL.path
        guard URL(fileURLWithPath: explicitDataDir).standardizedFileURL.path != defaultDir else { return nil }
        self.point = point
        self.log = log
    }

    func hit(_ point: Point) {
        guard point == self.point else { return }
        log.record("fault_injected", ["point": point.rawValue])
        log.flush()
        _exit(86)
    }
}
