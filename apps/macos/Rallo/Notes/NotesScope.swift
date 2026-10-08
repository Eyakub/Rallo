import Foundation

/// Which notes the small panel lists and where its note field files new ones
/// (0019 §10). Remembered in UserDefaults `notesPanelScope` as "all",
/// "unfiled", or the folder id.
enum NotesScope: Hashable {
    case all
    case unfiled
    case folder(String)

    static let defaultsKey = "notesPanelScope"

    init(stored: String?) {
        let value = stored ?? ""
        switch value {
        case "", "all": self = .all
        case "unfiled": self = .unfiled
        default: self = .folder(value)
        }
    }

    static func load(from defaults: UserDefaults) -> NotesScope {
        NotesScope(stored: defaults.string(forKey: defaultsKey))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    var stored: String {
        switch self {
        case .all: "all"
        case .unfiled: "unfiled"
        case let .folder(id): id
        }
    }

    var folderScope: FolderScope {
        switch self {
        case .all: .all
        case .unfiled: .unfiled
        case let .folder(id): .folder(id: id)
        }
    }

    /// All Notes and Notes file into the built-in Notes (no folder).
    var newNoteFolderID: String? {
        if case let .folder(id) = self { return id }
        return nil
    }

    var symbol: String {
        if case .all = self { return "tray" }
        return "folder"
    }

    /// A folder that no longer exists (deleted, maybe by the CLI) is All Notes.
    func resolved(in folders: [FolderSnapshot]) -> NotesScope {
        if case let .folder(id) = self, !folders.contains(where: { $0.id == id }) { return .all }
        return self
    }

    func title(in folders: [FolderSnapshot]) -> String {
        switch resolved(in: folders) {
        case .all: "All Notes"
        case .unfiled: "Notes"
        case let .folder(id): folders.first { $0.id == id }?.name ?? "All Notes"
        }
    }

    /// All Notes keeps today's prompt; a folder names itself.
    func placeholder(in folders: [FolderSnapshot], hasNotes: Bool) -> String {
        switch resolved(in: folders) {
        case .all: hasNotes ? "Something else on your mind?" : "What’s on your mind?"
        case .unfiled: "Add to Notes…"
        case .folder: "Add to \(Self.fitted(title(in: folders)))…"
        }
    }

    /// One placeholder line: a long folder name is cut by whole characters
    /// (graphemes, so a ZWJ sequence or Bangla conjunct is never split).
    private static func fitted(_ title: String) -> String {
        title.count > 24 ? String(title.prefix(23)) + "…" : title
    }

    func openCount(in overview: FolderOverview) -> Int {
        switch self {
        case .all: Int(overview.allOpen)
        case .unfiled: Int(overview.unfiledOpen)
        case let .folder(id): Int(overview.folders.first { $0.id == id }?.openCount ?? 0)
        }
    }

    static func countLine(open count: Int) -> String {
        switch count {
        case 0: "No open notes"
        case 1: "1 open note"
        default: "\(count) open notes"
        }
    }
}
