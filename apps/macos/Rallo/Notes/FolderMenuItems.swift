import Foundation

struct ScopeMenuItem: Equatable {
    let scope: NotesScope
    let title: String
    let count: Int
    let symbol: String
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
    /// All Notes, Notes, then each folder, with the core's open counts (shown
    /// beside the name, not in it). The view puts a separator after the first entry.
    static func scopeItems(current: NotesScope, overview: FolderOverview) -> [ScopeMenuItem] {
        let current = current.resolved(in: overview.folders)
        var items = [
            ScopeMenuItem(scope: .all, title: "All Notes", count: Int(overview.allOpen), symbol: "tray", checked: current == .all),
            ScopeMenuItem(scope: .unfiled, title: "Notes", count: Int(overview.unfiledOpen), symbol: "folder", checked: current == .unfiled),
        ]
        items += overview.folders.map {
            ScopeMenuItem(scope: .folder($0.id), title: $0.name, count: Int($0.openCount), symbol: "folder", checked: current == .folder($0.id))
        }
        return items
    }

    /// Notes, then each folder; the note's current folder is `checked` (the
    /// view also disables it). A long name is cut like the placeholder's, so it
    /// can't stretch the native submenu across the panel.
    static func moveItems(currentFolderID: String?, folders: [FolderSnapshot]) -> [MoveMenuItem] {
        [MoveMenuItem(folderID: nil, title: "Notes", checked: currentFolderID == nil)]
            + folders.map { MoveMenuItem(folderID: $0.id, title: cut($0.name), checked: $0.id == currentFolderID) }
    }

    private static func cut(_ name: String) -> String {
        name.count > 24 ? String(name.prefix(23)) + "…" : name
    }
}

/// Keyboard highlight movement in the folder dropdown: ↓ from nothing goes to
/// the first row, ↑ from nothing to the last, and both wrap.
enum MenuHighlight {
    static func next(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return (current + (forward ? 1 : count - 1)) % count
    }
}
