import Foundation

/// "New Folder…" in a note's Move menu (§10): the window's `FolderNamePrompter`
/// card, whose `validate` is the real create call, so the core's own message
/// shows under the field and the card stays up until the folder exists or the
/// user cancels. Then the note moves into it.
@MainActor
enum WindowFolderPrompt {
    static func newFolder(for item: ItemSnapshot, model: NotesWindowModel) async {
        var created: FolderSnapshot?
        _ = await model.namePrompter.ask(title: "New Folder", initial: "", confirmTitle: "Create") { [core = model.core] name in
            created = try await core.createFolder(name)
        }
        guard let folder = created else { return }
        await model.reload()  // the toast names the folder: the overview must know it
        await model.move(item, toFolder: folder.id)
    }
}
