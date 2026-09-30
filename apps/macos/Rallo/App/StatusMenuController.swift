import AppKit

/// Menu-bar access. Stays usable even when the pet window is unreachable.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var togglePet: () -> Void
        var toggleAnimations: () -> Void
        var openNotes: () -> Void
        var enableNotifications: () -> Void
        var exportBackup: () -> Void
        var exportSpreadsheet: () -> Void
        var importNotes: () -> Void
        var terminalCommand: () -> Void
        var toggleLoginItem: () -> Void
        var quit: () -> Void
    }

    private var statusItem: NSStatusItem?
    private let actions: Actions
    private let petVisible: () -> Bool
    private let notificationSummary: () -> String
    private let terminalCommandTitle: () -> String
    var animationsPaused: () -> Bool = { false }
    var loginItemState: () -> LoginItem.State = { .unavailable }

    init(
        actions: Actions,
        petVisible: @escaping () -> Bool,
        notificationSummary: @escaping () -> String,
        terminalCommandTitle: @escaping () -> String
    ) {
        self.actions = actions
        self.petVisible = petVisible
        self.notificationSummary = notificationSummary
        self.terminalCommandTitle = terminalCommandTitle
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Rallo")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Rallo"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Builds the same actions for the pet's context menu.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        populate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.addItem(item(petVisible() ? "Hide Pet" : "Show Pet", #selector(togglePet)))
        let pause = item("Pause Animations", #selector(toggleAnimations))
        pause.state = animationsPaused() ? .on : .off
        menu.addItem(pause)
        menu.addItem(item("Open Notes…", #selector(openNotes), key: "n"))
        menu.addItem(.separator())
        menu.addItem(item("Export Backup (JSON)…", #selector(exportBackup)))
        menu.addItem(item("Export Spreadsheet (CSV)…", #selector(exportSpreadsheet)))
        menu.addItem(item("Import Notes…", #selector(importNotes)))
        menu.addItem(.separator())
        menu.addItem(item(terminalCommandTitle(), #selector(terminalCommand)))
        menu.addItem(loginMenuItem())
        let status = NSMenuItem(title: notificationSummary(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(item("Enable Notifications…", #selector(enableNotifications)))
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Reminders already scheduled with macOS still arrive after quitting.", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        menu.addItem(item("Quit Rallo", #selector(quit), key: "q"))
    }

    private func loginMenuItem() -> NSMenuItem {
        let state = loginItemState()
        let title = state == .needsApproval ? "Open at Login (Allow in System Settings…)" : "Open at Login"
        let login = item(title, #selector(toggleLoginItem))
        login.state = state == .on ? .on : .off
        login.isEnabled = state != .unavailable
        if state == .unavailable { login.toolTip = "Move Rallo to Applications to open it at login." }
        return login
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePet() { actions.togglePet() }
    @objc private func toggleAnimations() { actions.toggleAnimations() }
    @objc private func openNotes() { actions.openNotes() }
    @objc private func enableNotifications() { actions.enableNotifications() }
    @objc private func exportBackup() { actions.exportBackup() }
    @objc private func exportSpreadsheet() { actions.exportSpreadsheet() }
    @objc private func importNotes() { actions.importNotes() }
    @objc private func terminalCommand() { actions.terminalCommand() }
    @objc private func toggleLoginItem() { actions.toggleLoginItem() }
    @objc private func quit() { actions.quit() }
}
