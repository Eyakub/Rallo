import Foundation

/// Names for folders the window makes itself (0019 §3). The core decides what
/// a valid name is (`FOLDER_NAME_INVALID`, `FOLDER_EXISTS`) and the window
/// shows its message; Swift never re-implements those rules. This only
/// guesses the first free "New Folder"; a wrong guess is answered by
/// `FOLDER_EXISTS` and the caller tries the next.
enum FolderNaming {
    /// "New Folder", then "New Folder 2", "New Folder 3", …
    static func newFolderName(existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains("new folder") else { return "New Folder" }
        var number = 2
        while taken.contains("new folder \(number)") { number += 1 }
        return "New Folder \(number)"
    }
}
