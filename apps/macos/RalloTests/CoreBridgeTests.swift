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

    func testCreateReminderTakesAPhraseAndSavesNothingOnARefusal() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let item = try store.createReminder(text: "Stretch", when: "in 2 hours")
        let after = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertEqual(item.text, "Stretch")
        let deadline = try XCTUnwrap(item.reminder?.deadlineMs)
        XCTAssertTrue((before + 7_200_000...after + 7_200_000).contains(deadline), "\(deadline)")

        XCTAssertThrowsError(try store.createReminder(text: "Nope", when: "later")) { error in
            guard case let RalloError.InvalidInput(code, message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "INVALID_TIME")
            XCTAssertEqual(message, "couldn't read \"later\" as a time; try \"in 2h\", \"5pm\" or \"fri 9am\"")
        }
        XCTAssertEqual(try store.listOpenItems(limit: 50).map(\.text), ["Stretch"], "a refused time saves no note")
    }

    /// Image paths are under the canonical directory (/private/var/...);
    /// `resolvingSymlinksInPath` would strip the /private.
    private static func canonical(_ url: URL) -> String {
        url.path.withCString { realpath($0, nil).map { String(cString: $0) } } ?? url.path
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]) + Data("IHDRfake".utf8)

    func testANoteWithImagesRoundTrips() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let item = try store.createNoteWithImages(text: "", images: [Self.png, Self.png])
        XCTAssertEqual(item.text, "")
        XCTAssertEqual(item.images.count, 2)
        let first = try XCTUnwrap(item.images.first)
        XCTAssertEqual(first.mimeType, "image/png")
        XCTAssertEqual(first.byteSize, Int64(Self.png.count))
        XCTAssertTrue(first.path.hasPrefix(Self.canonical(dataDir)), "Rallo keeps its own copy in its data directory")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.path)), Self.png)
        XCTAssertEqual(try store.listOpenItems(limit: 50).first?.images.map(\.id), item.images.map(\.id))
    }

    func testAttachAndDetachMoveTheRevision() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let note = try store.createNote(text: "Login broken")
        XCTAssertEqual(note.images, [])
        let attached = try store.attachImages(id: note.id, images: [Self.png], ifRevision: note.revision)
        XCTAssertEqual(attached.images.count, 1)
        XCTAssertEqual(attached.revision, note.revision + 1)
        let detached = try store.detachImage(id: note.id, imageId: attached.images[0].id, ifRevision: attached.revision)
        XCTAssertEqual(detached.images, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: attached.images[0].path))
    }

    func testAnUnsupportedImageIsRefusedAndNothingIsSaved() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        XCTAssertThrowsError(try store.createNoteWithImages(text: "x", images: [Data("not an image".utf8)])) { error in
            guard case let RalloError.InvalidInput(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "IMAGE_UNSUPPORTED")
        }
        XCTAssertEqual(try store.listOpenItems(limit: 50).count, 0)
    }

    func testAZipExportImportsIntoAnotherStore() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        _ = try store.createNoteWithImages(text: "with image", images: [Self.png])
        let archive = dataDir.appendingPathComponent("export.zip")
        let result = try store.exportToFile(path: archive.path, format: .zip, overwrite: false)
        XCTAssertEqual(result.items, 1)
        XCTAssertEqual(result.path, archive.path)

        let otherDir = dataDir.appendingPathComponent("other")
        let other = try RalloStore.open(dataDir: otherDir.path)
        let preview = try other.previewImportFile(path: archive.path)
        XCTAssertEqual(preview.new, 1)
        XCTAssertEqual(preview.format, .zip)
        _ = try other.applyImportFile(path: archive.path)
        let image = try XCTUnwrap(other.listOpenItems(limit: 50).first?.images.first)
        XCTAssertTrue(image.path.hasPrefix(Self.canonical(otherDir)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image.path)), Self.png)
    }

    func testAJsonExportWarnsThatImagesAreLeftOut() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        _ = try store.createNoteWithImages(text: "with image", images: [Self.png])
        let result = try store.exportToFile(path: dataDir.appendingPathComponent("x.json").path, format: .json, overwrite: false)
        XCTAssertEqual(result.warnings, ["1 image isn't included; use --format zip"])
    }

    func testTheSweepRunsOnAnEmptyStore() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let result = try store.sweepImages()
        XCTAssertEqual(result.expiredImages, 0)
        XCTAssertEqual(result.orphanFiles, 0)
    }
}
