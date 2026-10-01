import AppKit

/// The "Connect ClickUp" dialog (0010). It stays open while ClickUp checks
/// the token, then says who is connected, or why not, in the same window;
/// on a failure the token can be fixed and tried again.
@MainActor
final class ClickUpConnectDialog: NSObject {
    private static let intro = """
    Rallo checks ClickUp once a minute and lists direct messages waiting for your reply. \
    Paste a personal API token from ClickUp → Settings → Apps. It stays in your Keychain; \
    Rallo never stores message text.
    """

    private let watcher: ClickUpWatcher
    private let alert = NSAlert()
    private let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    private var connected = false

    init(watcher: ClickUpWatcher) {
        self.watcher = watcher
    }

    /// Runs modally until Cancel, or Done after a successful connection.
    func run() {
        alert.messageText = "Connect ClickUp"
        alert.informativeText = Self.intro
        field.placeholderString = "pk_…"
        alert.accessoryView = field
        // Connect keeps the dialog open: its action replaces NSAlert's own,
        // which would end the modal session on any click.
        let connect = alert.addButton(withTitle: "Connect")
        connect.target = self
        connect.action = #selector(connectPressed)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        alert.runModal()
    }

    @objc private func connectPressed() {
        if connected {
            NSApp.stopModal()
            return
        }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            NSSound.beep()
            return
        }
        show("Connect ClickUp", "Checking the token with ClickUp…", busy: true)
        Task {
            do {
                let who = try await watcher.connect(token: token)
                connected = true
                field.isHidden = true
                alert.buttons[0].title = "Done"
                alert.buttons[1].isHidden = true
                show("Connected to ClickUp", """
                Signed in as \(who). Direct messages waiting for your reply will appear under \
                “Waiting for you” in the notes panel within a minute.
                """, busy: false)
            } catch {
                show("Couldn’t connect ClickUp", Self.reason(for: error), busy: false)
                alert.window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    private func show(_ title: String, _ text: String, busy: Bool) {
        alert.messageText = title
        alert.informativeText = text
        field.isEnabled = !busy
        alert.buttons.forEach { $0.isEnabled = !busy }
        alert.layout()
    }

    private static func reason(for error: Error) -> String {
        switch error {
        case ClickUpError.unauthorized:
            "ClickUp didn’t accept that token. Check that you copied all of it (it starts with pk_)."
        case is ClickUpError:
            "ClickUp answered with an error. Try again in a moment."
        default:
            "Rallo couldn’t reach ClickUp. Check your connection and try again."
        }
    }
}
