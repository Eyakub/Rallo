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
    private let observer: ChangeObserver
    private let drainer: NotificationDrainer
    private let transfer: TransferController
    private let terminalSetup: TerminalSetupController
    private let petState: PetStateDriver
    private var animationsPaused = false
    private var statusMenu: StatusMenuController?
    private var systemObservers: [NSObjectProtocol] = []

    private var storageReady = false
    private var checking = false
    private var lastRevision: Int64?
    private var visibility: PetVisibility?
    private var placement: PetPlacement?
    private var notificationSummary = "Notifications: checking…"

    init(dataDir: String, launchMode: LaunchOptions.Mode, options: LaunchOptions) {
        self.dataDir = dataDir
        self.launchMode = launchMode
        core = CoreClient(dataDir: dataDir)
        log = DiagnosticsLog(dataDir: dataDir)
        notifications = NotificationCoordinator(log: log)
        let fault = FaultInjection(argument: options.faultInjection, explicitDataDir: options.dataDir, log: log)
        drainer = NotificationDrainer(core: core, adapter: notifications.adapter, log: log, fault: fault)
        transfer = TransferController(core: core, log: log)
        terminalSetup = TerminalSetupController(log: log)
        petState = PetStateDriver(core: core, pet: pet, log: log)
        notesModel = NotesViewModel(core: core)
        notes = NotesPanelController(model: notesModel)
        observer = ChangeObserver(dataDir: dataDir)
    }

    func start() async {
        log.record("app_launch", ["mode": "\(launchMode)", "bundle_path": Bundle.main.bundlePath])
        let menu = StatusMenuController(
            actions: .init(
                togglePet: { [weak self] in Task { await self?.togglePet() } },
                toggleAnimations: { [weak self] in Task { await self?.toggleAnimations() } },
                openNotes: { [weak self] in self?.openNotes(highlighting: nil) },
                enableNotifications: { [weak self] in Task { await self?.enableNotifications() } },
                exportBackup: { [weak self] in self?.transfer.export(.json) },
                exportSpreadsheet: { [weak self] in self?.transfer.export(.csv) },
                importNotes: { [weak self] in self?.transfer.importFile() },
                terminalCommand: { [weak self] in self?.terminalSetup.open() },
                quit: { NSApp.terminate(nil) }
            ),
            petVisible: { [weak self] in self?.pet.isVisible ?? false },
            notificationSummary: { [weak self] in self?.notificationSummary ?? "" },
            terminalCommandTitle: { [weak self] in self?.terminalSetup.menuTitle ?? "Enable Terminal Command…" }
        )
        menu.animationsPaused = { [weak self] in self?.animationsPaused ?? false }
        menu.install()
        statusMenu = menu

        pet.onClick = { [weak self] in self?.openNotes(highlighting: nil) }
        transfer.onShowNotes = { [weak self] in self?.openNotes(highlighting: nil) }
        notesModel.onEnableNotifications = { [weak self] in Task { await self?.turnOnNotifications() } }
        petState.onDueBoundary = { [weak self] in
            guard let self, self.notes.isOpen else { return }
            Task { await self.notesModel.reload() }
        }
        pet.onMoved = { [weak self] origin in Task { await self?.petMoved(to: origin) } }
        pet.contextMenu = { [weak self] in self?.statusMenu?.makeMenu() }
        notifications.onOpenItem = { [weak self] itemID in self?.openNotes(highlighting: itemID) }
        notifications.onAction = { [weak self] reminderID, generation, action, itemID in
            Task { await self?.handleNotificationAction(reminderID, generation, action, itemID) }
        }
        NotificationDrainer.registerCategories(on: UNUserNotificationCenter.current())
        observer.onPossibleChange = { [weak self] in Task { await self?.checkForChanges() } }
        observer.onShowRequest = { [weak self] in Task { await self?.handleShowRequest() } }
        observer.onDiagnosticsRequest = { [weak self] in self?.writeWindowReport() }

        do {
            try await core.open()
            storageReady = true
        } catch {
            log.record("storage_open_failed", ["error": "\(error)"])
            notificationSummary = "Storage unavailable — run `rallo doctor`"
            return
        }
        observer.start()
        await applyLaunchVisibility()
        await refreshNotificationSummary()
        observeSystemEvents()
        drainer.requestDrain("launch")
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
            openNotes(highlighting: nil)
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
        animationsPaused = (try? await core.petAnimationsPaused()) ?? false
        petState.refresh()
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

    // MARK: Notes and notifications

    private func openNotes(highlighting itemID: String?) {
        notesModel.highlight(itemID, for: 4)
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
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.razlio.rallo")") {
            NSWorkspace.shared.open(url)
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
        case .denied:
            notificationSummary = "Notifications: off in System Settings"
        case .notDetermined:
            notificationSummary = "Notifications: not set up yet"
        @unknown default:
            notificationSummary = "Notifications: unknown"
        }
    }

    private func writeWindowReport() {
        let report = WindowReport.make(pet: pet, notesWindow: notes.window)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            log.write("windows.json", data: data)
        }
        if let png = pet.snapshotPNG() {
            log.write("pet-snapshot.png", data: png)
        }
    }
}
