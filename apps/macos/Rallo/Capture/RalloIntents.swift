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
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await CaptureService.shared.addNote(text)
        return .result(dialog: "Saved to Rallo.")
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

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me about \(\.$text) \(\.$when)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let item = try await CaptureService.shared.addReminder(text, when: when)
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
