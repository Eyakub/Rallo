import SwiftUI

/// Inline editor for one note inside its expanded row. Saves with the
/// revision the row showed, so a note changed elsewhere is never overwritten.
struct ItemEditor: View {
    let item: ItemSnapshot
    @ObservedObject var model: NotesViewModel
    @FocusState private var focused: Bool

    private var canSave: Bool {
        // An image note's caption can be cleared; a text-only note can't be empty.
        let draft = model.editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!draft.isEmpty || !item.images.isEmpty) && model.editDraft != item.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Note", text: $model.editDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...12)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.rust, lineWidth: 1.5))
                .accessibilityLabel("Edit note")
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelEditing() }
                    .buttonStyle(.plain)
                    .font(Theme.rounded(12, .medium))
                    .foregroundStyle(Theme.bark)
                Button {
                    Task { await model.saveEdit(item) }
                } label: {
                    Text("Save")
                        .font(Theme.rounded(12, .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.rust))
                }
                .buttonStyle(.plain)
                .opacity(canSave ? 1 : 0.45)
                .disabled(!canSave)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Save changes")
            }
        }
        .onAppear { focused = true }
    }
}
