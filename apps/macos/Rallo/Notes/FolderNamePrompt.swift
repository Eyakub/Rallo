import AppKit

/// The one "name a folder" prompt (0019 §10), used by New Folder… here and by
/// New Folder and Rename in the window later. An alert with a text field that
/// stays up and shows the error while `validate` throws; `ask` returns the
/// name once `validate` succeeds, or nil on Cancel.
///
/// `validate` is async because the core is only reachable through CoreWorker;
/// callers pass the real create/rename, so the core's own message (empty, too
/// long, "Notes", already taken) is what the alert shows.
@MainActor
enum FolderNamePrompt {
    static func ask(title: String, initial: String, validate: @escaping (String) async throws -> Void) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Up to 50 characters."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Folder name"
        field.setAccessibilityLabel("Folder name")
        alert.accessoryView = field
        let ok = alert.addButton(withTitle: "OK")
        let cancel = alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.initialFirstResponder = field

        let handler = ConfirmHandler()
        handler.run = {
            let name = field.stringValue
            // One attempt at a time; both buttons rest until it is answered.
            ok.isEnabled = false
            cancel.isEnabled = false
            Task { @MainActor in
                do {
                    try await validate(name)
                    handler.accepted = name
                    // abortModal wakes the modal loop from outside an event handler; runModal's return code is ignored.
                    NSApp.abortModal()
                } catch {
                    alert.informativeText = (error as? RalloError)?.displayMessage ?? error.localizedDescription
                    alert.layout()
                    ok.isEnabled = true
                    cancel.isEnabled = true
                    alert.window.makeFirstResponder(field)
                }
            }
        }
        // Replacing the OK button's action keeps the alert open after a click.
        ok.target = handler
        ok.action = #selector(ConfirmHandler.confirm(_:))
        withExtendedLifetime(handler) { _ = alert.runModal() }
        return handler.accepted
    }
}

private final class ConfirmHandler: NSObject {
    var run: () -> Void = {}
    var accepted: String?

    @objc func confirm(_ sender: Any?) { run() }
}
