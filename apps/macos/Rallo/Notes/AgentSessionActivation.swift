import AppKit

/// Brings an agent session's terminal app forward (0007's "which terminal to
/// bring forward"): the app, not the exact tab.
enum AgentSessionActivation {
    static func activate(appPath: String) {
        let url = URL(fileURLWithPath: appPath).standardizedFileURL
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL == url
        }) {
            running.activate()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
