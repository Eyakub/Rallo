import CryptoKit
import Foundation

/// The installed-app OAuth flow for Google (0024 §4): PKCE, the consent URL, and reading the redirect.
struct PKCE {
    let verifier: String
    let challenge: String

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func make() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        let verifier = String((0..<64).map { _ in alphabet.randomElement(using: &generator)! })
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// base64url(SHA256(verifier)) without padding (RFC 7636 §4.2).
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum GoogleOAuth {
    static let scope = "https://www.googleapis.com/auth/drive.file"

    static func authorizationURL(clientID: String, redirect: URL, challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            ("client_id", clientID), ("redirect_uri", redirect.absoluteString), ("response_type", "code"),
            ("scope", scope), ("code_challenge", challenge), ("code_challenge_method", "S256"),
            ("state", state), ("access_type", "offline"), ("prompt", "consent"),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    /// `target` is the request-target of the redirect's HTTP request line (`/?code=…&state=…`).
    static func parseRedirect(_ target: String, expectedState: String) throws -> String {
        let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if value("error") == "access_denied" { throw GoogleDriveError.cancelled }
        guard value("state") == expectedState, let code = value("code"), !code.isEmpty else { throw GoogleDriveError.malformed }
        return code
    }
}
