import AppKit

/// What the Settings window shows and does. The coordinator fills the
/// snapshot fields and the action closures (as `StatusMenuController` gets
/// its closures); the model refreshes whenever the window opens and after
/// each action.
@MainActor
final class SettingsModel: ObservableObject {
    enum AgentsStatus: Equatable {
        case checking
        case known(hooks: CLIReports.Check?, skill: CLIReports.Check?)
    }

    // Snapshot from the coordinator.
    @Published var loginState: LoginItem.State = .unavailable
    @Published var petVisible = false
    @Published var terminalEnabled = false
    @Published var notificationSummary = ""
    @Published var notificationsAuthorized = false
    @Published var notifyLongWait = false
    @Published var clickUpConnected = false
    @Published var clickUpStatus: String?
    @Published var updateCheckEnabled = false
    @Published var updateCheckAllowed = true
    @Published var voiceTypingEnabled = false
    @Published var voiceTypingAvailable = false
    @Published var voicePermissions = ""
    @Published var voiceAccessibilityMissing = false
    var dataPath = ""

    // Own state.
    /// The selected tab's tag: general, notifications, agents, clickup, data, about.
    @Published var tab = "general"
    @Published var token = ""
    @Published var clickUpBusy = false
    @Published var clickUpMessage: String?
    @Published var agents = AgentsStatus.checking
    @Published var agentsBusy = false
    @Published var agentsMessage: String?
    @Published var update: CLIReports.UpdateOutcome?
    @Published var updateBusy = false
    /// Set by the coordinator: only the installed app, never a `--data-dir` instance.
    @Published var uninstallAvailable = false
    @Published var uninstalling = false
    @Published var uninstallMessage: String?

    // Actions, wired by the coordinator.
    var refreshSnapshot: () -> Void = {}
    var toggleLoginItem: () -> Void = {}
    var togglePet: () async -> Void = {}
    var openTerminalSetup: () -> Void = {}
    var enableNotifications: () async -> Void = {}
    var toggleNotifyLongWait: () async -> Void = {}
    var connectClickUp: (String) async throws -> String = { _ in "" }
    var disconnectClickUp: () async -> Void = {}
    var exportBackup: () -> Void = {}
    var exportSpreadsheet: () -> Void = {}
    var importNotes: () -> Void = {}
    var setUpdateCheck: (Bool) -> Void = { _ in }
    var setVoiceTyping: (Bool) -> Void = { _ in }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    var dataPathDisplay: String { (dataPath as NSString).abbreviatingWithTildeInPath }

    /// Called when the window opens.
    func opened() {
        refresh()
        clickUpMessage = nil
        Task { await loadAgents() }
    }

    func refresh() { refreshSnapshot() }

    /// Runs an action, then re-reads the snapshot.
    func perform(_ action: @escaping () async -> Void) {
        Task {
            await action()
            refresh()
        }
    }

    func toggleLogin() {
        toggleLoginItem()
        refresh()
    }

    func showDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dataPath)])
    }

    // MARK: ClickUp (0010)

    func connect() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            NSSound.beep()
            return
        }
        clickUpBusy = true
        clickUpMessage = "Checking the token with ClickUp…"
        Task {
            do {
                let who = try await connectClickUp(value)
                token = ""
                clickUpMessage = "Signed in as \(who). Direct messages waiting for your reply will appear under “Waiting for you” within a minute."
            } catch {
                clickUpMessage = Self.reason(for: error)
            }
            clickUpBusy = false
            refresh()
        }
    }

    func disconnect() {
        clickUpMessage = nil
        perform { [self] in await disconnectClickUp() }
    }

    private static func reason(for error: Error) -> String {
        switch error {
        case ClickUpError.unauthorized:
            "ClickUp didn’t accept that token. Check that you copied all of it (it starts with pk_)."
        case ClickUpError.disabled:
            "ClickUp is off in instances started with --data-dir."
        case is ClickUpError:
            "ClickUp answered with an error. Try again in a moment."
        default:
            "Rallo couldn’t reach ClickUp. Check your connection and try again."
        }
    }

    // MARK: Agents (0007)

    func loadAgents() async {
        let data = await EmbeddedCLI.run(["doctor", "--json"])
        let checks = CLIReports.doctorChecks(data)
        agents = .known(hooks: checks["agent_hooks"], skill: checks["agent_skill"])
    }

    func setupAgents(_ what: String) {
        agentsBusy = true
        agentsMessage = nil
        Task {
            let data = await EmbeddedCLI.run(["setup", what, "--json"])
            let outcome = what == "hooks" ? CLIReports.hooksOutcome(data) : CLIReports.skillOutcome(data)
            switch outcome {
            case let .done(text), let .failed(text): agentsMessage = text
            }
            agentsBusy = false
            await loadAgents()
        }
    }

    // MARK: Updates

    func checkForUpdates() {
        updateBusy = true
        update = nil
        Task {
            update = CLIReports.updateOutcome(await EmbeddedCLI.run(["update", "--check", "--json"]))
            updateBusy = false
        }
    }

    /// `rallo update` quits this app, swaps the bundle, and relaunches, so
    /// it is started and left running rather than awaited.
    func installUpdate() {
        let process = Process()
        process.executableURL = EmbeddedCLI.url
        process.arguments = ["update"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        updateBusy = true
        do {
            try process.run()
        } catch {
            update = .failed("Rallo couldn’t start the update.")
            updateBusy = false
        }
    }

    /// `rallo uninstall` quits this app and removes it, so like the update it
    /// is started and left running rather than awaited.
    func uninstall(deleteNotes: Bool) {
        let process = Process()
        process.executableURL = EmbeddedCLI.url
        process.arguments = ["uninstall", "--yes"] + (deleteNotes ? ["--purge"] : [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // On success this app is quit before the CLI exits; still running
        // means it stopped early (say, the final export failed).
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                self?.uninstalling = false
                self?.uninstallMessage = "Rallo couldn’t uninstall; nothing was removed. Run “rallo uninstall” in Terminal to see why."
            }
        }
        uninstalling = true
        uninstallMessage = nil
        do {
            try process.run()
        } catch {
            uninstalling = false
            NSSound.beep()
        }
    }
}
