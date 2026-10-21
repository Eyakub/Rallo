import Foundation

/// 0024 §3: at most once a day, and only when something changed.
enum BackupSchedule {
    static let interval: TimeInterval = 24 * 60 * 60

    static func isDue(now: Date, lastSuccess: Date?, lastRevision: Int64?, revision: Int64) -> Bool {
        guard revision != lastRevision else { return false }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= interval
    }
}

/// 0024 §5: keep the newest few of this Mac's backups.
enum BackupRetention {
    static let keep = 2

    /// `handles` run oldest first.
    static func split(_ handles: [String], keep: Int) -> (kept: [String], removed: [String]) {
        let cut = max(0, handles.count - keep)
        return (Array(handles[cut...]), Array(handles[..<cut]))
    }
}

/// 0024 §2: `Rallo Backup <Mac name> <yyyy-MM-dd HH.mm.ss>.zip` (seconds, so two backups in one minute never collide).
enum BackupNaming {
    static func fileName(mac: String, date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let cleaned = mac.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Mac" : cleaned
        return "Rallo Backup \(name) \(formatter.string(from: date)).zip"
    }
}
