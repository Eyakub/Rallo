import XCTest

/// Plan 1's API (0021 §10, the cross-plan contract) as plan 2 relies on it.
/// This file creates no production code.
final class AttentionContractTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-attention-contract-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testAlertSettingsRecordAndDefaults() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        let defaults = try store.alertSettings()
        XCTAssertEqual(defaults, AlertSettings(summon: true, sound: .ralloChime, nag: true, nagIntervalMinutes: 2,
                                               nagMaxRounds: 5, glow: false, agents: true))
        _ = [AlertSound.ralloChime, .bambooKnock, .gentleBell, .system, .none]
    }

    func testAlertSettingsRoundTripAndOnlyReportChanges() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        var settings = try store.alertSettings()
        settings.glow = true
        XCTAssertTrue(try store.setAlertSettings(settings: settings))
        XCTAssertFalse(try store.setAlertSettings(settings: settings))
        XCTAssertEqual(try RalloStore.open(dataDir: dataDir.path).alertSettings().glow, true)
    }

    func testAlertSettingsRejectAValueOutsideTheChoices() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        var settings = try store.alertSettings()
        settings.nagIntervalMinutes = 3
        XCTAssertThrowsError(try store.setAlertSettings(settings: settings)) { error in
            guard case RalloError.InvalidInput = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testCoreClientWrappers() async throws {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        var settings = try await core.alertSettings()
        settings.summon = false
        let changed = try await core.setAlertSettings(settings)
        XCTAssertTrue(changed)
        let reread = try await core.alertSettings()
        XCTAssertFalse(reread.summon)
    }
}
