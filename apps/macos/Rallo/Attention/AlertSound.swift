import AppKit
import UserNotifications

/// The chimes (0021 §6): Settings titles, the bundled files, the banner's
/// sound, and the in-app chime for nag rounds and the Settings preview.
extension AlertSound {
    static let menuOrder: [AlertSound] = [.ralloChime, .bambooKnock, .gentleBell, .system, .none]

    var title: String {
        switch self {
        case .ralloChime: "Rallo Chime"
        case .bambooKnock: "Bamboo Knock"
        case .gentleBell: "Gentle Bell"
        case .system: "System default"
        case .none: "None"
        }
    }

    /// Made by scripts/make-chimes.py; nil for System default and None.
    var fileName: String? {
        switch self {
        case .ralloChime: "rallo-chime.caf"
        case .bambooKnock: "bamboo-knock.caf"
        case .gentleBell: "gentle-bell.caf"
        case .system, .none: nil
        }
    }

    /// The banner's sound. Where macOS looks for the file is spike S3's
    /// question (Task 11c changes only this seam's setup, never its callers).
    var notificationSound: UNNotificationSound? {
        switch self {
        case .none: nil
        case .system: .default
        case .ralloChime, .bambooKnock, .gentleBell: fileName.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
        }
    }

    @MainActor private static var player: NSSound?

    /// Nag rounds and the Settings preview; System default is the alert beep.
    @MainActor func play() {
        switch self {
        case .none:
            return
        case .system:
            NSSound.beep()
        case .ralloChime, .bambooKnock, .gentleBell:
            guard let fileName, let url = Bundle.main.url(forResource: fileName, withExtension: nil) else { return NSSound.beep() }
            Self.player?.stop()
            Self.player = NSSound(contentsOf: url, byReference: true)
            Self.player?.play()
        }
    }
}
