import SwiftUI

/// The Notes window's content: sidebar, list, editor (0019 §11).
struct NotesWindowView: View {
    @ObservedObject var model: NotesWindowModel

    var body: some View {
        NavigationSplitView {
            FolderSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            NoteListColumn(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            NoteEditorColumn(model: model, editor: model.editor)
        }
        .tint(Theme.rust)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search all notes")
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .sheet(item: $model.pendingFolderDelete) { pending in
            DeleteFolderSheet(pending: pending, model: model)
        }
        .overlay(alignment: .top) { errorBanner }
        .folderNamePrompt(model.namePrompter)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    model.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .font(Theme.rounded(12.5, .medium))
            .foregroundStyle(Theme.error)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceTop))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.error.opacity(0.45)))
            .frame(maxWidth: 520)
            .padding(.top, 10)
            .accessibilityLabel("Error: \(message)")
        }
    }
}
