import XCTest

final class LaunchOptionsTests: XCTestCase {
    func testPrepareUninstallFlag() {
        XCTAssertFalse(LaunchOptions.parse(["Rallo"]).prepareUninstall)
        XCTAssertTrue(LaunchOptions.parse(["Rallo", "--prepare-uninstall"]).prepareUninstall)
    }

    func testDataDir() {
        XCTAssertEqual(LaunchOptions.parse(["Rallo", "--data-dir", "/tmp/x"]).dataDir, "/tmp/x")
    }
}
