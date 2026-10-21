import Foundation

/// Where a finished backup zip goes (0024). Google Drive sits behind the same protocol.
protocol BackupDestination: Sendable {
    /// Stable identity, e.g. "folder:/abs/path" or (part B) "gdrive:<folder id>". Changing it starts a new handle list.
    var key: String { get }
    /// Stores the finished zip under `name`; returns a handle (file name, or a Drive file ID) for retention.
    func store(_ file: URL, name: String) async throws -> String
    /// Deletes a backup this Mac stored earlier; an already-missing one is not an error.
    func remove(_ handle: String) async throws
}

/// A reason shown to the person as is, after "Couldn't back up: ".
struct BackupError: Error, Equatable {
    let message: String
}

/// A folder on disk: iCloud Drive's Rallo Backups folder, or one the user picked.
struct FolderDestination: BackupDestination {
    let folder: URL

    var key: String { "folder:" + folder.standardizedFileURL.path }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, present only when iCloud Drive is on.
    static func iCloudRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static func iCloudAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: iCloudRoot(home: home).path, isDirectory: &isDir) && isDir.boolValue
    }

    static func iCloud(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FolderDestination {
        FolderDestination(folder: iCloudRoot(home: home).appendingPathComponent("Rallo Backups", isDirectory: true))
    }

    func store(_ file: URL, name: String) async throws -> String {
        let fm = FileManager.default
        let partial = folder.appendingPathComponent(".\(name).partial")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: file, to: partial)
            try fm.moveItem(at: partial, to: folder.appendingPathComponent(name))
        } catch {
            try? fm.removeItem(at: partial)
            throw BackupError(message: "the folder isn’t writable")
        }
        return name
    }

    /// Only a plain `Rallo Backup ….zip` file name is ever deleted: never a path (the prefix rules out `..`).
    static func isBackupName(_ handle: String) -> Bool {
        handle.hasPrefix("Rallo Backup ") && handle.hasSuffix(".zip") && !handle.contains("/")
    }

    func remove(_ handle: String) async throws {
        guard Self.isBackupName(handle) else { return }
        let target = folder.appendingPathComponent(handle)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
