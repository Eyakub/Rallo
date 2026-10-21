import Foundation

/// The OAuth client for Google Drive backup (0024 §4): build settings from the
/// gitignored `private/google-oauth.env`, read from Info.plist. A build without
/// them leaves the `$(…)` placeholders or empty strings, and Drive is "not set up".
enum GoogleDriveConfig {
    static var clientID: String { value("RalloGoogleClientID") }
    static var clientSecret: String { value("RalloGoogleClientSecret") }
    static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    private static func value(_ key: String) -> String {
        let raw = (Bundle.main.infoDictionary?[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.hasPrefix("$(") ? "" : raw
    }
}
