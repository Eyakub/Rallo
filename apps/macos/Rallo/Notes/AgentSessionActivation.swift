import AppKit

/// The exact pane a row click can reach (docs/decisions/0009), planned from
/// the session's stored `focus` and its terminal app's bundle id. `nil` from
/// `plan` means only the app comes forward.
enum AgentFocusTarget: Equatable {
    case cmux(workspace: String, panel: String)
    case terminalTab(tty: String)
    case iTermSession(tty: String)

    static let cmuxBundleID = "com.cmuxterm.app"
    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    static func plan(focus: String?, bundleID: String?) -> AgentFocusTarget? {
        guard let focus else { return nil }
        if focus.hasPrefix("cmux:"), bundleID == cmuxBundleID {
            let ids = focus.dropFirst(5).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard ids.count == 2, ids.allSatisfy(isCmuxID) else { return nil }
            return .cmux(workspace: ids[0], panel: ids[1])
        }
        if focus.hasPrefix("tty:") {
            let tty = String(focus.dropFirst(4))
            guard isTTY(tty) else { return nil }
            switch bundleID {
            case terminalBundleID: return .terminalTab(tty: tty)
            case iTermBundleID: return .iTermSession(tty: tty)
            default: return nil
            }
        }
        return nil
    }

    /// The commands to run in order, each only if the previous one succeeded.
    func commands(appURL: URL) -> [(tool: URL, arguments: [String])] {
        let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
        switch self {
        case let .cmux(workspace, panel):
            let cli = appURL.appendingPathComponent("Contents/Resources/bin/cmux")
            return [
                (cli, ["select-workspace", "--workspace", workspace]),
                (cli, ["focus-panel", "--panel", panel, "--workspace", workspace]),
            ]
        case let .terminalTab(tty):
            return [(osascript, ["-e", Self.terminalScript, tty])]
        case let .iTermSession(tty):
            return [(osascript, ["-e", Self.iTermScript, tty])]
        }
    }

    // The tty is passed as an argument, never spliced into the script.
    private static let terminalScript = """
    on run argv
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is item 1 of argv then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        error "no tab on " & item 1 of argv
    end run
    """

    private static let iTermScript = """
    on run argv
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is item 1 of argv then
                            select w
                            select t
                            select s
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        error "no session on " & item 1 of argv
    end run
    """

    private static func isCmuxID(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isTTY(_ value: String) -> Bool {
        let digits = value.dropFirst("/dev/ttys".count)
        return value.hasPrefix("/dev/ttys") && (1...6).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Brings an agent session's terminal forward: the app at once, then its
/// exact pane when Rallo knows how to reach it (0009). If that step fails
/// (the tab closed, Automation was declined, cmux's socket is off), the app
/// is already in front.
enum AgentSessionActivation {
    static func activate(_ session: AgentSessionSnapshot) {
        if session.isClickUp {
            // `clickup://` opens the conversation in the desktop app (0010);
            // without it, the same page opens in the browser.
            if let url = ClickUpWaiting.link(focus: session.focus, desktop: session.appPath != nil) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let appPath = session.appPath else { return }
        let url = URL(fileURLWithPath: appPath).standardizedFileURL
        bringForward(url)
        guard let target = AgentFocusTarget.plan(focus: session.focus, bundleID: Bundle(url: url)?.bundleIdentifier)
        else { return }
        let commands = target.commands(appURL: url)
        // ponytail: no timeout; osascript gives up after AppleScript's 2 min
        // event timeout, and a click only ever starts one of these.
        DispatchQueue.global(qos: .userInitiated).async {
            for command in commands {
                let process = Process()
                process.executableURL = command.tool
                process.arguments = command.arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return }
            }
        }
    }

    private static func bringForward(_ url: URL) {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL == url
        }) {
            running.activate()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
