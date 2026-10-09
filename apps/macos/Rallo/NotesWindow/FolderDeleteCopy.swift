import Foundation

/// The delete-folder sheet's words (0019 §12).
struct FolderDeleteCopy: Equatable {
    let title: String
    let message: String
    let holdsNotes: Bool

    init(folderName: String, noteCount: Int) {
        title = "Delete “\(folderName)”?"
        holdsNotes = noteCount > 0
        switch noteCount {
        case 0:
            message = "The folder is empty."
        case 1:
            message = "It holds 1 note. Keep it in Notes, or delete it too? Deleted notes stay in Deleted, where you can restore them."
        default:
            message = "It holds \(noteCount) notes. Keep them in Notes, or delete them too? Deleted notes stay in Deleted, where you can restore them."
        }
    }
}
