import Foundation

/// The sidebar's rows in the order they are drawn, for Up/Down navigation.
enum SidebarOrder {
    enum Direction { case up, down }

    /// Notes, folders (as shown), the four views, then tags.
    static func rows(folderIDs: [String], tagNames: [String]) -> [NotesWindowSelection] {
        [.scope(.unfiled)]
            + folderIDs.map { .scope(.folder($0)) }
            + [.scope(.all), .due, .done, .deleted]
            + tagNames.map { .tag($0) }
    }

    /// The row after (or before) `current`, or nil at an end: no wrapping. With no current
    /// row (it vanished from the list), Down lands on the first row and Up on the last.
    static func next(after current: NotesWindowSelection?, in rows: [NotesWindowSelection], direction: Direction) -> NotesWindowSelection? {
        guard !rows.isEmpty else { return nil }
        guard let current, let index = rows.firstIndex(of: current) else {
            return direction == .down ? rows.first : rows.last
        }
        let target = direction == .down ? index + 1 : index - 1
        return rows.indices.contains(target) ? rows[target] : nil
    }
}
