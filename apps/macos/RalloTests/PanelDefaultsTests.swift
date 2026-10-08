import XCTest

/// 0019 §10: only the real data directory may write the app's own defaults.
final class PanelDefaultsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/rallo-home-test", isDirectory: true)
    private var real: String { PanelDefaults.realDataDir(home: home).path }

    func testTheRealDataDirUsesStandardDefaults() {
        XCTAssertNil(PanelDefaults.suiteName(forDataDir: real, home: home))
    }

    func testAnyOtherDirUsesTheScratchSuite() {
        XCTAssertEqual(PanelDefaults.suiteName(forDataDir: "/tmp/rallo-scratch", home: home), "com.razlio.rallo.scratch")
        XCTAssertEqual(PanelDefaults.suiteName(forDataDir: real + "-other", home: home), "com.razlio.rallo.scratch")
    }

    func testTrailingSlashAndDotDotVariantsOfTheRealDirStillCount() {
        XCTAssertNil(PanelDefaults.suiteName(forDataDir: real + "/", home: home))
        XCTAssertNil(PanelDefaults.suiteName(forDataDir: real + "/../Rallo", home: home))
    }
}
