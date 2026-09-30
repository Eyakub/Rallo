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
        .onTapGesture { if !editing { model.toggleExpanded(item) } }
        .contextMenu {
            Button("Mark as Done") { Task { await model.complete(item) } }
            Button("Edit") { model.beginEditing(item) }
            Divider()
            Button("Copy Text") { copy(item.text) }
            Button("Copy ID for the Terminal") { copy(item.id) }
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
            Text(created, format: .relative(presentation: .named, unitsStyle: .wide))
                .font(Theme.rounded(12))
                .foregroundStyle(Theme.bark)
            Spacer(minLength: 0)
            if expanded {
                Button("Edit") { model.beginEditing(item) }
                    .buttonStyle(.plain)
                    .font(Theme.rounded(12, .semibold))
                    .foregroundStyle(Theme.rust)
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
        .padding(.top, expanded ? 2 : 0)
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
