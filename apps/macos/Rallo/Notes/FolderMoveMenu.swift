import SwiftUI

/// A menu row with a native checkmark when `checked`.
struct MenuChoice: View {
    let title: String
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { checked }, set: { _ in action() }))
    }
}

/// "Move to" (0019 §10): Notes, then the folders alphabetically (the note's
/// current one checked and disabled), a separator, New Folder…. Reused by the
/// window's Move chip. Put it inside a `Menu` or a `.contextMenu`.
struct FolderMoveMenu: View {
    let currentFolderID: String?        // nil = Notes
    let folders: [FolderSnapshot]       // alphabetical
    let onMove: (String?) -> Void       // nil = Notes
    let onNewFolder: () -> Void

    var body: some View {
        ForEach(FolderMenus.moveItems(currentFolderID: currentFolderID, folders: folders), id: \.folderID) { item in
            MenuChoice(title: item.title, checked: item.checked) { onMove(item.folderID) }
                .disabled(item.checked)
        }
        Divider()
        Button("New Folder…", action: onNewFolder)
    }
}
