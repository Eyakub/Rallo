import SwiftUI

/// §12's sheet. Keep Notes is the default; deleting notes is the destructive choice.
struct DeleteFolderSheet: View {
    let pending: PendingFolderDelete
    @ObservedObject var model: NotesWindowModel

    private var copy: FolderDeleteCopy {
        FolderDeleteCopy(folderName: pending.folder.name, noteCount: pending.noteCount)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.rust)
                .accessibilityHidden(true)
            Text(copy.title)
                .font(Theme.rounded(16, .semibold))
            Text(copy.message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.bark)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                if copy.holdsNotes {
                    Button { confirm(keepNotes: true) } label: { wide("Keep Notes") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button(role: .destructive) { confirm(keepNotes: false) } label: { wide("Delete Notes") }
                        .buttonStyle(.bordered)
                } else {
                    // Nothing to keep or delete; Keep Notes is the harmless flag for the core.
                    Button(role: .destructive) { confirm(keepNotes: true) } label: { wide("Delete") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Button { model.pendingFolderDelete = nil } label: { wide("Cancel") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 340)
        .tint(Theme.rust)
    }

    private func wide(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity)
    }

    private func confirm(keepNotes: Bool) {
        Task { await model.confirmDelete(pending, keepNotes: keepNotes) }
    }
}
