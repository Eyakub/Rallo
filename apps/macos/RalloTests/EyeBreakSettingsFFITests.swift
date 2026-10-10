import XCTest

/// `eye_breaks.settings` through UniFFI and `CoreClient` (0022 §9), on a temp store.
final class EyeBreakSettingsFFITests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-eye-breaks-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func testDefaultsRoundTripAndChangeReporting() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        XCTAssertEqual(try store.eyeBreakSettings(),
                       EyeBreakSettings(enabled: false, intervalMinutes: 20, lengthSeconds: 20, warnSeconds: 10,
                                        allowSkip: true, holdOnCall: true))
        var settings = try store.eyeBreakSettings()
        settings.enabled = true
        settings.warnSeconds = 0
        XCTAssertTrue(try store.setEyeBreakSettings(settings: settings))
        XCTAssertFalse(try store.setEyeBreakSettings(settings: settings))
        XCTAssertEqual(try RalloStore.open(dataDir: dataDir.path).eyeBreakSettings(), settings)
    }

    func testAValueOutsideTheChoicesIsInvalidInput() throws {
        let store = try RalloStore.open(dataDir: dataDir.path)
        var settings = try store.eyeBreakSettings()
        settings.intervalMinutes = 25
        XCTAssertThrowsError(try store.setEyeBreakSettings(settings: settings)) { error in
            guard case let RalloError.InvalidInput(code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "INVALID_INPUT")
        }
    }

    func testCoreClientWrappers() async throws {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        var settings = try await core.eyeBreakSettings()
        settings.enabled = true
        let changed = try await core.setEyeBreakSettings(settings)
        XCTAssertTrue(changed)
        let reread = try await core.eyeBreakSettings()
        XCTAssertTrue(reread.enabled)
    }
}
