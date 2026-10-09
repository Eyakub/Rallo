import SwiftUI

/// The right column (0019 §11): the open note's date, text and images, with
/// the "changed somewhere else" bar above. The toolbar and the reminder pill
/// come in the next task.
struct NoteEditorColumn: View {
    @ObservedObject var model: NotesWindowModel
    @ObservedObject var editor: NoteEditorSession

    /// The list's copy of the note (latest after a reload), else the session's
    /// (a note created a moment ago).
    private var note: ItemSnapshot? { model.selectedItem ?? editor.note }

    var body: some View {
        Group {
            if note == nil && !editor.isDraft {
                Text("No note selected")
                    .font(Theme.rounded(15, .medium))
                    .foregroundStyle(Theme.bark)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if editor.conflict {
                ConflictBar(
                    showTheirs: { Task { await model.showTheirs() } },
                    keepMine: { Task { await model.keepMine() } }
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(createdText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.bark)
                        .frame(maxWidth: .infinity)
                    NoteTextEditor(session: editor)
                    if let message = editor.error {
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.error)
                            .accessibilityLabel("Error: \(message)")
                    }
                    if let note, !note.images.isEmpty {
                        ImageStrip(
                            item: note,
                            tile: CGSize(width: 210, height: 140),
                            onRemove: { image in Task { await model.removeImage(image, from: note) } },
                            onFocusChange: { _ in }
                        )
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// "8 October 2026 at 10:42"
    private var createdText: String {
        let created = note.map { Date(timeIntervalSince1970: TimeInterval($0.createdAtMs) / 1000) } ?? .now
        return created.formatted(date: .long, time: .shortened)
    }
}

/// An agent or the CLI changed the note while it was being edited (0019 §11).
private struct ConflictBar: View {
    let showTheirs: () -> Void
    let keepMine: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.rust)
                .accessibilityHidden(true)
            Text("This note changed somewhere else.")
                .font(Theme.rounded(13, .medium))
            Spacer(minLength: 8)
            Button("Show Theirs", action: showTheirs)
                .buttonStyle(.bordered)
            Button("Keep Mine", action: keepMine)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.highlight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
