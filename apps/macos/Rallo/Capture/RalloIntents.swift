import AppIntents

extension CaptureFailure: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// "Add Rallo Note" in Shortcuts, Siri and Spotlight (0017).
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Rallo Note"
    static let description = IntentDescription("Saves a note in Rallo.")
    static let openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What's the note?")
    var text: String?

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let images = Self.storable(images)
        // The note is optional only when images come with it (0018).
        guard text?.isEmpty == false || !images.isEmpty else {
            throw $text.needsValueError("What's the note?")
        }
        _ = try await CaptureService.shared.addNote(text ?? "", images: images)
        return .result(dialog: "Saved to Rallo.")
    }

    /// Shortcuts' files as Rallo stores them: the five stored formats as they
    /// are, other images as PNG; anything else goes through unchanged for the
    /// core to refuse with its message.
    static func storable(_ files: [IntentFile]?) -> [Data] {
        (files ?? []).map { ImageClipboard.storable($0.data) ?? $0.data }
    }
}

/// "Add Rallo Reminder": When uses 0016's rules, as `rallo remind --at` does.
struct AddReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Rallo Reminder"
    static let description = IntentDescription(
        "Saves a note in Rallo with a one-time reminder. When takes \"fri 5pm\", \"tomorrow 9am\", \"in 2 hours\" or an ISO 8601 date."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What should Rallo remind you about?")
    var text: String

    @Parameter(title: "When", requestValueDialog: "When?")
    var when: String

    @Parameter(title: "Images", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]?

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me about \(\.$text) \(\.$when)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = try await CaptureService.shared.addReminder(text, when: when, images: AddNoteIntent.storable(images))
        guard let reminder = item.reminder else { return .result(dialog: "Saved to Rallo.") }
        let authorization = await CaptureService.shared.notificationAuthorization()
        let label = ReminderLabel.text(for: reminder.deadline)
        return .result(dialog: "\(CaptureService.reminderReply(label: label, authorization: authorization))")
    }
}

/// Siri phrases, also listed in Spotlight on macOS 26. A phrase can't carry
/// free text, so Siri asks for the note and the time.
struct RalloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: ["Add a note in \(.applicationName)", "New \(.applicationName) note"],
            shortTitle: "Add Note",
            systemImageName: "note.text.badge.plus"
        )
        AppShortcut(
            intent: AddReminderIntent(),
            phrases: ["Remind me in \(.applicationName)", "New \(.applicationName) reminder"],
            shortTitle: "Add Reminder",
            systemImageName: "bell.badge"
        )
    }
}
