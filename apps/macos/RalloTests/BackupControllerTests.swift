import XCTest

@MainActor
final class BackupControllerTests: XCTestCase {
    private var root: URL!
    private var core: CoreClient!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        core = CoreClient(dataDir: root.appendingPathComponent("data").path)
        try await core.open()
        suite = "rallo.backup.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite!).plist"))
        try? FileManager.default.removeItem(at: root)
    }

    private func controller(scratch: Bool = true, google: Bool = false, token: String? = nil) -> BackupController {
        BackupController(core: core, defaults: defaults, log: DiagnosticsLog(dataDir: root.appendingPathComponent("data").path),
                         isScratch: scratch, tokens: MemoryTokenStore(token), googleConfigured: google,
                         home: root.appendingPathComponent("home"), macName: "Test Mac")
    }

    private func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    private func zips(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".zip") }.sorted()
    }

    func testThreeRunsKeepTheTwoNewestAndLeaveStrangersAlone() async throws {
        let dir = folder("out")
        let backup = controller()
        backup.select(.folder, folder: dir.path)
        _ = try await core.createNote("first")
        await backup.backUpNow()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("keep-me.zip"))
        let first = zips(dir).filter { $0 != "keep-me.zip" }
        XCTAssertEqual(first.count, 1)
        // Deleted by hand before it would be pruned: must not fail the run.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(first[0]))
        try await Task.sleep(nanoseconds: 1_100_000_000)
        await backup.backUpNow()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        await backup.backUpNow()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        await backup.backUpNow()
        XCTAssertNil(backup.lastError)
        let now = zips(dir)
        XCTAssertEqual(now.count, 3)   // two backups + keep-me
        XCTAssertTrue(now.contains("keep-me.zip"))
        let backups = now.filter { $0 != "keep-me.zip" }
        XCTAssertEqual(backups, backups.sorted())

        let summary = try await core.previewImportFile(dir.appendingPathComponent(backups[1]).path)
        XCTAssertGreaterThanOrEqual(summary.totalRecords, 1)
    }

    func testCheckIfDueBacksUpOnce() async throws {
        let dir = folder("once")
        let backup = controller()
        backup.select(.folder, folder: dir.path)
        _ = try await core.createNote("note")
        await backup.checkIfDue()
        await backup.checkIfDue()
        XCTAssertEqual(zips(dir).count, 1)
    }

    func testSwitchingFolderStartsANewListAndKeepsTheOldFiles() async throws {
        let one = folder("one"), two = folder("two")
        let backup = controller()
        _ = try await core.createNote("note")
        backup.select(.folder, folder: one.path)
        await backup.backUpNow()
        backup.select(.folder, folder: two.path)
        XCTAssertNil(backup.lastSuccess)
        await backup.backUpNow()
        XCTAssertEqual(zips(one).count, 1)
        XCTAssertEqual(zips(two).count, 1)
    }

    func testFailureSetsTheErrorKeepsLastSuccessAndCleansTemp() async throws {
        let dir = folder("ok")
        let backup = controller()
        backup.select(.folder, folder: dir.path)
        await backup.backUpNow()
        let success = try XCTUnwrap(backup.lastSuccess)
        let before = tempBackupDirs()
        backup.select(.folder, folder: "/dev/null/nope")
        await backup.backUpNow()
        XCTAssertNotNil(backup.lastError)
        XCTAssertNil(backup.lastSuccess)   // new destination, fresh schedule
        XCTAssertEqual(tempBackupDirs(), before)
        XCTAssertNotNil(success)
    }

    func testFailureInTheSameDestinationKeepsLastSuccess() async throws {
        let dir = folder("same")
        let backup = controller()
        backup.select(.folder, folder: dir.path)
        await backup.backUpNow()
        let success = try XCTUnwrap(backup.lastSuccess)
        try FileManager.default.removeItem(at: dir)
        try Data("file".utf8).write(to: dir)   // a file where the folder should be
        await backup.backUpNow()
        XCTAssertNotNil(backup.lastError)
        XCTAssertEqual(backup.lastSuccess, success)
    }

    func testICloudIsUnavailableInAScratchInstance() throws {
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: FolderDestination.iCloudRoot(home: home), withIntermediateDirectories: true)
        XCTAssertFalse(controller(scratch: true).iCloudAvailable)
        XCTAssertTrue(controller(scratch: false).iCloudAvailable)
        let scratch = controller(scratch: true)
        scratch.select(.icloud)
        XCTAssertEqual(scratch.kind, .off)
    }

    func testICloudBacksUpIntoRalloBackupsAndKeepsTheTwoNewest() async throws {
        let home = root.appendingPathComponent("home")
        let backup = controller(scratch: false)
        XCTAssertFalse(backup.iCloudAvailable)   // no CloudDocs folder: iCloud Drive is off
        try FileManager.default.createDirectory(at: FolderDestination.iCloudRoot(home: home), withIntermediateDirectories: true)
        XCTAssertTrue(backup.iCloudAvailable)
        backup.select(.icloud)
        XCTAssertEqual(backup.kind, .icloud)
        _ = try await core.createNote("note")
        for _ in 0..<3 {
            await backup.backUpNow()
            try await Task.sleep(nanoseconds: 1_100_000_000)   // names have one-second resolution
        }
        XCTAssertNil(backup.lastError)
        let names = zips(FolderDestination.iCloudRoot(home: home).appendingPathComponent("Rallo Backups", isDirectory: true))
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("Rallo Backup Test Mac ") })
    }

    func testFolderRemoveDeletesOnlyPlainBackupNames() async throws {
        let dir = folder("rm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mine = "Rallo Backup Test Mac 2026-10-21 09.10.00.zip"
        for name in [mine, "other.zip", "Rallo Backup x.txt"] { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        let outside = root.appendingPathComponent("Rallo Backup outside.zip")
        try Data("x".utf8).write(to: outside)
        let destination = FolderDestination(folder: dir)
        for handle in ["other.zip", "Rallo Backup x.txt", "..", "../Rallo Backup outside.zip", "Rallo Backup /../x.zip"] {
            try await destination.remove(handle)
        }
        XCTAssertEqual(zips(dir), [mine, "other.zip"].sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        try await destination.remove(mine)
        XCTAssertEqual(zips(dir), ["other.zip"])
    }

    private func googleReason(_ backup: BackupController) async -> String? {
        defaults.set("google", forKey: "backupKind")
        await backup.backUpNow()
        return backup.lastError
    }

    func testGoogleUnavailableReasons() async {
        let scratch = await googleReason(controller(scratch: true, google: true, token: "t"))
        XCTAssertEqual(scratch, "Google Drive is off in instances started with --data-dir")
        let notSetUp = await googleReason(controller(scratch: false, google: false))
        XCTAssertEqual(notSetUp, "Google Drive isn’t set up in this build")
        let notConnected = await googleReason(controller(scratch: false, google: true))
        XCTAssertEqual(notConnected, "Google Drive isn’t connected")
    }

    func testGoogleCannotBeSelectedWhenUnavailableAndScratchNeverConnects() async {
        let backup = controller(scratch: true, google: true)
        backup.select(.google)
        XCTAssertEqual(backup.kind, .off)
        XCTAssertFalse(backup.googleConnected)
        do {
            _ = try await backup.connectGoogleDrive()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? GoogleDriveError, .disabled)
        }
    }

    private func tempBackupDirs() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("rallo-backup-") && !$0.hasPrefix("rallo-backup-test-") })
    }
}
