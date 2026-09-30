import AppKit
import SwiftUI

/// Title and preview derived from a note's text for display only; the stored
/// text is never changed. The first non-empty line is the title.
struct NoteParts: Equatable {
    let title: String
    let rest: String

    init(_ text: String) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            rest = ""
            return
        }
        title = lines[first].trimmingCharacters(in: .whitespaces)
        rest = lines[(first + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rest flattened to one line for the collapsed preview.
    var preview: String {
        rest.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

extension ReminderSnapshot {
    var deadline: Date { Date(timeIntervalSince1970: TimeInterval(deadlineMs) / 1000) }

    /// A short qualifier for the row, straight from the core's scheduling
    /// status (0005); `nil` when it is simply scheduled.
    var statusNote: (text: String, help: String)? {
        switch (schedulingState, schedulingReason) {
        case ("pending", _):
            ("not scheduled yet", "Saved. Rallo hasn’t handed this reminder to macOS yet.")
        case ("scheduled", "permission_not_requested"):
            ("notifications off", "Scheduled, but notifications aren’t enabled. Choose Enable Notifications in the Rallo menu.")
        case ("delivered", _):
            ("sent", "macOS delivered this notification.")
        case ("unavailable", "permission_denied"):
            ("notifications off", "Notifications are turned off for Rallo in System Settings.")
        case ("unavailable", "delivery_unconfirmed"):
            ("may not have alerted", "Rallo couldn’t confirm the alert. Snooze to try again.")
        case ("unavailable", _):
            ("wasn’t scheduled", "The time passed before macOS accepted it. Snooze to try again.")
        default:
            nil
        }
    }
}

enum ReminderLabel {
    /// "today at 14:20", "tomorrow at 9:00", or "Fri 3 Oct at 9:00".
    static func text(for date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day) at \(time)"
    }
}

struct NoteRow: View {
    let item: ItemSnapshot
    @ObservedObject var model: NotesViewModel
    @State private var hovering = false

    private var parts: NoteParts { NoteParts(item.text) }
    private var expanded: Bool { model.expandedID == item.id }
    private var editing: Bool { model.editingID == item.id }
    private var completing: Bool { model.completingIDs.contains(item.id) }
    private var highlighted: Bool { model.highlightedItemID == item.id }
    private var created: Date { Date(timeIntervalSince1970: TimeInterval(item.createdAtMs) / 1000) }

    /// Whether collapsing hides anything worth expanding for.
    private var hasMore: Bool { !parts.rest.isEmpty || parts.title.count > 38 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CompletionButton(completing: completing) { Task { await model.complete(item) } }
                .accessibilityLabel("Mark “\(parts.title)” as done")
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    ItemEditor(item: item, model: model)
                } else {
                    content
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? Theme.highlight : ((hovering || expanded) ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if model.openSwipe != nil {
                model.openSwipe = nil
            } else if !editing {
                model.toggleExpanded(item)
            }
        }
        .contextMenu {
            Button("Mark as Done") { Task { await model.complete(item) } }
            Button("Edit") { model.beginEditing(item) }
            remindMenu
            Divider()
            Button("Copy Text") { copy(item.text) }
            Button("Copy ID for the Terminal") { copy(item.id) }
            Divider()
            Button("Delete", role: .destructive) { Task { await model.delete(item) } }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
                .strikethrough(completing, color: Theme.bark)
                .foregroundStyle(completing ? Theme.bark : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: expanded)
            if hasMore {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.bark)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .opacity(hovering || expanded ? 1 : 0.45)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(expanded ? "Collapses the note" : "Shows the whole note")
        .accessibilityAction { model.toggleExpanded(item) }

        if !parts.rest.isEmpty {
            if expanded {
                Text(parts.rest)
                    .font(.system(size: 14))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(parts.preview)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(Theme.bark)
            }
        }

        HStack(spacing: 10) {
            if let reminder = activeReminder {
                reminderLabel(reminder)
            } else {
                Text(created, format: .relative(presentation: .named, unitsStyle: .wide))
                    .font(Theme.rounded(12))
                    .foregroundStyle(Theme.bark)
            }
            Spacer(minLength: 0)
            if expanded {
                Menu {
                    remindButtons
                } label: {
                    Text(activeReminder == nil ? "Remind" : "Change")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .font(Theme.rounded(12, .semibold))
                .foregroundStyle(Theme.rust)
                .accessibilityLabel(activeReminder == nil ? "Set a reminder" : "Change the reminder")
                Button("Edit") { model.beginEditing(item) }
                    .buttonStyle(.plain)
                    .font(Theme.rounded(12, .semibold))
                    .foregroundStyle(Theme.rust)
                    .keyboardShortcut("e", modifiers: .command)
                Button("Delete") { Task { await model.delete(item) } }
                    .buttonStyle(.plain)
                    .font(Theme.rounded(12, .semibold))
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(.top, expanded ? 2 : 0)
    }

    private var activeReminder: ReminderSnapshot? {
        guard let reminder = item.reminder, reminder.state == .active else { return nil }
        return reminder
    }

    private func reminderLabel(_ reminder: ReminderSnapshot) -> some View {
        let when = ReminderLabel.text(for: reminder.deadline)
        let overdue = reminder.deadline <= .now
        return HStack(spacing: 4) {
            Image(systemName: overdue ? "bell.fill" : "bell")
                .font(.system(size: 10, weight: .semibold))
            Text(when.prefix(1).uppercased() + when.dropFirst())
            if let note = reminder.statusNote {
                Text(note.text).foregroundStyle(Theme.bark)
            }
        }
        .font(Theme.rounded(12, overdue ? .semibold : .medium))
        .foregroundStyle(Theme.rust)
        .help(reminder.statusNote?.help ?? "Reminder \(when)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reminder \(when)\(reminder.statusNote.map { ", \($0.text)" } ?? "")")
    }

    private var remindMenu: some View {
        Menu("Remind Me") { remindButtons }
    }

    @ViewBuilder
    private var remindButtons: some View {
        ForEach(RemindPreset.allCases) { preset in
            Button(preset.title) { Task { await model.remind(item, preset) } }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Reminders-style completion circle; fills with a bamboo check when used.
struct CompletionButton: View {
    let completing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(completing ? Theme.bamboo : (hovering ? Theme.rust : Theme.bark), lineWidth: 1.5)
                    .background(Circle().fill(completing ? Theme.bamboo : .clear))
                if completing {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 18, height: 18)
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(completing)
        .help("Mark as done")
    }
}
