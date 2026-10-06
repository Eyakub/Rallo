import AppKit

/// A capture failure whose message Siri, Shortcuts and the notes panel show
/// as-is (0017).
struct CaptureFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Saves notes and reminders for the Shortcuts actions, Siri and the
/// Services menu (0017). macOS may start Rallo for them, so each request
/// waits briefly for the app to open its store.
@MainActor
final class CaptureService {
    static let shared = CaptureService()

    private var core: CoreClient?
    private var showError: ((String) -> Void)?
    private var unavailableMessage: String?
    private let waitLimit: Duration

    init(waitLimit: Duration = .seconds(5)) {
        self.waitLimit = waitLimit
    }

    /// Where a failed Services save is reported: the notes panel. Set before the
    /// store opens, so a store that never opens is still reported.
    func showErrors(_ sink: @escaping (String) -> Void) {
        showError = sink
    }

    /// Called once the store is open.
    func attach(core: CoreClient) {
        self.core = core
    }

    /// The store will never open: requests fail with `message` right away,
    /// including any already waiting.
    func unavailable(_ message: String) {
        unavailableMessage = message
    }

    func addNote(_ text: String) async throws -> ItemSnapshot {
        let core = try await readyCore()
        return try await reported { try await core.createNote(text) }
    }

    func addReminder(_ text: String, when: String) async throws -> ItemSnapshot {
        let core = try await readyCore()
        return try await reported { try await core.createReminder(text, when: when) }
    }

    /// What the core last saw of notification permission, nil if it can't say.
    func notificationAuthorization() async -> NotificationAuthorization? {
        try? await core?.notificationAuthorization()
    }

    /// The spoken reply for a saved reminder (0017): honest when alerts are blocked.
    nonisolated static func reminderReply(label: String, authorization: NotificationAuthorization?) -> String {
        switch authorization {
        case .denied:
            "Reminder set for \(label), but it won't alert you: notifications for Rallo are off in System Settings."
        case .notDetermined:
            "Reminder set for \(label), but it won't alert you until you allow Rallo's notifications."
        default:
            "Reminder set for \(label)."
        }
    }

    /// Services has no way to reply, so a failure goes to the notes panel (or a
    /// beep if no sink was set).
    func saveSelection(_ text: String) async {
        do {
            _ = try await addNote(text)
        } catch {
            let message = (error as? CaptureFailure)?.message ?? error.localizedDescription
            if let showError { showError(message) } else { NSSound.beep() }
        }
    }

    // ponytail: polls every 100 ms up to waitLimit; a continuation if startup ever needs a signal instead
    private func readyCore() async throws -> CoreClient {
        let clock = ContinuousClock()
        let deadline = clock.now + waitLimit
        while core == nil, clock.now < deadline {
            if let unavailableMessage { throw CaptureFailure(message: unavailableMessage) }
            try await Task.sleep(for: .milliseconds(100))
        }
        if core == nil, let unavailableMessage { throw CaptureFailure(message: unavailableMessage) }
        guard let core else { throw CaptureFailure(message: "Rallo is still starting. Try again in a moment.") }
        return core
    }

    private func reported(_ work: () async throws -> ItemSnapshot) async throws -> ItemSnapshot {
        do {
            return try await work()
        } catch let error as RalloError {
            throw CaptureFailure(message: error.displayMessage)
        }
    }
}
