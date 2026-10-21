import XCTest

final class BackupPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverBackedUpAndChangedIsDue() {
        XCTAssertTrue(BackupSchedule.isDue(now: now, lastSuccess: nil, lastRevision: nil, revision: 5))
        XCTAssertTrue(BackupSchedule.isDue(now: now, lastSuccess: nil, lastRevision: 4, revision: 5))
    }

    func testSameRevisionIsNeverDue() {
        XCTAssertFalse(BackupSchedule.isDue(now: now, lastSuccess: now - 3 * 86_400, lastRevision: 5, revision: 5))
    }

    func testChangedButWithinADayIsNotDueAndExactlyADayIs() {
        XCTAssertFalse(BackupSchedule.isDue(now: now, lastSuccess: now - 23 * 3600, lastRevision: 4, revision: 5))
        XCTAssertTrue(BackupSchedule.isDue(now: now, lastSuccess: now - 24 * 3600, lastRevision: 4, revision: 5))
    }

    func testNilLastRevisionIsDueOnceADayPassed() {
        XCTAssertTrue(BackupSchedule.isDue(now: now, lastSuccess: now - 25 * 3600, lastRevision: nil, revision: 0))
    }

    func testRetentionKeepsTheNewest() {
        let two = BackupRetention.split(["a", "b", "c", "d"], keep: 2)
        XCTAssertEqual(two.kept, ["c", "d"])
        XCTAssertEqual(two.removed, ["a", "b"])
        let one = BackupRetention.split(["a"], keep: 2)
        XCTAssertEqual(one.kept, ["a"])
        XCTAssertEqual(one.removed, [])
    }

    func testFileNames() {
        let date = ISO8601DateFormatter().date(from: "2026-10-21T09:10:05Z")!
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(BackupNaming.fileName(mac: "Eyakub's MacBook Pro", date: date, timeZone: utc),
                       "Rallo Backup Eyakub's MacBook Pro 2026-10-21 09.10.05.zip")
        XCTAssertTrue(BackupNaming.fileName(mac: "a/b:c", date: date, timeZone: utc).contains(" a-b-c "))
        XCTAssertTrue(BackupNaming.fileName(mac: "", date: date, timeZone: utc).hasPrefix("Rallo Backup Mac 2026"))
    }
}
