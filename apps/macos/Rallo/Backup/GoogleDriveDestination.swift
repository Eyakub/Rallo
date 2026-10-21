import Foundation

/// Where the refresh token lives. The app uses the Keychain (`GoogleDriveToken`); tests inject their own.
protocol GoogleTokenStore: Sendable {
    func exists() -> Bool
    func read() -> String?
    func save(_ token: String) -> Bool
    func delete()
}

/// A "Rallo Backups" folder in the person's My Drive (0024 §4). Handles are Drive file IDs.
struct GoogleDriveDestination: BackupDestination {
    let api: GoogleDriveAPI
    let tokens: GoogleTokenStore
    nonisolated(unsafe) let defaults: UserDefaults

    var folderID: String? { defaults.string(forKey: BackupController.Keys.googleFolder) }

    var key: String { "gdrive:" + (folderID ?? "") }

    func store(_ file: URL, name: String) async throws -> String {
        try await run { access in
            let folder = try await api.ensureFolder(folderID, accessToken: access)
            if folder != folderID { defaults.set(folder, forKey: BackupController.Keys.googleFolder) }
            return try await api.upload(file, name: name, parent: folder, accessToken: access)
        }
    }

    func remove(_ handle: String) async throws {
        try await run { try await api.delete(handle, accessToken: $0) }
    }

    /// Refreshes the access token, runs `operation`, and on a 401 refreshes once more and retries once.
    private func run<T>(_ operation: (String) async throws -> T) async throws -> T {
        do {
            guard let refreshToken = await Task.detached(operation: { tokens.read() }).value else { throw GoogleDriveError.reconnect }
            let access = try await api.refresh(refreshToken)
            do {
                return try await operation(access)
            } catch GoogleDriveError.unauthorized {
                return try await operation(try await api.refresh(refreshToken))
            }
        } catch {
            throw Self.describe(error)
        }
    }

    /// The line shown after "Couldn't back up: ".
    static func describe(_ error: Error) -> BackupError {
        switch error {
        case let error as BackupError: error
        case GoogleDriveError.quotaFull: BackupError(message: "Google Drive is full")
        case GoogleDriveError.reconnect, GoogleDriveError.unauthorized: BackupError(message: "reconnect Google Drive in Settings")
        case GoogleDriveError.rateLimited: BackupError(message: "Google Drive is busy, trying later")
        case GoogleDriveError.failed(let code): BackupError(message: "Google Drive answered \(code)")
        case is URLError: BackupError(message: "Rallo couldn’t reach Google Drive")
        default: BackupError(message: "Google Drive didn’t answer as expected")
        }
    }
}
