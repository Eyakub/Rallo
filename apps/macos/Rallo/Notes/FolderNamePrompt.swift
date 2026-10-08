import Foundation

/// The one "name a folder" prompt (0019 §10), used by New Folder… here and by
/// New Folder and Rename in the window later. It drives `FolderNameOverlay`,
/// a dialog card drawn inside the panel (an NSAlert's modal loop would starve
/// the main-actor work that validates the name).
///
/// Validation is the caller's real create/rename, so the core's own message
/// (empty, too long, "Notes", already taken) is what the dialog shows.
@MainActor
final class FolderNamePrompter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let title: String
        let initial: String
        let confirmTitle: String
    }

    @Published private(set) var request: Request?
    @Published private(set) var error: String?
    @Published private(set) var isSaving = false
    /// Bumped on every failed save, so an identical repeated message still
    /// shakes, is announced and refocuses the field.
    @Published private(set) var errorCount = 0

    private var validate: ((String) async throws -> Void)?
    /// Cancel arrived mid-save: dismiss once the save fails (a success returns the name).
    private var cancelAfterSave = false
    private var continuation: CheckedContinuation<String?, Never>?

    /// Shows the dialog; returns the accepted name, or nil on Cancel/Esc/dismiss.
    /// A new ask while one is showing cancels the old one (it returns nil).
    func ask(title: String, initial: String, confirmTitle: String,
             validate: @escaping (String) async throws -> Void) async -> String? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.validate = validate
            request = Request(title: title, initial: initial, confirmTitle: confirmTitle)
        }
    }

    /// Runs `validate`; on a throw the dialog stays up with the core's message.
    func submit(_ name: String) async {
        guard let validate, let id = request?.id, !isSaving else { return }
        isSaving = true
        error = nil
        do {
            try await validate(name)
            // Superseded while saving: that ask already resumed its caller.
            guard request?.id == id else { return }
            finish(name)
        } catch {
            guard request?.id == id else { return }
            if cancelAfterSave {
                finish(nil)
                return
            }
            isSaving = false
            errorCount += 1
            self.error = Self.capitalized((error as? RalloError)?.displayMessage ?? error.localizedDescription)
        }
    }

    /// Dismisses the dialog; during a save it waits for the result instead.
    func cancel() {
        if isSaving {
            cancelAfterSave = true
            return
        }
        finish(nil)
    }

    /// The core's messages start lowercase ("a folder name is…"); display only.
    private static func capitalized(_ message: String) -> String {
        message.prefix(1).uppercased() + message.dropFirst()
    }

    /// Editing the field takes the stale message away.
    func clearError() {
        if error != nil { error = nil }
    }

    /// Every path out resumes the caller exactly once.
    private func finish(_ name: String?) {
        let pending = continuation
        continuation = nil
        validate = nil
        cancelAfterSave = false
        request = nil
        error = nil
        isSaving = false
        pending?.resume(returning: name)
    }
}
