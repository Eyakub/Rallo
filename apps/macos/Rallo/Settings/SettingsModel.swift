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

    nonisolated private static let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rallo")

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
        let data = await Self.run(["doctor", "--json"])
        let checks = CLIReports.doctorChecks(data)
        agents = .known(hooks: checks["agent_hooks"], skill: checks["agent_skill"])
    }

    func setupAgents(_ what: String) {
        agentsBusy = true
        agentsMessage = nil
        Task {
            let data = await Self.run(["setup", what, "--json"])
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
            update = CLIReports.updateOutcome(await Self.run(["update", "--check", "--json"]))
            updateBusy = false
        }
    }

    /// `rallo update` quits this app, swaps the bundle, and relaunches, so
    /// it is started and left running rather than awaited.
    func installUpdate() {
        let process = Process()
        process.executableURL = Self.cli
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

    /// Runs the embedded CLI off the main thread and returns its stdout.
    /// `doctor` exits 1 on a problem yet still prints its report, so the
    /// exit status is ignored.
    private static func run(_ arguments: [String]) async -> Data {
        await Task.detached {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return Data() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
    }
}
