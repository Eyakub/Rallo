import Foundation

/// What the notes window's sidebar has selected (0019 §11).
enum NotesWindowSelection: Hashable {
    case scope(NotesScope)
    case due, done, deleted
    case tag(String)
}

enum SelectionFallback {
    /// Where the sidebar lands after a reload: a folder that's gone (deleted
    /// here or by the CLI) switches to Notes, a tag no open note carries any
    /// more to All Notes. Everything else stays.
    static func resolve(_ selection: NotesWindowSelection, folderIDs: Set<String>, tagNames: Set<String>) -> NotesWindowSelection {
        switch selection {
        case let .scope(.folder(id)) where !folderIDs.contains(id): .scope(.unfiled)
        case let .tag(name) where !tagNames.contains(name): .scope(.all)
        default: selection
        }
    }
}
