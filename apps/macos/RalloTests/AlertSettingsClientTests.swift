import XCTest

/// 0021 §10 and §2 through the bindings and the real CoreClient, on a
/// temporary data directory (never real user data).
final class AlertSettingsClientTests: XCTestCase {
    private var dataDir: URL!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-alerts-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func client() async throws -> CoreClient {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        return core
    }

    func testAFreshStoreHasTheSpecDefaults() async throws {
        let settings = try await client().alertSettings()
        XCTAssertEqual(settings, AlertSettings(summon: true, sound: .ralloChime, nag: true, nagIntervalMinutes: 2,
                                               nagMaxRounds: 5, glow: false, agents: true))
    }

    func testSettingsRoundTripAndAnIdenticalSaveIsANoOp() async throws {
        let core = try await client()
        var settings = try await core.alertSettings()
        settings.glow = true
        settings.sound = .bambooKnock
        settings.nagIntervalMinutes = 5
        let first = try await core.setAlertSettings(settings)
        let second = try await core.setAlertSettings(settings)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let read = try await core.alertSettings()
        XCTAssertEqual(read, settings)
    }

    func testAnOutOfRangeValueIsInvalidInput() async throws {
        let core = try await client()
        var settings = try await core.alertSettings()
        settings.nagMaxRounds = 4
        do {
            try await core.setAlertSettings(settings)
            XCTFail("4 repeats was accepted")
        } catch {
            guard case let RalloError.InvalidInput(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "INVALID_INPUT")
        }
    }

    /// Review Focus 3: a page smaller than the due list must not hide a due reminder.
    func testAllDueItemsPagesThroughEveryDueReminder() async throws {
        let core = try await client()
        for text in ["one", "two", "three"] {
            let note = try await core.createNote(text)
            _ = try await core.remindIn(note, duration: "1s")
        }
        _ = try await core.createReminder("later", when: "in 2 hours")
        try await Task.sleep(nanoseconds: 1_400_000_000)
        let due = try await core.allDueItems(pageSize: 2)
        XCTAssertEqual(Set(due.map(\.text)), ["one", "two", "three"])
    }
}
