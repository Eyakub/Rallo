import XCTest

final class GoogleDriveAPITests: XCTestCase {
    private func api() -> GoogleDriveAPI {
        GoogleDriveAPI(clientID: "cid", clientSecret: "secret", session: StubURLProtocol.session())
    }

    private func quota(_ reason: String, status: Int = 403) -> (status: Int, headers: [String: String], body: Data) {
        StubURLProtocol.json(["error": ["errors": [["reason": reason]]]], status: status)
    }

    func testExchangePostsTheForm() async throws {
        StubURLProtocol.install { _, _ in
            StubURLProtocol.json(["refresh_token": "r", "access_token": "a", "expires_in": 3599])
        }
        let tokens = try await api().exchange(code: "the code", verifier: "ver", redirect: URL(string: "http://127.0.0.1:9")!)
        XCTAssertEqual(tokens, GoogleDriveAPI.Tokens(refreshToken: "r", accessToken: "a", expiresIn: 3599))
        let seen = try XCTUnwrap(StubURLProtocol.seen.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(formFields(seen.body), [
            "code": "the code", "client_id": "cid", "client_secret": "secret", "redirect_uri": "http://127.0.0.1:9",
            "grant_type": "authorization_code", "code_verifier": "ver",
        ])
    }

    func testRefreshInvalidGrantMeansReconnect() async {
        StubURLProtocol.install { _, _ in StubURLProtocol.json(["error": "invalid_grant"], status: 400) }
        do {
            _ = try await api().refresh("r")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GoogleDriveError, .reconnect)
        }
    }

    func testRefreshReturnsTheAccessToken() async throws {
        StubURLProtocol.install { _, _ in StubURLProtocol.json(["access_token": "fresh"]) }
        let token = try await api().refresh("r")
        XCTAssertEqual(token, "fresh")
        XCTAssertEqual(formFields(StubURLProtocol.seen[0].body)["grant_type"], "refresh_token")
    }

    func testUploadStartsAResumableSessionThenPutsTheFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-api-test-\(UUID().uuidString).zip")
        try Data("zipbytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        StubURLProtocol.install { request, _ in
            if request.httpMethod == "POST" {
                return (200, ["Location": "https://upload.example.com/session/1"], Data())
            }
            return StubURLProtocol.json(["id": "file-1"])
        }
        let id = try await api().upload(file, name: "Rallo Backup X.zip", parent: "folder-1", accessToken: "tok")
        XCTAssertEqual(id, "file-1")
        let seen = StubURLProtocol.seen
        XCTAssertEqual(seen.count, 2)
        let start = seen[0]
        XCTAssertEqual(start.request.url?.absoluteString, "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")
        XCTAssertEqual(start.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(start.request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=UTF-8")
        XCTAssertEqual(start.request.value(forHTTPHeaderField: "X-Upload-Content-Type"), "application/zip")
        XCTAssertEqual(start.request.value(forHTTPHeaderField: "X-Upload-Content-Length"), "8")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: start.body) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Rallo Backup X.zip")
        XCTAssertEqual(body["parents"] as? [String], ["folder-1"])
        let put = seen[1]
        XCTAssertEqual(put.request.httpMethod, "PUT")
        XCTAssertEqual(put.request.url?.absoluteString, "https://upload.example.com/session/1")
        XCTAssertEqual(put.request.value(forHTTPHeaderField: "Content-Type"), "application/zip")
        XCTAssertEqual(put.body, Data("zipbytes".utf8))
    }

    func testDelete404IsDone() async throws {
        StubURLProtocol.install { _, _ in StubURLProtocol.json(["error": ["code": 404]], status: 404) }
        try await api().delete("gone", accessToken: "tok")
        XCTAssertEqual(StubURLProtocol.seen[0].request.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.seen[0].request.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/gone")
    }

    func testEnsureFolderCreatesWhenTheStoredOneIsTrashed() async throws {
        StubURLProtocol.install { request, _ in
            request.httpMethod == "POST" ? StubURLProtocol.json(["id": "new"]) : StubURLProtocol.json(["id": "old", "trashed": true])
        }
        let id = try await api().ensureFolder("old", accessToken: "tok")
        XCTAssertEqual(id, "new")
        let seen = StubURLProtocol.seen
        XCTAssertEqual(seen.map { $0.request.httpMethod }, ["GET", "POST"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: seen[1].body) as? [String: String])
        XCTAssertEqual(body, ["name": "Rallo Backups", "mimeType": "application/vnd.google-apps.folder"])
    }

    func testEnsureFolderKeepsALiveOneAndCreatesOnA404() async throws {
        StubURLProtocol.install { _, _ in StubURLProtocol.json(["id": "old", "trashed": false]) }
        let kept = try await api().ensureFolder("old", accessToken: "tok")
        XCTAssertEqual(kept, "old")
        XCTAssertEqual(StubURLProtocol.seen.count, 1)
        StubURLProtocol.install { request, _ in
            request.httpMethod == "POST" ? StubURLProtocol.json(["id": "new"]) : StubURLProtocol.json([:], status: 404)
        }
        let made = try await api().ensureFolder("old", accessToken: "tok")
        XCTAssertEqual(made, "new")
    }

    func testErrorMapping() async {
        for (answer, expected) in [
            (quota("storageQuotaExceeded"), GoogleDriveError.quotaFull),
            (quota("userRateLimitExceeded"), .rateLimited),
            (quota("rateLimitExceeded"), .rateLimited),
            (quota("x", status: 429), .rateLimited),
            (quota("x", status: 503), .failed(503)),
            (quota("x", status: 401), .unauthorized),
        ] {
            StubURLProtocol.install { _, _ in answer }
            do {
                try await api().delete("f", accessToken: "t")
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? GoogleDriveError, expected)
            }
        }
    }

    func testAccountEmail() async throws {
        StubURLProtocol.install { _, _ in StubURLProtocol.json(["user": ["emailAddress": "me@example.com"]]) }
        let email = try await api().accountEmail(accessToken: "t")
        XCTAssertEqual(email, "me@example.com")
        XCTAssertEqual(StubURLProtocol.seen[0].request.url?.absoluteString, "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")
    }
}
