import XCTest

/// 0019 §10: what the panel asks of the core, through the real CoreClient on a
/// temporary data directory (never real user data).
final class CoreClientFoldersTests: XCTestCase {
    private var dataDir: URL!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-folders-client-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func client() async throws -> CoreClient {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        return core
    }

    func testANewNoteLandsInTheScopesFolderAndListsThere() async throws {
        let core = try await client()
        let work = try await core.createFolder("Work")
        let filed = try await core.createNote("Plan #bug", images: [], folderID: work.id)
        let loose = try await core.createNote("Loose", images: [])
        XCTAssertEqual(filed.folderName, "Work")
        XCTAssertNil(loose.folderId)

        let inWork = try await core.openItems(scope: .folder(id: work.id))
        XCTAssertEqual(inWork.map(\.id), [filed.id])
        let unfiled = try await core.openItems(scope: .unfiled)
        XCTAssertEqual(unfiled.map(\.id), [loose.id])
        let all = try await core.openItems()
        XCTAssertEqual(Set(all.map(\.id)), [filed.id, loose.id])

        let overview = try await core.folderOverview()
        XCTAssertEqual(overview.allOpen, 2)
        XCTAssertEqual(overview.unfiledOpen, 1)
        XCTAssertEqual(overview.folders.map(\.openCount), [1])
    }

    func testMoveOutAndBackIsWhatUndoDoes() async throws {
        let core = try await client()
        let work = try await core.createFolder("Work")
        let note = try await core.createNote("Plan", images: [], folderID: work.id)
        let moved = try await core.moveItem(note, folderID: nil)
        XCTAssertNil(moved.folderId)
        let back = try await core.moveItem(moved, folderID: work.id)
        XCTAssertEqual(back.folderId, work.id)
        XCTAssertEqual(back.folderName, "Work")
    }

    func testMoveWithAStaleRevisionIsAConflict() async throws {
        let core = try await client()
        let work = try await core.createFolder("Work")
        let note = try await core.createNote("Plan", images: [])
        _ = try await core.moveItem(note, folderID: work.id)   // note is now stale
        do {
            _ = try await core.moveItem(note, folderID: nil)
            XCTFail("a stale move must not apply")
        } catch let error as RalloError {
            guard case let .Conflict(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "REVISION_CONFLICT")
        }
        // Nothing moved by the failed attempt.
        let inWork = try await core.openItems(scope: .folder(id: work.id))
        XCTAssertEqual(inWork.map(\.id), [note.id])
    }

    func testFolderNameErrorsKeepTheirCodes() async throws {
        let core = try await client()
        _ = try await core.createFolder("Work")
        for bad in ["", "   ", "notes", "NOTES", String(repeating: "x", count: 51)] {
            do {
                _ = try await core.createFolder(bad)
                XCTFail("“\(bad)” must be refused")
            } catch let error as RalloError {
                guard case let .InvalidInput(code, message) = error else { return XCTFail("unexpected \(error)") }
                XCTAssertEqual(code, "FOLDER_NAME_INVALID")
                XCTAssertFalse(error.displayMessage.isEmpty, message)
            }
        }
        do {
            _ = try await core.createFolder("work")
            XCTFail("a duplicate differing only by case must be refused")
        } catch let error as RalloError {
            guard case let .Conflict(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "FOLDER_EXISTS")
        }
        let overview = try await core.folderOverview()
        XCTAssertEqual(overview.folders.map(\.name), ["Work"], "refused names create nothing")
    }
}
