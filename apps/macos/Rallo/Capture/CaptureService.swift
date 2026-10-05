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
    private let waitLimit: Duration

    init(waitLimit: Duration = .seconds(5)) {
        self.waitLimit = waitLimit
    }

    /// Called once the store is open; `showError` puts a message in the notes panel.
    func attach(core: CoreClient, showError: @escaping (String) -> Void) {
        self.core = core
        self.showError = showError
    }

    func addNote(_ text: String) async throws -> ItemSnapshot {
        let core = try await readyCore()
        return try await reported { try await core.createNote(text) }
    }

    func addReminder(_ text: String, when: String) async throws -> ItemSnapshot {
        let core = try await readyCore()
        return try await reported { try await core.createReminder(text, when: when) }
    }

    /// Services has no way to reply, so a failure goes to the notes panel (or a
    /// beep if the store never opened).
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
            try await Task.sleep(for: .milliseconds(100))
        }
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
