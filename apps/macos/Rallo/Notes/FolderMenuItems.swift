import Foundation

struct ScopeMenuItem: Equatable {
    let scope: NotesScope
    let title: String
    let checked: Bool
}

struct MoveMenuItem: Equatable {
    /// nil is the built-in Notes.
    let folderID: String?
    let title: String
    let checked: Bool
}

/// The ordered, checked entries of the panel's two folder menus (0019 §10).
/// Folders arrive alphabetical from the core and are never re-sorted here.
enum FolderMenus {
    /// All Notes, Notes, then each folder, with the core's open counts. The
    /// view puts a separator after the first entry.
    static func scopeItems(current: NotesScope, overview: FolderOverview) -> [ScopeMenuItem] {
        let current = current.resolved(in: overview.folders)
        var items = [
            ScopeMenuItem(scope: .all, title: "All Notes (\(overview.allOpen))", checked: current == .all),
            ScopeMenuItem(scope: .unfiled, title: "Notes (\(overview.unfiledOpen))", checked: current == .unfiled),
        ]
        items += overview.folders.map {
            ScopeMenuItem(scope: .folder($0.id), title: "\($0.name) (\($0.openCount))", checked: current == .folder($0.id))
        }
        return items
    }

    /// Notes, then each folder; the note's current folder is `checked` (the
    /// view also disables it).
    static func moveItems(currentFolderID: String?, folders: [FolderSnapshot]) -> [MoveMenuItem] {
        [MoveMenuItem(folderID: nil, title: "Notes", checked: currentFolderID == nil)]
            + folders.map { MoveMenuItem(folderID: $0.id, title: $0.name, checked: $0.id == currentFolderID) }
    }
}
