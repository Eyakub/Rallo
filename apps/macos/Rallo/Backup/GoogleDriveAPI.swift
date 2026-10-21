import Foundation

enum GoogleDriveError: Error, Equatable {
    case notConfigured, disabled, cancelled, timedOut, reconnect, quotaFull, rateLimited, failed(Int), malformed
    /// A 401 on a call that took an access token: the caller refreshes once and retries.
    case unauthorized
}

/// Google's OAuth token endpoint and the Drive v3 calls Rallo needs (0024 §4).
struct GoogleDriveAPI {
    struct Tokens: Equatable {
        let refreshToken: String
        let accessToken: String
        let expiresIn: Int
    }

    let clientID: String
    let clientSecret: String
    var session: URLSession = GoogleDriveAPI.ephemeralSession()

    /// In-memory only, like ClickUp's: no cache, cookies or connection records on disk.
    static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    private static let base = "https://www.googleapis.com/drive/v3"

    // MARK: OAuth

    func exchange(code: String, verifier: String, redirect: URL) async throws -> Tokens {
        let json = try await form("https://oauth2.googleapis.com/token", [
            "code": code, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String, let access = json["access_token"] as? String else {
            throw GoogleDriveError.malformed
        }
        return Tokens(refreshToken: refresh, accessToken: access, expiresIn: json["expires_in"] as? Int ?? 0)
    }

    /// A new access token; `invalid_grant` (revoked or expired) means the person must reconnect.
    func refresh(_ refreshToken: String) async throws -> String {
        let json = try await form("https://oauth2.googleapis.com/token", [
            "client_id": clientID, "client_secret": clientSecret, "refresh_token": refreshToken, "grant_type": "refresh_token",
        ])
        guard let access = json["access_token"] as? String else { throw GoogleDriveError.malformed }
        return access
    }

    func revoke(_ token: String) async throws {
        _ = try await form("https://oauth2.googleapis.com/revoke", ["token": token])
    }

    // MARK: Drive

    func accountEmail(accessToken: String) async throws -> String {
        let json = try await json(get("\(Self.base)/about?fields=user(emailAddress)", accessToken))
        guard let email = (json["user"] as? [String: Any])?["emailAddress"] as? String else { throw GoogleDriveError.malformed }
        return email
    }

    /// The backups folder: the stored one when it still exists and isn't in the trash, else a new one.
    func ensureFolder(_ id: String?, accessToken: String) async throws -> String {
        if let id {
            do {
                let json = try await json(get("\(Self.base)/files/\(id)?fields=id,trashed", accessToken))
                if json["trashed"] as? Bool != true, let found = json["id"] as? String { return found }
            } catch GoogleDriveError.failed(404) {}
        }
        var request = URLRequest(url: URL(string: "\(Self.base)/files?fields=id")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "Rallo Backups", "mimeType": "application/vnd.google-apps.folder",
        ])
        guard let created = try await json(request)["id"] as? String else { throw GoogleDriveError.malformed }
        return created
    }

    /// A resumable upload: one request to start, one to send the file. Returns the new file's ID.
    func upload(_ file: URL, name: String, parent: String, accessToken: String) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!,
                               timeoutInterval: 30)
        start.httpMethod = "POST"
        start.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("application/zip", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
        let (_, started) = try await send(start)
        guard let location = started.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw GoogleDriveError.malformed
        }
        var put = URLRequest(url: url, timeoutInterval: 600)
        put.httpMethod = "PUT"
        put.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: put, fromFile: file)
        try Self.check(response, data)
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw GoogleDriveError.malformed
        }
        return id
    }

    /// 404 counts as done: the file is already gone.
    func delete(_ id: String, accessToken: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.base)/files/\(id)")!, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await send(request)
        } catch GoogleDriveError.failed(404) {}
    }

    // MARK: Plumbing

    private func get(_ url: String, _ accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func form(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 400,
           (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String == "invalid_grant" {
            throw GoogleDriveError.reconnect
        }
        try Self.check(response, data)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await send(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GoogleDriveError.malformed }
        return object
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        return (data, response as! HTTPURLResponse)
    }

    /// Maps a failed answer to `GoogleDriveError`; 2xx passes.
    static func check(_ response: URLResponse, _ data: Data) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return }
        let reasons = (((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["errors"]
            as? [[String: Any]])?.compactMap { $0["reason"] as? String } ?? []
        switch code {
        case 401: throw GoogleDriveError.unauthorized
        case 429: throw GoogleDriveError.rateLimited
        case 403 where reasons.contains("storageQuotaExceeded"): throw GoogleDriveError.quotaFull
        case 403 where reasons.contains("rateLimitExceeded") || reasons.contains("userRateLimitExceeded"): throw GoogleDriveError.rateLimited
        default: throw GoogleDriveError.failed(code)
        }
    }
}
