import XCTest

@MainActor
final class UpdateCheckerDefaultsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "rallo.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func checker() -> UpdateChecker {
        UpdateChecker(log: DiagnosticsLog(dataDir: NSTemporaryDirectory() + suite), defaults: defaults)
    }

    func testUnsetKeyMeansEnabled() {
        XCTAssertTrue(checker().isEnabled)
    }

    func testStoredFalseStaysOff() {
        defaults.set(false, forKey: UpdateChecker.enabledKey)
        XCTAssertFalse(checker().isEnabled)
    }

    func testStoredTrueIsOn() {
        defaults.set(true, forKey: UpdateChecker.enabledKey)
        XCTAssertTrue(checker().isEnabled)
    }
}
