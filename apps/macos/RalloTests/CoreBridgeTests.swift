import XCTest

/// Rust ↔ Swift round trips through the generated UniFFI bindings, using an
/// isolated temporary data directory (never real user data).
final class CoreBridgeTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testCreateAndListRoundTrip() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let before = try store.changeRevision()
        let text = "Review deployment\n  with “quotes” and émoji 🦊"
        let item = try store.createNote(text: text)
        XCTAssertEqual(item.text, text, "text must survive the bridge losslessly")
        XCTAssertEqual(item.status, .open)
        XCTAssertEqual(item.revision, 1)
        XCTAssertEqual(item.displayId.count, 6)
        XCTAssertEqual(try store.changeRevision(), before + 1)
        XCTAssertEqual(try store.listOpenItems(limit: 50).map(\.id), [item.id])

        // A second handle (as the CLI process would have) sees the commit.
        let other = try RalloStore.open(dataDir: dataDir.path)
        XCTAssertEqual(try other.listOpenItems(limit: 50).first?.text, text)
    }

    func testValidationErrorsAreStructured() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        XCTAssertThrowsError(try store.createNote(text: " \n\t ")) { error in
            guard case let RalloError.InvalidInput(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "TEXT_EMPTY")
        }
        XCTAssertNoThrow(try store.createNote(text: String(repeating: "a", count: 64 * 1024)))
        XCTAssertThrowsError(try store.createNote(text: String(repeating: "a", count: 64 * 1024 + 1))) { error in
            guard case let RalloError.InvalidInput(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "TEXT_TOO_LONG")
        }
        XCTAssertEqual(try store.listOpenItems(limit: 50).count, 1)
    }

    func testSwipeActionsRoundTrip() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let note = try store.createNote(text: "Call mum back")
        XCTAssertNil(note.reminder)

        let reminded = try store.remindIn(id: note.id, duration: "20m", ifRevision: note.revision)
        let reminder = try XCTUnwrap(reminded.reminder)
        XCTAssertEqual(reminder.state, .active)
        XCTAssertEqual(reminder.schedulingState, "pending", "the core reports it until the app schedules it")
        XCTAssertEqual(try store.listOpenItems(limit: 50).first?.reminder?.schedulingState, "pending")

        // The same RFC 3339 form CoreClient sends for "tomorrow at 9:00".
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let nine = Date(timeIntervalSince1970: TimeInterval(reminder.deadlineMs / 1000 + 86_400))
        let moved = try store.remindAt(id: note.id, rfc3339: formatter.string(from: nine), ifRevision: reminded.revision)
        XCTAssertEqual(moved.reminder?.deadlineMs, Int64(nine.timeIntervalSince1970) * 1000)

        XCTAssertThrowsError(try store.deleteItem(id: note.id, ifRevision: note.revision)) { error in
            guard case let RalloError.Conflict(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "REVISION_CONFLICT", "a stale row must not delete newer state")
        }
        let deleted = try store.deleteItem(id: note.id, ifRevision: moved.revision)
        XCTAssertNotNil(deleted.deletedAtMs)
        XCTAssertEqual(deleted.reminder?.state, .deleted)
        XCTAssertTrue(try store.listOpenItems(limit: 50).isEmpty)

        let restored = try store.restoreItem(id: note.id, ifRevision: deleted.revision)
        XCTAssertNil(restored.deletedAtMs)
        XCTAssertNotEqual(restored.reminder?.state, .active, "restore never re-enables a reminder")
        XCTAssertEqual(try store.listOpenItems(limit: 50).map(\.id), [note.id])
    }

    func testNewerSchemaIsRefused() throws {
        _ = try RalloStore.open(dataDir: dataDir.path)
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [dataDir.appendingPathComponent("rallo.sqlite3").path, "PRAGMA user_version = 99;"]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertThrowsError(try RalloStore.open(dataDir: dataDir.path)) { error in
            guard case let RalloError.IncompatibleSchema(found, supported, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(found, 99)
            XCTAssertLessThan(supported, 99)
        }
    }

    func testPreferencesPersistAndOnlyBumpRevisionOnChange() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        XCTAssertNil(try store.petVisibility())
        XCTAssertTrue(try store.setPetVisibility(visibility: .hidden))
        let revision = try store.changeRevision()
        XCTAssertFalse(try store.setPetVisibility(visibility: .hidden))
        XCTAssertEqual(try store.changeRevision(), revision)
        XCTAssertTrue(try store.setPetPlacement(placement: PetPlacement(x: 120.5, y: -40)))
        let reopened = try RalloStore.open(dataDir: dataDir.path)
        XCTAssertEqual(try reopened.petVisibility(), .hidden)
        XCTAssertEqual(try reopened.petPlacement(), PetPlacement(x: 120.5, y: -40))
    }

    func testInstanceLockIsExclusivePerDataDirectory() throws {
        let first = try tryAcquireInstanceLock(dataDir: dataDir.path)
        XCTAssertNotNil(first)
        XCTAssertNil(try tryAcquireInstanceLock(dataDir: dataDir.path))
        let otherDir = dataDir.appendingPathComponent("other").path
        XCTAssertNotNil(try tryAcquireInstanceLock(dataDir: otherDir))
        _ = first
    }

    func testWorkerRunsCoreCallsOffTheMainThread() async throws {
        let worker = CoreWorker()
        try await worker.open(dataDir: dataDir.path)
        let onMain = try await worker.perform { _ in Thread.isMainThread }
        XCTAssertFalse(onMain)
        let item = try await worker.perform { try $0.createNote(text: "from worker") }
        XCTAssertEqual(item.text, "from worker")
    }
}
