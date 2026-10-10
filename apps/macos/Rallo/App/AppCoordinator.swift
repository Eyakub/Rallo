import AppKit
import UserNotifications

/// Owns the app's long-lived parts and applies state read from the core.
@MainActor
final class AppCoordinator {
    let dataDir: String
    let notifications: NotificationCoordinator

    private let launchMode: LaunchOptions.Mode
    private let core: CoreClient
    private let log: DiagnosticsLog
    private let pet = PetController()
    private let notesModel: NotesViewModel
    private let notes: NotesPanelController
    private let notesWindowModel: NotesWindowModel
    private let notesWindow: NotesWindowController
    private let observer: ChangeObserver
    private let drainer: NotificationDrainer
    private let transfer: TransferController
    private let terminalSetup: TerminalSetupController
    private let petState: PetStateDriver
    private let agentWaitNotifier: AgentWaitNotifier
    let quietSignals = QuietSignals()
    let attention: AttentionCoordinator
    private let clickUp: ClickUpWatcher
    private let updateChecker: UpdateChecker
    private let settingsModel = SettingsModel()
    private lazy var settings = SettingsWindowController(model: settingsModel)
    private let globalShortcuts = GlobalShortcuts()
    private let voice: VoiceTyping
    private let voiceKey = VoiceKeyMonitor()
    private var animationsPaused = false
    private var statusMenu: StatusMenuController?
    private var systemObservers: [NSObjectProtocol] = []

    private var storageReady = false
    private var capturingScreenshot = false
    private var checking = false
    private var lastRevision: Int64?
    private var visibility: PetVisibility?
    private var placement: PetPlacement?
    private var notificationSummary = "Notifications: checking…"
    private var notificationsAuthorized = false
    private var agentSessions: [AgentSessionSnapshot] = []
    private var notifyLongWaitEnabled = false
    private var alertSettings = AlertSettings.initial
    private var agentJumpState = AgentJumpState()
    private var livenessTimer: Timer?
    private var sweepTimer: Timer?
    private var demoOpen: String?
    /// Started with a --data-dir other than the default (tests, demos). The
    /// CLI launches the real app with --data-dir set to the default folder,
    /// so passing the flag alone doesn't make an instance a scratch one.
    private let isScratch: Bool

    init(dataDir: String, launchMode: LaunchOptions.Mode, options: LaunchOptions) {
        self.dataDir = dataDir
        self.launchMode = launchMode
        isScratch = options.dataDir != nil && dataDir != (try? resolveDataDir(explicit: nil))
        // Screenshot mode only ever applies to a scratch instance.
        if isScratch {
            demoOpen = options.demoOpen
            switch options.demoAppearance {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }
        core = CoreClient(dataDir: dataDir)
        log = DiagnosticsLog(dataDir: dataDir)
        notifications = NotificationCoordinator(log: log)
        let fault = FaultInjection(argument: options.faultInjection, explicitDataDir: options.dataDir, log: log)
        drainer = NotificationDrainer(core: core, adapter: notifications.adapter, log: log, fault: fault)
        transfer = TransferController(core: core, log: log)
        terminalSetup = TerminalSetupController(log: log)
        petState = PetStateDriver(core: core, pet: pet, log: log)
        attention = AttentionCoordinator(core: core, pet: pet, quietSignals: quietSignals, log: log)
        clickUp = ClickUpWatcher(core: core, log: log)
        updateChecker = UpdateChecker(log: log)
        voice = VoiceTyping(log: log)
        updateChecker.allowed = !isScratch
        if isScratch {
            clickUp.disabledReason = "ClickUp is off in instances started with --data-dir."
        }
        // The wait-threshold testing override (0008) only ever applies to a
        // scratch instance started with an explicit --data-dir.
        agentWaitNotifier = AgentWaitNotifier(adapter: notifications.adapter, log: log, allowThresholdOverride: isScratch)
        // The panel's folder choice and the Notes window's frame (0019) live in
        // UserDefaults, which is per bundle id: any data dir but the real one
        // must not overwrite the real app's.
        // `.standard` for the real data dir, else the scratch suite (`PanelDefaults`).
        let defaults = PanelDefaults.defaults(forDataDir: dataDir)
        notesModel = NotesViewModel(core: core, defaults: defaults)
        notes = NotesPanelController(model: notesModel)
        notesWindowModel = NotesWindowModel(core: core)
        notesWindow = NotesWindowController(model: notesWindowModel, defaults: defaults)
        observer = ChangeObserver(dataDir: dataDir)
    }

    func start() async {
        log.record("app_launch", ["mode": "\(launchMode)", "bundle_path": Bundle.main.bundlePath])
        let menu = StatusMenuController(
            actions: .init(
                togglePet: { [weak self] in Task { await self?.togglePet() } },
                toggleAnimations: { [weak self] in Task { await self?.toggleAnimations() } },
                openNotes: { [weak self] in self?.openNotes(highlighting: nil) },
                openNotesWindow: { [weak self] in self?.openNotesWindow() },
                jumpToWaitingAgent: { [weak self] in self?.jumpToWaitingAgent() },
                selectAgentSession: { [weak self] session in self?.activateAgent(session) },
                openSettings: { [weak self] in self?.openSettings() },
                openUpdate: { [weak self] in self?.openUpdate() },
                quit: { NSApp.terminate(nil) }
            ),
            petVisible: { [weak self] in self?.pet.isVisible ?? false }
        )
        menu.animationsPaused = { [weak self] in self?.animationsPaused ?? false }
        menu.agentSessions = { [weak self] in self?.agentSessions ?? [] }
        menu.jumpShortcutAvailable = { [weak self] in self?.globalShortcuts.jumpRegistered ?? true }
        menu.notesShortcutAvailable = { [weak self] in self?.globalShortcuts.toggleNotesRegistered ?? true }
        menu.updateAvailable = { [weak self] in self?.updateChecker.available }
        menu.install()
        statusMenu = menu
        configureSettings()
        updateChecker.onChange = { [weak self] in
            self?.settingsModel.refresh()
            self?.statusMenu?.setUpdateBadge(self?.updateChecker.available)
        }
        menu.setUpdateBadge(updateChecker.available)
        updateChecker.start()
        notifications.onOpenUpdate = { [weak self] in self?.openUpdate() }

        pet.onClick = { [weak self] in
            guard let self else { return }
            if notes.isOpen { notes.close() } else { openNotes(highlighting: nil) }
        }
        transfer.onShowNotes = { [weak self] in self?.openNotes(highlighting: nil) }
        notesModel.onEnableNotifications = { [weak self] in Task { await self?.turnOnNotifications() } }
        notesModel.onExpand = { [weak self] in self?.expandNotesPanel() }
        notesWindow.onPresenceChange = { [weak self] open in self?.updateActivationPolicy(notesWindowOpen: open) }
        petState.onDueBoundary = { [weak self] in
            guard let self else { return }
            if notes.isOpen { Task { await self.notesModel.reload() } }
            if notesWindow.isOpen { Task { await self.notesWindowModel.reload() } }
        }
        petState.onRecompute = { [weak self] in self?.attention.dueMayHaveChanged() }
        quietSignals.isVoiceTypingListening = { [weak self] in self?.voice.isListening ?? false }
        attention.animationsPaused = { [weak self] in self?.animationsPaused ?? false }
        attention.openNotes = { [weak self] itemID in self?.openNotes(highlighting: itemID) }
        attention.activateAgent = { [weak self] session in self?.activateAgent(session) }
        drainer.alertSound = { [weak self] in self?.alertSettings.sound ?? .ralloChime }
        agentWaitNotifier.alertSound = { [weak self] in self?.alertSettings.sound ?? .ralloChime }
        agentWaitNotifier.onPost = { [weak self] session, identifier in self?.attention.agentPosted(session, identifier: identifier) }
        agentWaitNotifier.onWithdraw = { [weak self] identifiers in self?.attention.agentsWithdrawn(identifiers) }
        pet.onMoved = { [weak self] origin in Task { await self?.petMoved(to: origin) } }
        pet.contextMenu = { [weak self] in self?.statusMenu?.makeMenu() }
        notifications.onOpenItem = { [weak self] itemID in
            self?.attention.bannerOpened(itemID: itemID)
            self?.openNotes(highlighting: itemID)
        }
        notifications.onAction = { [weak self] reminderID, generation, action, itemID in
            Task { await self?.handleNotificationAction(reminderID, generation, action, itemID) }
        }
        notifications.onActivateAgent = { [weak self] agent, sessionId in
            self?.attention.bannerActivatedAgent(agent: agent, sessionId: sessionId)
            Task { await self?.activateAgentFromNotification(agent: agent, sessionId: sessionId) }
        }
        NotificationDrainer.registerCategories(on: UNUserNotificationCenter.current())
        agentWaitNotifier.isEnabled = { [weak self] in self?.notifyLongWaitEnabled ?? false }
        agentWaitNotifier.isAuthorized = { [weak self] in self?.notificationsAuthorized ?? false }
        globalShortcuts.onJump = { [weak self] in self?.jumpToWaitingAgent() }
        globalShortcuts.onToggleNotes = { [weak self] in
            guard let self else { return }
            if notes.isOpen { notes.close() } else { openNotes(highlighting: nil) }
        }
        globalShortcuts.onVoice = { [weak self] in self?.voice.toggle() }
        globalShortcuts.onScreenshot = { [weak self] in Task { await self?.takeScreenshot() } }
        voiceKey.isListening = { [weak self] in self?.voice.isListening ?? false }
        voiceKey.onAction = { [weak self] in
            switch $0 {
            case .startHold, .startHandsFree: self?.voice.start()
            case .endHold: self?.voice.stop(reason: .release)
            case .stop: self?.voice.stop(reason: .shortcut)
            }
        }
        voice.onListening = { [weak self] in self?.pet.setListening($0) }
        voice.onTyped = { [weak self] in self?.pet.heard() }
        voice.petFrame = { [weak self] in
            guard let self, pet.isVisible else { return nil }
            return pet.frame
        }
        globalShortcuts.register()
        globalShortcuts.setVoice(enabled: Self.voiceTypingEnabled)
        voiceKey.setEnabled(Self.voiceTypingEnabled)
        globalShortcuts.setScreenshot(enabled: Self.screenshotHotkeyEnabled)
        observer.onPossibleChange = { [weak self] in Task { await self?.checkForChanges() } }
        observer.onShowRequest = { [weak self] in Task { await self?.handleShowRequest() } }
        observer.onDiagnosticsRequest = { [weak self] in self?.writeWindowReport() }

        CaptureService.shared.showErrors { [weak self] message in self?.showCaptureError(message) }
        do {
            try await core.open()
            storageReady = true
            excludeRuntimeFromBackups()
            startImageSweep()
            clickUp.onChange = { [weak self] in Task { await self?.checkForChanges() } }
            clickUp.start()
        } catch {
            log.record("storage_open_failed", ["error": "\(error)"])
            notificationSummary = "Storage unavailable — run `rallo doctor`"
            CaptureService.shared.unavailable("Rallo can't open its storage. Run rallo doctor in Terminal.")
            return
        }
        observer.start()
        await applyLaunchVisibility()
        CaptureService.shared.attach(core: core)
        await refreshNotificationSummary()
        observeSystemEvents()
        // 0021 §9: asked until answered, on every launch mode (user, 2026-10-10).
        quietSignals.requestFocusAuthorization()
        drainer.requestDrain("launch")
        openForDemo()
    }

    /// `--demo-open` (scripts/screenshots.sh): opens the view to capture
    /// once launch has settled.
    private func openForDemo() {
        guard let demoOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            switch demoOpen.split(separator: ":").first {
            case "notes": openNotes(highlighting: nil)
            case "window": openNotesWindow()
            case "menu": statusMenu?.openMenu()
            case "listening":
                // The voice-typing pose (0013): 8 s listening with a nod every
                // 2.5 s, 4 s back at rest, repeating.
                let start = Date()
                pet.setListening(true)
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        let phase = Int(Date().timeIntervalSince(start) * 2) % 24
                        self?.pet.setListening(phase < 16)
                        if phase < 16, phase % 5 == 0 { self?.pet.heard() }
                    }
                }
            case "settings":
                if let tab = demoOpen.split(separator: ":").dropFirst().first { settingsModel.tab = String(tab) }
                openSettings()
            default: break
            }
        }
    }

    /// Unregisters the global shortcuts; called once, at quit.
    func stop() {
        globalShortcuts.unregister()
    }

    /// Sleep and clock changes can elapse deadlines or strand attempts.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainer.requestDrain("did_wake") }
        })
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainer.requestDrain("clock_changed") }
        })
        // Coming back from System Settings: pick up a permission change now
        // rather than at the next heartbeat.
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainer.requestDrain("did_become_active") }
        })
    }

    enum ReopenSource {
        case application(bundleID: String)
        case unknown(pid: pid_t?)
    }

    func handleReopen(source: ReopenSource) {
        switch source {
        case let .application(bundleID):
            log.record("app_reopen", ["sender": bundleID])
            if notesWindow.isOpen {
                openNotesWindow()  // the Dock icon: bring the window back, minimised or not
            } else {
                openNotes(highlighting: nil)
            }
        case let .unknown(pid):
            // Most likely a CLI launch that raced startup: never let it open
            // panels or override a deliberate hide.
            log.record("app_reopen_ignored", ["sender_pid": pid.map { Int($0) } ?? NSNull()])
        }
    }

    // MARK: Visibility

    private func applyLaunchVisibility() async {
        do {
            let saved = try await core.petVisibility()
            switch launchMode {
            case .show:
                try await core.setPetVisibility(.visible)
            case .background:
                // Never onboards or activates; passive restoration only.
                break
            case .interactive where saved == nil:
                // First interactive launch introduces the pet.
                try await core.setPetVisibility(.visible)
                try await core.setOnboardingCompleted()
            case .interactive:
                break
            }
            try await reloadFromCore()
        } catch {
            log.record("launch_visibility_failed", ["error": "\(error)"])
        }
    }

    private func reloadFromCore() async throws {
        let previousRevision = lastRevision
        lastRevision = try await core.changeRevision()
        if previousRevision != nil, previousRevision != lastRevision {
            drainer.requestDrain("revision")
        }
        let newVisibility = try await core.petVisibility()
        let newPlacement = try await core.petPlacement()
        let placementChanged = newPlacement != placement
        visibility = newVisibility
        placement = newPlacement
        let origin = placement.map { NSPoint(x: $0.x, y: $0.y) }
        if visibility == .visible {
            if !pet.isVisible {
                pet.show(savedOrigin: origin)
            } else if placementChanged {
                pet.move(savedOrigin: origin)
            }
        } else if pet.isVisible {
            pet.hide()
        }
        if notes.isOpen {
            await notesModel.reload()
        }
        if notesWindow.isOpen {
            await notesWindowModel.reload()
        }
        animationsPaused = (try? await core.petAnimationsPaused()) ?? false
        agentSessions = (try? await core.agentSessions()) ?? []
        armLivenessTimer()
        notifyLongWaitEnabled = (try? await core.agentsNotifyLongWait()) ?? false
        statusMenu?.refreshAgents(agentSessions)
        alertSettings = (try? await core.alertSettings()) ?? alertSettings
        attention.settingsChanged(alertSettings)
        if let reminderPrefix = try? await core.notificationIdentifierPrefix() {
            // ClickUp sends its own banners (0010); the long wait is for agents.
            agentWaitNotifier.reload(sessions: agentSessions.filter { !$0.isClickUp }, reminderPrefix: reminderPrefix)
        }
        petState.refresh()
        settingsModel.refresh()
    }

    private func checkForChanges() async {
        guard storageReady, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let revision = try await core.changeRevision()
            guard revision != lastRevision else { return }
            try await reloadFromCore()
        } catch {
            log.record("change_check_failed", ["error": "\(error)"])
        }
    }

    private func handleShowRequest() async {
        log.record("show_request")
        await checkForChanges()
        if visibility == .visible && !pet.isVisible {
            pet.show(savedOrigin: placement.map { NSPoint(x: $0.x, y: $0.y) })
        }
    }

    private func togglePet() async {
        do {
            try await core.setPetVisibility(pet.isVisible ? .hidden : .visible)
            try await reloadFromCore()
        } catch {
            log.record("toggle_pet_failed", ["error": "\(error)"])
        }
    }

    private func toggleAnimations() async {
        do {
            try await core.setPetAnimationsPaused(!animationsPaused)
            try await reloadFromCore()
        } catch {
            log.record("toggle_animations_failed", ["error": "\(error)"])
        }
    }

    private func petMoved(to origin: NSPoint) async {
        let clamped = PetPlacementPolicy.resolve(saved: origin, size: PetPanel.spriteSize)
        if clamped != origin { pet.move(savedOrigin: clamped) }
        do {
            try await core.setPetPlacement(PetPlacement(x: clamped.x, y: clamped.y))
            try await reloadFromCore()
        } catch {
            log.record("save_placement_failed", ["error": "\(error)"])
        }
    }

    // MARK: Agent attention reach (0008, 0009)

    /// 0018: images of notes deleted 30+ days ago, and files no note owns,
    /// are removed at launch and once a day.
    private func startImageSweep() {
        sweepImages()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepImages() }
        }
    }

    private func sweepImages() {
        Task {
            do {
                let result = try await core.sweepImages()
                if result.expiredImages + result.orphanFiles > 0 {
                    log.record("images_swept", ["expired": result.expiredImages, "orphans": result.orphanFiles])
                }
            } catch {
                log.record("image_sweep_failed", ["error": "\(error)"])
            }
        }
    }

    /// While an agent waits, looks every 30 s for one whose process has gone
    /// (a terminal closed without a clean exit): reading sessions prunes it,
    /// and the revision bump reloads every view.
    private func armLivenessTimer() {
        if agentSessions.isEmpty {
            livenessTimer?.invalidate()
            livenessTimer = nil
        } else if livenessTimer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task {
                        _ = try? await self.core.agentSessions()
                        await self.checkForChanges()
                    }
                }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            livenessTimer = timer
        }
    }

    // MARK: Settings

    /// ⌘, and the menu's "Settings…" (also the hidden app menu's).
    func openSettings() {
        settings.show()
    }

    // MARK: Notes window (0019)

    /// The status menu's and the Window menu's "Notes Window", the Dock icon.
    func openNotesWindow() {
        notesWindow.show()
    }

    /// The panel's expand button: the panel closes and the window opens on the
    /// panel's scope, with the panel's expanded note selected.
    private func expandNotesPanel() {
        let selection = NotesWindowSelection.scope(notesModel.scope)
        let noteID = notesModel.expandedID
        notes.close()
        notesWindow.show(selection: selection, noteID: noteID)
        log.record("notes_window_opened", ["from": "panel"])
    }

    /// Rallo is a Dock app only while the Notes window is open (0019 §11);
    /// Settings and the panel never change the policy.
    private func updateActivationPolicy(notesWindowOpen: Bool) {
        let wanted: NSApplication.ActivationPolicy = notesWindowOpen ? .regular : .accessory
        guard wanted != NSApp.activationPolicy() else { return }
        NSApp.setActivationPolicy(wanted)
        log.record("activation_policy", ["policy": wanted == .regular ? "regular" : "accessory"])
        // Dropping to .accessory can leave Settings or the panel showing in an inactive app.
        if wanted == .accessory, settings.isOpen || notes.isOpen {
            NSApp.activate()
            if settings.isOpen { settings.bringForward() } else { notes.window?.makeKeyAndOrderFront(nil) }
        }
    }

    /// ⌘N, ⇧⌘N and ⌘F act only while the window is key and its New Folder card is not up.
    var notesWindowAcceptsCommands: Bool { notesWindow.isKey && notesWindowModel.namePrompter.request == nil }
    var notesWindowCanCreateNote: Bool { notesWindowAcceptsCommands && notesWindowModel.canCreateNote }
    var notesWindowHasUnsavedText: Bool {
        notesWindow.nsWindow?.makeFirstResponder(nil)  // a pending composition commits, so it counts
        return notesWindowModel.editor.hasUnsavedText
    }
    func newNoteInNotesWindow() { Task { await notesWindowModel.beginNewNote() } }
    func newFolderInNotesWindow() { Task { await notesWindowModel.newFolderInline() } }
    func focusNotesWindowSearch() { notesWindow.focusSearch() }

    /// ⌘Q: end any input-method composition first, so the committed text is what saves.
    func flushNotesWindow() async {
        notesWindow.nsWindow?.makeFirstResponder(nil)
        await notesWindowModel.editor.flush()
    }

    /// The menu item and the update notification: Settings → About, where
    /// "Update Now" and its confirmation do the install.
    private func openUpdate() {
        settingsModel.tab = "about"
        openSettings()
        settingsModel.checkForUpdates()
    }

    private func configureSettings() {
        let model = settingsModel
        model.dataPath = dataDir
        // A --data-dir instance must never offer it: the CLI would uninstall the real app.
        model.uninstallAvailable = !isScratch
            && TerminalCommand.isInstalled(Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
        model.refreshSnapshot = { [weak self] in
            guard let self else { return }
            model.loginState = LoginItem.state
            model.petVisible = pet.isVisible
            model.terminalEnabled = terminalSetup.isEnabled
            model.notificationSummary = notificationSummary
            model.notificationsAuthorized = notificationsAuthorized
            model.notifyLongWait = notifyLongWaitEnabled
            model.alertSettings = alertSettings
            model.clickUpConnected = clickUp.isConnected
            model.clickUpStatus = clickUp.status
            model.updateCheckEnabled = updateChecker.isEnabled
            model.updateCheckAllowed = updateChecker.allowed
            model.voiceTypingEnabled = Self.voiceTypingEnabled
            model.voiceAccessibilityMissing = !VoicePermissions.accessibilityAllowed(prompt: false)
            model.voiceShortcutTaken = Self.voiceTypingEnabled && !globalShortcuts.voiceRegistered
            model.screenshotHotkeyEnabled = Self.screenshotHotkeyEnabled
            model.screenshotShortcutTaken = Self.screenshotHotkeyEnabled && !globalShortcuts.screenshotRegistered
        }
        model.toggleLoginItem = { [weak self] in
            guard let self else { return }
            LoginItem.toggle(log: log)
        }
        model.togglePet = { [weak self] in await self?.togglePet() }
        model.openTerminalSetup = { [weak self] in self?.terminalSetup.open() }
        model.enableNotifications = { [weak self] in await self?.enableNotifications() }
        model.toggleNotifyLongWait = { [weak self] in await self?.toggleNotifyLongWait() }
        // Connect checks the token with ClickUp before keeping it in the
        // Keychain; Disconnect forgets it and clears its rows (0010).
        model.connectClickUp = { [weak self] token in
            guard let self else { return "" }
            return try await clickUp.connect(token: token)
        }
        model.disconnectClickUp = { [weak self] in await self?.clickUp.disconnect() }
        model.exportArchive = { [weak self] in self?.transfer.export(.zip) }
        model.exportBackup = { [weak self] in self?.transfer.export(.json) }
        model.exportSpreadsheet = { [weak self] in self?.transfer.export(.csv) }
        model.importNotes = { [weak self] in self?.transfer.importFile() }
        model.setVoiceTyping = { [weak self] enabled in
            guard let self else { return }
            UserDefaults.standard.set(enabled, forKey: "voiceTypingEnabled")
            globalShortcuts.setVoice(enabled: enabled)
            voiceKey.setEnabled(enabled)
            if enabled {
                Task {
                    _ = await VoicePermissions.requestMicrophone()
                    _ = VoicePermissions.accessibilityAllowed(prompt: true)
                    self.settingsModel.refresh()
                }
            } else {
                voice.stop(reason: .shortcut)
            }
            settingsModel.refresh()
        }
        model.setScreenshotHotkey = { [weak self] enabled in
            guard let self else { return }
            UserDefaults.standard.set(enabled, forKey: "screenshotHotkeyEnabled")
            globalShortcuts.setScreenshot(enabled: enabled)
            settingsModel.refresh()
        }
        model.setUpdateCheck = { [weak self] enabled in
            self?.updateChecker.setEnabled(enabled)
            self?.settingsModel.refresh()
        }
        model.setAlertSettings = { [weak self] settings in
            guard let self else { return }
            self.settingsModel.alertSettings = settings  // the control moves at once
            Task {
                do {
                    try await self.core.setAlertSettings(settings)
                    // The revision bump drains: a new chime re-registers pending banners (0021 §6).
                    try await self.reloadFromCore()
                } catch {
                    self.log.record("alert_settings_failed", ["error": "\(error)"])
                    self.settingsModel.refresh()
                }
            }
        }
        model.openNotificationSettings = { NSWorkspace.shared.open(Self.notificationSettingsURL) }
    }

    /// System Settings › Notifications › Rallo. Spike S5 checks it opens Rallo's own page (Task 11e).
    static var notificationSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.razlio.rallo")")!
    }

    private static var voiceTypingEnabled: Bool { UserDefaults.standard.bool(forKey: "voiceTypingEnabled") }
    private static var screenshotHotkeyEnabled: Bool { UserDefaults.standard.bool(forKey: "screenshotHotkeyEnabled") }

    /// Agent sessions are runtime state (0009): keep them out of Time
    /// Machine. The core creates the folder when it opens the store.
    private func excludeRuntimeFromBackups() {
        var url = URL(fileURLWithPath: dataDir).appendingPathComponent("runtime", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            log.record("runtime_backup_exclusion_failed", ["error": "\(error)"])
        }
    }

    /// Brings a session's terminal forward from the menu's "Agents" section;
    /// a no-op if Rallo couldn't identify one (the row is disabled instead).
    private func activateAgent(_ session: AgentSessionSnapshot) {
        AgentSessionActivation.activate(session)
        // Opening a ClickUp conversation counts as reading it (0010).
        guard session.isClickUp else { return }
        Task {
            do {
                try await core.dismissAgentSession(session)
                await checkForChanges()
            } catch {
                log.record("clickup_dismiss_failed", ["error": "\(error)"])
            }
        }
    }

    /// ⌃⌥⌘J and the menu's "Jump to Waiting Agent": longest-waiting first,
    /// then most-recently-finished; a press within 5 s advances the cycle.
    private func jumpToWaitingAgent() {
        let (session, state) = AgentJumpPlanner.next(sessions: agentSessions, previous: agentJumpState)
        agentJumpState = state
        guard let session else { return }
        activateAgent(session)
    }

    /// A clicked long-wait notification: the session may have finished or
    /// been dismissed since it was posted, in which case this is a no-op.
    private func activateAgentFromNotification(agent: String, sessionId: String) async {
        do {
            let sessions = try await core.agentSessions()
            guard let session = sessions.first(where: { $0.agent == agent && $0.sessionId == sessionId }) else { return }
            activateAgent(session)
        } catch {
            log.record("agent_notification_activate_failed", ["error": "\(error)"])
        }
    }

    private func toggleNotifyLongWait() async {
        do {
            try await core.setAgentsNotifyLongWait(!notifyLongWaitEnabled)
            try await reloadFromCore()
        } catch {
            log.record("toggle_notify_long_wait_failed", ["error": "\(error)"])
        }
    }

    // MARK: Notes and notifications

    /// A Services save that failed (0017): the panel opens and says why.
    /// `captureError` survives reloads; the next fresh open clears it.
    private func showCaptureError(_ message: String) {
        openNotes(highlighting: nil)
        notesModel.captureError = message
    }

    /// ⌃⌥⌘S (0018): the capture opens in the note field with the cursor in
    /// the text; Return saves, Escape discards. The panel steps aside while
    /// the user selects.
    private func takeScreenshot() async {
        guard storageReady, !capturingScreenshot else { return }
        capturingScreenshot = true
        defer { capturingScreenshot = false }
        notes.close()
        let outcome = await ScreenshotCapture.capture()
        log.record("screenshot", ["outcome": outcome.name])
        switch outcome {
        case let .captured(capture):
            let data = ImageClipboard.storable(capture) ?? capture
            do {
                try ImageClipboard.check([data], staged: notesModel.stagedImages.count)
                openNotes(highlighting: nil)
                notesModel.stage([data])
            } catch {
                showCaptureError((error as? ImageRefusal)?.message ?? error.localizedDescription)
            }
        case .needsPermission:
            showCaptureError(ScreenshotCapture.permissionMessage)
        case .cancelled:
            break
        }
    }

    private func openNotes(highlighting itemID: String?) {
        Task { await notesModel.reveal(itemID) }
        notes.open(near: pet.isVisible ? pet.frame : nil)
        log.record("notes_opened", ["item_id": itemID ?? NSNull()])
    }

    private func enableNotifications() async {
        NSApp.activate()
        _ = await notifications.requestAuthorization()
        await refreshNotificationSummary()
        drainer.requestDrain("authorization")
    }

    /// Never asked: the system prompt. Denied: macOS won't ask again, so
    /// open Rallo's page in System Settings.
    private func turnOnNotifications() async {
        let settings = await notifications.adapter.settings()
        if settings.authorizationStatus == .notDetermined {
            await enableNotifications()
        } else {
            NSWorkspace.shared.open(Self.notificationSettingsURL)
        }
    }

    /// The core applies the action only if the notification still matches
    /// the reminder's current generation; otherwise the note is shown as it
    /// is now, with an explanation.
    private func handleNotificationAction(
        _ reminderID: String, _ generation: Int64, _ action: NotificationAction, _ itemID: String?
    ) async {
        do {
            switch try await core.applyNotificationAction(reminderId: reminderID, generation: generation, action: action) {
            case let .applied(item):
                log.record("notification_action_applied", ["item_id": item.id, "action": "\(action)"])
            case let .stale(item, reason):
                log.record("notification_action_stale", ["item_id": item?.id ?? NSNull(), "reason": "\(reason)"])
                openNotes(highlighting: item?.id ?? itemID)
                notesModel.inform(Self.staleMessage(reason))
            }
        } catch {
            log.record("notification_action_failed", ["error": "\(error)"])
            openNotes(highlighting: itemID)
        }
        drainer.requestDrain("notification_action")
    }

    private static func staleMessage(_ reason: StaleReason) -> String {
        switch reason {
        case .changed: "This reminder changed since that notification."
        case .deleted: "That note was deleted."
        case .missing: "That reminder no longer exists."
        }
    }

    private func refreshNotificationSummary() async {
        let settings = await notifications.adapter.settings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationSummary = "Notifications: allowed"
            notificationsAuthorized = true
        case .denied:
            notificationSummary = "Notifications: off in System Settings"
            notificationsAuthorized = false
        case .notDetermined:
            notificationSummary = "Notifications: not set up yet"
            notificationsAuthorized = false
        @unknown default:
            notificationSummary = "Notifications: unknown"
            notificationsAuthorized = false
        }
    }

    private func writeWindowReport() {
        let report = WindowReport.make(pet: pet, notesWindow: notes.window, notesAppWindow: notesWindow.nsWindow)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            log.write("windows.json", data: data)
        }
        if let png = pet.snapshotPNG() {
            log.write("pet-snapshot.png", data: png)
        }
    }
}
