import XCTest

final class GoogleDriveDestinationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var file: URL!

    override func setUpWithError() throws {
        suite = "rallo.gdrive.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        file = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-gdrive-test-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: file)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite!).plist"))
        try? FileManager.default.removeItem(at: file)
    }

    private func destination(token: String? = "refresh") -> GoogleDriveDestination {
        GoogleDriveDestination(api: GoogleDriveAPI(clientID: "c", clientSecret: "s", session: StubURLProtocol.session()),
                               tokens: MemoryTokenStore(token), defaults: defaults)
    }

    func testKeyIsTheFolderID() {
        defaults.set("abc", forKey: BackupController.Keys.googleFolder)
        XCTAssertEqual(destination().key, "gdrive:abc")
    }

    func testStoreRefreshesCreatesTheFolderAndReturnsTheFileID() async throws {
        StubURLProtocol.install { request, _ in
            switch (request.httpMethod ?? "", request.url?.host ?? "") {
            case ("POST", "oauth2.googleapis.com"): return StubURLProtocol.json(["access_token": "acc"])
            case ("POST", "www.googleapis.com") where request.url?.path == "/drive/v3/files": return StubURLProtocol.json(["id": "folder-1"])
            case ("POST", _): return (200, ["Location": "https://upload.example.com/s"], Data())
            default: return StubURLProtocol.json(["id": "file-1"])
            }
        }
        let dest = destination()
        let id = try await dest.store(file, name: "Rallo Backup T.zip")
        XCTAssertEqual(id, "file-1")
        XCTAssertEqual(defaults.string(forKey: BackupController.Keys.googleFolder), "folder-1")
        XCTAssertEqual(dest.key, "gdrive:folder-1")
    }

    func testA401OnUploadRefreshesOnceAndRetries() async throws {
        defaults.set("folder-1", forKey: BackupController.Keys.googleFolder)
        nonisolated(unsafe) var refreshes = 0
        nonisolated(unsafe) var starts = 0
        StubURLProtocol.install { request, _ in
            if request.url?.host == "oauth2.googleapis.com" {
                refreshes += 1
                return StubURLProtocol.json(["access_token": "acc\(refreshes)"])
            }
            if request.httpMethod == "GET" { return StubURLProtocol.json(["id": "folder-1", "trashed": false]) }
            if request.httpMethod == "POST" {
                starts += 1
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer acc1" { return StubURLProtocol.json([:], status: 401) }
                return (200, ["Location": "https://upload.example.com/s"], Data())
            }
            return StubURLProtocol.json(["id": "file-2"])
        }
        let id = try await destination().store(file, name: "n.zip")
        XCTAssertEqual(id, "file-2")
        XCTAssertEqual(refreshes, 2)   // one to start, one after the 401
        XCTAssertEqual(starts, 2)
    }

    func testNoTokenOrInvalidGrantAsksToReconnect() async {
        StubURLProtocol.install { _, _ in StubURLProtocol.json(["error": "invalid_grant"], status: 400) }
        for dest in [destination(token: nil), destination()] {
            do {
                _ = try await dest.store(file, name: "n.zip")
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? BackupError, BackupError(message: "reconnect Google Drive in Settings"))
            }
        }
    }

    func testRemoveDeletesByID() async throws {
        StubURLProtocol.install { request, _ in
            request.httpMethod == "DELETE" ? (204, [:], Data()) : StubURLProtocol.json(["access_token": "acc"])
        }
        try await destination().remove("file-9")
        XCTAssertEqual(StubURLProtocol.seen.last?.request.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/file-9")
    }

    func testErrorLines() {
        XCTAssertEqual(GoogleDriveDestination.describe(GoogleDriveError.quotaFull).message, "Google Drive is full")
        XCTAssertEqual(GoogleDriveDestination.describe(GoogleDriveError.rateLimited).message, "Google Drive is busy, trying later")
        XCTAssertEqual(GoogleDriveDestination.describe(GoogleDriveError.failed(503)).message, "Google Drive answered 503")
    }
}
