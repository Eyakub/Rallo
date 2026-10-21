import Foundation

/// The Google refresh token in the login Keychain (0024 §4), like `ClickUpToken`.
/// `exists()` never prompts; `read()` can, so it runs only when a backup runs or on connect/disconnect.
struct GoogleDriveToken: GoogleTokenStore {
    private let secret = KeychainSecret(service: "rallo-google-drive-token", label: "Rallo: Google Drive")

    func exists() -> Bool { secret.exists() }
    func read() -> String? { secret.read() }
    func save(_ token: String) -> Bool { secret.save(token) }
    func delete() { secret.delete() }
}
