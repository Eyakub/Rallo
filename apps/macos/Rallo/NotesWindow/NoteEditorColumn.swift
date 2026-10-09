import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The right column (0019 §11): the open note's date, reminder, text and
/// images, with the "changed somewhere else" bar above and the note's actions
/// in the toolbar.
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
        .background(Theme.surface.ignoresSafeArea(edges: .top))
        .toolbar { toolbar }
    }

    /// A note that can be acted on: saved, and not in Deleted.
    private var actionable: ItemSnapshot? {
        guard let note, note.deletedAtMs == nil else { return nil }
        return note
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            let done = actionable?.status == .done
            Button {
                if let note = actionable { Task { await model.toggleDone(note) } }
            } label: {
                Label(done ? "Reopen" : "Mark as Done", systemImage: done ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .disabled(actionable == nil)
            .help(done ? "Reopen" : "Mark as Done")

            Menu {
                if let note = actionable {
                    RemindMenuItems(
                        onPreset: { preset in Task { await model.remind(note, preset) } },
                        onCustom: { model.customRemindOpen = true }
                    )
                }
            } label: {
                Label("Remind Me", systemImage: "bell")
            }
            .disabled(actionable == nil)
            .help("Remind Me")

            Button(action: addImage) {
                Label("Add Image", systemImage: "photo.badge.plus")
            }
            .disabled(actionable == nil)
            .help("Add Image")

            Menu {
                if let note = actionable {
                    FolderMoveMenu(
                        currentFolderID: note.folderId,
                        folders: model.folders,
                        onMove: { id in Task { await model.move(note, toFolder: id) } },
                        onNewFolder: { Task { await WindowFolderPrompt.newFolder(for: note, model: model) } }
                    )
                }
            } label: {
                Label(model.folderName(actionable?.folderId), systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(actionable == nil)
            .help("Move to Folder")
        }
    }

    /// Add Image: an open panel for images, normalised like pasted ones, then `attach_images`.
    private func addImage() {
        guard let note = actionable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to add to this note"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let images = await Task.detached { urls.compactMap { try? Data(contentsOf: $0) }.compactMap(ImageClipboard.storable) }.value
            if images.isEmpty {
                model.errorMessage = "Couldn’t read that image."
            } else {
                await model.attachImages(images, to: note)
            }
        }
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
                        .popover(isPresented: $model.customRemindOpen, arrowEdge: .bottom) {
                            CustomRemindPopover(
                                onSet: { date in
                                    model.customRemindOpen = false
                                    if let note = actionable { Task { await model.remind(note, at: date) } }
                                },
                                onCancel: { model.customRemindOpen = false }
                            )
                        }
                    if let note = actionable, let reminder = note.reminder, reminder.state == .active {
                        ReminderPill(
                            reminder: reminder,
                            onPreset: { preset in Task { await model.remind(note, preset) } },
                            onCustom: { model.customRemindOpen = true },
                            onCancel: { Task { await model.cancelReminder(note) } }
                        )
                    }
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

/// The note's reminder (a bell, `Theme.rust`); clicking it offers the Remind Me
/// choices again, and Cancel Reminder.
private struct ReminderPill: View {
    let reminder: ReminderSnapshot
    let onPreset: (RemindPreset) -> Void
    let onCustom: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let when = ReminderLabel.text(for: reminder.deadline)
        Menu {
            RemindMenuItems(onPreset: onPreset, onCustom: onCustom)
            Divider()
            Button("Cancel Reminder", role: .destructive, action: onCancel)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: reminder.alertBlocked ? "bell.slash" : "bell")
                    .font(.system(size: 11, weight: .semibold))
                Text(when.prefix(1).uppercased() + when.dropFirst())
            }
            .font(Theme.rounded(12.5, .semibold))
            .foregroundStyle(Theme.rust)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.highlight))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(reminder.statusNote?.help ?? "Reminder \(when)")
        .accessibilityLabel("Reminder \(when)")
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
