import XCTest

/// Link decisions for "Enable Terminal Command…", against a fake home and
/// app bundle in a temporary directory (never the real ~/.local/bin).
final class TerminalCommandTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var app: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-term-\(UUID().uuidString)")
        home = root.appendingPathComponent("Home With Spaces")
        app = home.appendingPathComponent("Applications/Rallo.app")
        try makeCLI(in: app)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var localBin: URL { home.appendingPathComponent(".local/bin") }

    private func makeCLI(in bundle: URL) throws {
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let cli = helpers.appendingPathComponent("rallo")
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
    }

    private func inspect(path: [String]? = nil) -> TerminalCommand.State {
        TerminalCommand.inspect(appURL: app, home: home, pathDirectories: path ?? [localBin.path, "/usr/bin"])
    }

    func testFreshInstallLinksIntoLocalBinOnPath() throws {
        let state = inspect()
        XCTAssertEqual(state, .available(directory: localBin, onPath: true))
        let link = try TerminalCommand.enable(state, appURL: app)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       TerminalCommand.cliURL(in: app).path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.path))
        XCTAssertEqual(inspect(), .enabled(link: link, onPath: true))
    }

    func testLocalBinOffPathIsStillProposedAndReported() {
        XCTAssertEqual(inspect(path: ["/usr/bin"]), .available(directory: localBin, onPath: false))
    }

    func testMovedAppIsRepairable() throws {
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let old = "/Volumes/Rallo/Rallo.app/Contents/Helpers/rallo"
        try FileManager.default.createSymbolicLink(atPath: localBin.appendingPathComponent("rallo").path,
                                                   withDestinationPath: old)
        let state = inspect()
        XCTAssertEqual(state, .repairable(link: localBin.appendingPathComponent("rallo"), oldTarget: old, onPath: true))
        _ = try TerminalCommand.enable(state, appURL: app)
        XCTAssertEqual(inspect(), .enabled(link: localBin.appendingPathComponent("rallo"), onPath: true))
    }

    func testAnotherRalloIsNeverReplaced() throws {
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let other = localBin.appendingPathComponent("rallo")
        FileManager.default.createFile(atPath: other.path, contents: Data("someone else's tool".utf8))
        let state = inspect()
        XCTAssertEqual(state, .conflict(existing: other))
        XCTAssertThrowsError(try TerminalCommand.enable(state, appURL: app))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "someone else's tool")
    }

    func testAnEarlierRalloOnPathIsAConflict() throws {
        let earlier = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: earlier.appendingPathComponent("rallo").path, contents: Data())
        XCTAssertEqual(inspect(path: [earlier.path, localBin.path]),
                       .conflict(existing: earlier.appendingPathComponent("rallo")))
    }

    func testAppOutsideApplicationsIsNotInstalled() throws {
        app = root.appendingPathComponent("Downloads/Rallo.app")
        try makeCLI(in: app)
        XCTAssertEqual(inspect(), .notInstalled)
    }
}
