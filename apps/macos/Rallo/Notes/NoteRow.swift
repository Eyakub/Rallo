import AppKit
import SwiftUI

extension ReminderSnapshot {
    var deadline: Date { Date(timeIntervalSince1970: TimeInterval(deadlineMs) / 1000) }

    /// macOS will not present this reminder's alert.
    var alertBlocked: Bool {
        schedulingReason == "permission_denied" || schedulingReason == "permission_not_requested"
    }

    /// A short qualifier for the row, straight from the core's scheduling
    /// status (0005); `nil` when it is simply scheduled.
    var statusNote: (text: String, help: String)? {
        switch (schedulingState, schedulingReason) {
        case ("pending", _):
            ("not scheduled yet", "Saved. Rallo hasn’t handed this reminder to macOS yet.")
        case ("scheduled", "permission_not_requested"):
            ("won’t alert", "Saved and handed to macOS, but Rallo isn’t allowed to show notifications yet.")
        case ("delivered", _):
            ("sent", "macOS delivered this notification.")
        case ("unavailable", "permission_denied"):
            ("won’t alert", "Notifications for Rallo are off in System Settings, so no alert will appear.")
        case ("unavailable", "delivery_unconfirmed"):
            ("may not have alerted", "Rallo couldn’t confirm the alert. Snooze to try again.")
        case ("unavailable", _):
            ("wasn’t scheduled", "The time passed before macOS accepted it. Snooze to try again.")
        default:
            nil
        }
    }
}

struct NoteRow: View {
    let item: ItemSnapshot
    @ObservedObject var model: NotesViewModel
    @State private var hovering = false
    @State private var dropTargeted = false

    private var parts: NoteParts { NoteParts(item.text) }
    private var expanded: Bool { model.expandedID == item.id }
    private var editing: Bool { model.editingID == item.id }
    private var completing: Bool { model.completingIDs.contains(item.id) }
    private var highlighted: Bool { model.highlightedItemID == item.id }
    private var created: Date { Date(timeIntervalSince1970: TimeInterval(item.createdAtMs) / 1000) }

    /// A collapsed row hides something: a title's body, or more than two
    /// lines of body text.
    private var hasMore: Bool {
        (parts.title != nil ? !parts.body.isEmpty : parts.body.count > 76) || (!item.text.isEmpty && !item.images.isEmpty)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CompletionButton(completing: completing) { Task { await model.complete(item) } }
                .accessibilityLabel("Mark “\(item.name)” as done")
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
                .fill(highlighted || dropTargeted ? Theme.highlight : ((hovering || expanded) ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrop(of: [.image], isTargeted: $dropTargeted) { providers in
            let outside = providers.filter { !$0.hasItemConformingToTypeIdentifier(ownDragType) }
            guard !outside.isEmpty else { return false }
            Task { @MainActor in await model.attach(await ImageClipboard.load(outside), to: item) }
            return true
        }
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
        .popover(
            isPresented: Binding(
                get: { model.customRemindID == item.id },
                set: { if !$0, model.customRemindID == item.id { model.customRemindID = nil } }
            ),
            arrowEdge: .bottom
        ) {
            CustomRemindPopover(item: item, model: model)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if item.text.isEmpty {
                    Text("Image")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.bark)
                } else if let title = parts.title {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(expanded ? nil : 1)
                } else {
                    Text(parts.body)
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .lineLimit(expanded ? nil : 2)
                        .textSelection(.enabled)
                }
            }
            .truncationMode(.tail)
            .strikethrough(completing, color: Theme.bark)
            .foregroundStyle(completing ? Theme.bark : Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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

        if parts.title != nil {
            if expanded {
                Text(parts.body)
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

        if expanded || item.text.isEmpty, !item.images.isEmpty {
            ImageStrip(item: item, model: model).padding(.top, 4)
        }

        HStack(spacing: 10) {
            if let reminder = activeReminder {
                reminderLabel(reminder)
            } else {
                Text(created, format: .relative(presentation: .named, unitsStyle: .wide))
                    .font(Theme.rounded(12))
                    .foregroundStyle(Theme.bark)
            }
            if !item.images.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "photo")
                        .font(.system(size: 10, weight: .semibold))
                    Text(item.images.count == 1 ? "1 image" : "\(item.images.count) images")
                }
                .font(Theme.rounded(12))
                .foregroundStyle(Theme.bark)
                .accessibilityElement(children: .combine)
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

        if let reminder = activeReminder, reminder.deadline <= .now {
            HStack(spacing: 8) {
                dueButton("Snooze 10 min", help: "Remind me again in 10 minutes") { Task { await model.snooze(item) } }
                dueButton("Dismiss", help: "Stop this reminder; the note stays open") {
                    Task { await model.dismissReminder(item) }
                }
            }
            .padding(.top, 2)
        }
    }

    private var activeReminder: ReminderSnapshot? {
        guard let reminder = item.reminder, reminder.state == .active else { return nil }
        return reminder
    }

    private func reminderLabel(_ reminder: ReminderSnapshot) -> some View {
        let when = ReminderLabel.text(for: reminder.deadline)
        let overdue = reminder.deadline <= .now
        return HStack(spacing: 4) {
            Image(systemName: reminder.alertBlocked ? "bell.slash" : (overdue ? "bell.fill" : "bell"))
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

    /// Due reminders get their two answers right on the row, not behind a
    /// swipe or menu.
    private func dueButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(11, .semibold))
                .foregroundStyle(Theme.rust)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().strokeBorder(Theme.rust.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var remindMenu: some View {
        Menu("Remind Me") { remindButtons }
    }

    @ViewBuilder
    private var remindButtons: some View {
        ForEach(RemindPreset.allCases) { preset in
            Button(preset.title) { Task { await model.remind(item, preset) } }
        }
        Divider()
        Button("Custom…") { model.customRemindID = item.id }
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
