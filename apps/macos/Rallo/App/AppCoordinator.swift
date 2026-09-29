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
    private var statusMenu: StatusMenuController?

    private var storageReady = false
    private var checking = false
    private var lastRevision: Int64?
    private var visibility: PetVisibility?
    private var placement: PetPlacement?
    private var notificationSummary = "Notifications: checking…"

    init(dataDir: String, launchMode: LaunchOptions.Mode) {
        self.dataDir = dataDir
        self.launchMode = launchMode
        core = CoreClient(dataDir: dataDir)
        log = DiagnosticsLog(dataDir: dataDir)
        notifications = NotificationCoordinator(log: log)
        notesModel = NotesViewModel(core: core)
        notes = NotesPanelController(model: notesModel)
        observer = ChangeObserver(dataDir: dataDir)
    }

    func start() async {
        log.record("app_launch", ["mode": "\(launchMode)", "bundle_path": Bundle.main.bundlePath])
        let menu = StatusMenuController(
            actions: .init(
                togglePet: { [weak self] in Task { await self?.togglePet() } },
                openNotes: { [weak self] in self?.openNotes(highlighting: nil) },
                enableNotifications: { [weak self] in Task { await self?.enableNotifications() } },
                quit: { NSApp.terminate(nil) }
            ),
            petVisible: { [weak self] in self?.pet.isVisible ?? false },
            notificationSummary: { [weak self] in self?.notificationSummary ?? "" }
        )
        menu.install()
        statusMenu = menu

        pet.onClick = { [weak self] in self?.openNotes(highlighting: nil) }
        pet.onMoved = { [weak self] origin in Task { await self?.petMoved(to: origin) } }
        pet.contextMenu = { [weak self] in self?.statusMenu?.makeMenu() }
        notifications.onOpenItem = { [weak self] itemID in self?.openNotes(highlighting: itemID) }
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
        lastRevision = try await core.changeRevision()
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
        notesModel.highlightedItemID = itemID
        notes.open(near: pet.isVisible ? pet.frame : nil)
        log.record("notes_opened", ["item_id": itemID ?? NSNull()])
    }

    private func enableNotifications() async {
        NSApp.activate()
        _ = await notifications.requestAuthorization()
        await refreshNotificationSummary()
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
