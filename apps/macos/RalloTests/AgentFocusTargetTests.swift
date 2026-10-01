import XCTest

/// Which exact pane a row click reaches (docs/decisions/0009).
final class AgentFocusTargetTests: XCTestCase {
    private let ws = "A8E6AFDC-7521-43FE-95F1-CEE1DB2B0B8F"
    private let panel = "5177B057-74A2-4FC1-BDFE-39CA9CE39FCC"

    func testCmuxPaneOnlyInCmux() {
        XCTAssertEqual(AgentFocusTarget.plan(focus: "cmux:\(ws):\(panel)", bundleID: "com.cmuxterm.app"),
                       .cmux(workspace: ws, panel: panel))
        XCTAssertNil(AgentFocusTarget.plan(focus: "cmux:\(ws):\(panel)", bundleID: "com.apple.Terminal"))
    }

    func testTTYPicksTerminalOrITermAndNothingElse() {
        XCTAssertEqual(AgentFocusTarget.plan(focus: "tty:/dev/ttys003", bundleID: "com.apple.Terminal"),
                       .terminalTab(tty: "/dev/ttys003"))
        XCTAssertEqual(AgentFocusTarget.plan(focus: "tty:/dev/ttys003", bundleID: "com.googlecode.iterm2"),
                       .iTermSession(tty: "/dev/ttys003"))
        XCTAssertNil(AgentFocusTarget.plan(focus: "tty:/dev/ttys003", bundleID: "com.microsoft.VSCode"))
    }

    func testMalformedFocusFallsBackToTheApp() {
        XCTAssertNil(AgentFocusTarget.plan(focus: nil, bundleID: "com.apple.Terminal"))
        XCTAssertNil(AgentFocusTarget.plan(focus: "tty:/dev/ttys003\" & quit", bundleID: "com.apple.Terminal"))
        XCTAssertNil(AgentFocusTarget.plan(focus: "tty:/etc/passwd", bundleID: "com.apple.Terminal"))
        XCTAssertNil(AgentFocusTarget.plan(focus: "cmux:\(ws)", bundleID: "com.cmuxterm.app"))
        XCTAssertNil(AgentFocusTarget.plan(focus: "cmux:\(ws):--help x", bundleID: "com.cmuxterm.app"))
    }

    func testCmuxSelectsTheWorkspaceThenThePanel() {
        let app = URL(fileURLWithPath: "/Applications/cmux.app")
        let commands = AgentFocusTarget.cmux(workspace: ws, panel: panel).commands(appURL: app)
        XCTAssertEqual(commands.map(\.tool.path), Array(repeating: "/Applications/cmux.app/Contents/Resources/bin/cmux", count: 2))
        XCTAssertEqual(commands.map(\.arguments), [
            ["select-workspace", "--workspace", ws],
            ["focus-panel", "--panel", panel, "--workspace", ws],
        ])
    }

    func testTheTTYIsAnArgumentNotPartOfTheScript() {
        let commands = AgentFocusTarget.terminalTab(tty: "/dev/ttys003").commands(appURL: URL(fileURLWithPath: "/"))
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].tool.path, "/usr/bin/osascript")
        XCTAssertEqual(commands[0].arguments.last, "/dev/ttys003")
        XCTAssertFalse(commands[0].arguments[1].contains("ttys003"))
    }
}
