import AppKit
import notify
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let options: LaunchOptions
    private var instanceLock: InstanceLock?
    private var coordinator: AppCoordinator?
    /// Kept here: `NSApp.servicesProvider` doesn't retain it.
    private let servicesProvider = ServicesProvider()
    private var terminationSource: DispatchSourceSignal?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let dataDir: String
        do {
            dataDir = try resolveDataDir(explicit: options.dataDir)
        } catch {
            NSLog("Rallo: cannot resolve data directory: %@", "\(error)")
            exit(EXIT_FAILURE)
        }
        guard let lock = Self.acquireInstanceLock(dataDir: dataDir) else {
            // Another instance owns this data directory: forward an explicit
            // show request (never for background launches) and exit.
            if options.mode != .background {
                notify_post(showSignalName(dataDir: dataDir))
            }
            exit(EXIT_SUCCESS)
        }
        instanceLock = lock
        let coordinator = AppCoordinator(dataDir: dataDir, launchMode: options.mode, options: options)
        self.coordinator = coordinator
        // Must be set before launch completes to receive the response that
        // launched the app from a notification click.
        UNUserNotificationCenter.current().delegate = coordinator.notifications
        installTerminationHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        // Set at launch so a Services request that started the app is delivered (0017).
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        Task { @MainActor in await coordinator?.start() }
    }

    /// A menu-bar app shows no menu bar, and without a main menu nothing
    /// routes ⌘X/⌘C/⌘V/⌘A/⌘Z to text fields (the composer, the ClickUp
    /// token field in Settings). It is visible only while the Notes window is open
    /// (Rallo is then a Dock app, 0019); otherwise it carries the standard Edit key
    /// equivalents and the Notes window's File and Window items.
    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: "Find", action: #selector(find), keyEquivalent: "f")
        findItem.target = self
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let app = NSMenu(title: "Rallo")
        let settings = app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Rallo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "Rallo", action: nil, keyEquivalent: "")  // the app menu's slot
        appItem.submenu = app
        let file = NSMenu(title: "File")
        let noteItem = file.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "n")
        noteItem.target = self
        let folderItem = file.addItem(withTitle: "New Folder", action: #selector(newFolder), keyEquivalent: "N")
        folderItem.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let notesWindowItem = windowMenu.addItem(withTitle: "Notes Window", action: #selector(openNotesWindow), keyEquivalent: "")
        notesWindowItem.target = self
        // No NSApp.windowsMenu: AppKit would list window titles and the Settings tab title, and drop
        // "Notes Window" while the window is closed (0019 §11 pins this menu's items).
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(fileItem)
        main.addItem(editItem)
        main.addItem(windowItem)
        return main
    }

    @objc private func openSettings() { coordinator?.openSettings() }
    @objc private func newNote() { coordinator?.newNoteInNotesWindow() }
    @objc private func newFolder() { coordinator?.newFolderInNotesWindow() }
    @objc private func openNotesWindow() { coordinator?.openNotesWindow() }
    @objc private func find() { coordinator?.focusNotesWindowSearch() }

    /// ⌘N, ⇧⌘N and ⌘F belong to the Notes window: they are dimmed (and do
    /// nothing) anywhere else, so they never fire from the panel or Settings,
    /// nor behind the window's New Folder card.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newNote) { return coordinator?.notesWindowCanCreateNote ?? false }
        if menuItem.action == #selector(newFolder) || menuItem.action == #selector(find) {
            return coordinator?.notesWindowAcceptsCommands ?? false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let source = Self.reopenSource()
        Task { @MainActor in coordinator?.handleReopen(source: source) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting saves what's being typed in the Notes window first (0019 §11).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.notesWindowHasUnsavedText else { return .terminateNow }
        Task { @MainActor in
            await coordinator.flushNotesWindow()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    /// Who sent the reopen event. The CLI's `open -g` requests can queue up
    /// while the app is starting and arrive as reopen events after `open` has
    /// exited, so only a sender that resolves to a running GUI application
    /// (Finder, Dock, Spotlight, …) counts as a user asking to see Rallo.
    private static func reopenSource() -> AppCoordinator.ReopenSource {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else { return .unknown(pid: nil) }
        let pid = pid_t(descriptor.int32Value)
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier {
            return .application(bundleID: bundleID)
        }
        return .unknown(pid: pid)
    }

    /// The CLI probes the lock for an instant, so retry briefly before
    /// concluding that a real instance holds it.
    private static func acquireInstanceLock(dataDir: String) -> InstanceLock? {
        for attempt in 0..<20 {
            if let lock = try? tryAcquireInstanceLock(dataDir: dataDir) {
                return lock
            }
            if attempt < 19 { usleep(50_000) }
        }
        return nil
    }

    /// Treat SIGTERM (e.g. from the dev install script) as an ordinary quit.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }
}
