import AppKit

/// Menu-bar access. Stays usable even when the pet window is unreachable.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var togglePet: () -> Void
        var toggleAnimations: () -> Void
        var openNotes: () -> Void
        var jumpToWaitingAgent: () -> Void
        var selectAgentSession: (AgentSessionSnapshot) -> Void
        var enableNotifications: () -> Void
        var toggleNotifyLongWait: () -> Void
        var toggleClickUp: () -> Void
        var exportBackup: () -> Void
        var exportSpreadsheet: () -> Void
        var importNotes: () -> Void
        var terminalCommand: () -> Void
        var toggleLoginItem: () -> Void
        var quit: () -> Void
    }

    /// ⌃⌥⌘, shown on the shortcut-carrying menu items (0008); the global
    /// behaviour comes from `GlobalShortcuts`, not this display alone.
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    private var statusItem: NSStatusItem?
    private let actions: Actions
    private let petVisible: () -> Bool
    private let notificationSummary: () -> String
    private let terminalCommandTitle: () -> String
    var animationsPaused: () -> Bool = { false }
    var loginItemState: () -> LoginItem.State = { .unavailable }
    var agentSessions: () -> [AgentSessionSnapshot] = { [] }
    var notifyLongWaitEnabled: () -> Bool = { false }
    var notificationsAuthorized: () -> Bool = { false }
    var jumpShortcutAvailable: () -> Bool = { true }
    var notesShortcutAvailable: () -> Bool = { true }
    var clickUpConnected: () -> Bool = { false }
    var clickUpStatus: () -> String? = { nil }

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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Rallo")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeft
        item.button?.toolTip = "Rallo"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Waiting-agent count beside the paw, nothing at zero, and a tooltip
    /// listing every tracked session (0008). Called from the same reload
    /// path the panel and pet use.
    func refreshAgents(_ sessions: [AgentSessionSnapshot]) {
        guard let button = statusItem?.button else { return }
        let waiting = sessions.filter { $0.state == "waiting" }.count
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.toolTip = sessions.isEmpty ? "Rallo" : Self.tooltipLines(sessions).joined(separator: "\n")
    }

    private static func tooltipLines(_ sessions: [AgentSessionSnapshot]) -> [String] {
        AgentSessionFormatting.sorted(sessions).map(agentMenuLine)
    }

    /// "Claude Code · shop — Waiting for permission: Bash (4 min)".
    private static func agentMenuLine(for session: AgentSessionSnapshot) -> String {
        let time = AgentSessionFormatting.relativeTime(updatedAtMs: session.updatedAtMs)
        return "\(AgentSessionFormatting.title(for: session)) — \(AgentSessionFormatting.subtitle(for: session)) (\(time))"
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
        populateAgentsSection(menu)
        menu.addItem(item(petVisible() ? "Hide Pet" : "Show Pet", #selector(togglePet)))
        let pause = item("Pause Animations", #selector(toggleAnimations))
        pause.state = animationsPaused() ? .on : .off
        menu.addItem(pause)
        menu.addItem(notesMenuItem())
        menu.addItem(jumpMenuItem())
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
        menu.addItem(notifyLongWaitMenuItem())
        if !notificationsAuthorized() {
            let note = NSMenuItem(title: "Notifications are off for Rallo", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        menu.addItem(item(clickUpConnected() ? "Disconnect ClickUp" : "Connect ClickUp…", #selector(toggleClickUp)))
        if let status = clickUpStatus() {
            let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Reminders already scheduled with macOS still arrive after quitting.", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        menu.addItem(item("Quit Rallo", #selector(quit), key: "q"))
    }

    /// "Waiting for You" section above the rest of the menu, same rows and
    /// order as the panel's (0007/0008/0010): choosing one brings its
    /// terminal or ClickUp conversation forward, nothing here dismisses one.
    private func populateAgentsSection(_ menu: NSMenu) {
        let sessions = AgentSessionFormatting.sorted(agentSessions())
        guard !sessions.isEmpty else { return }
        let header = NSMenuItem(title: "Waiting for You", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for session in sessions {
            let row = NSMenuItem(title: Self.agentMenuLine(for: session), action: #selector(selectAgentSession(_:)), keyEquivalent: "")
            row.target = self
            row.isEnabled = session.isActionable
            row.representedObject = session
            menu.addItem(row)
        }
        menu.addItem(.separator())
    }

    private func notesMenuItem() -> NSMenuItem {
        let notes = item("Open Notes…", #selector(openNotes))
        notes.keyEquivalent = "n"
        notes.keyEquivalentModifierMask = Self.shortcutModifiers
        if !notesShortcutAvailable() { notes.title += " (shortcut in use)" }
        return notes
    }

    private func jumpMenuItem() -> NSMenuItem {
        let jump = item("Jump to Waiting Agent", #selector(jumpToWaitingAgent))
        jump.keyEquivalent = "j"
        jump.keyEquivalentModifierMask = Self.shortcutModifiers
        jump.isEnabled = !agentSessions().isEmpty
        if !jumpShortcutAvailable() { jump.title += " (shortcut in use)" }
        return jump
    }

    private func notifyLongWaitMenuItem() -> NSMenuItem {
        let toggle = item("Notify When an Agent Waits 5 Minutes", #selector(toggleNotifyLongWait))
        toggle.state = notifyLongWaitEnabled() ? .on : .off
        return toggle
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
    @objc private func jumpToWaitingAgent() { actions.jumpToWaitingAgent() }
    @objc private func selectAgentSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? AgentSessionSnapshot else { return }
        actions.selectAgentSession(session)
    }
    @objc private func enableNotifications() { actions.enableNotifications() }
    @objc private func toggleNotifyLongWait() { actions.toggleNotifyLongWait() }
    @objc private func toggleClickUp() { actions.toggleClickUp() }
    @objc private func exportBackup() { actions.exportBackup() }
    @objc private func exportSpreadsheet() { actions.exportSpreadsheet() }
    @objc private func importNotes() { actions.importNotes() }
    @objc private func terminalCommand() { actions.terminalCommand() }
    @objc private func toggleLoginItem() { actions.toggleLoginItem() }
    @objc private func quit() { actions.quit() }
}
