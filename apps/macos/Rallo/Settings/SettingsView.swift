import AppKit
import SwiftUI

/// The Settings window's tabs, shown as native toolbar tabs by
/// `SettingsWindowController` (a SwiftUI TabView in an AppKit window folds
/// its tabs into the toolbar's overflow menu on macOS 26). The raw value is
/// `SettingsModel.tab`.
enum SettingsTab: String, CaseIterable {
    case general, notifications, agents, voice, clickup, data, about

    static let size = CGSize(width: 540, height: 400)

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .voice: "Voice"
        case .clickup: "ClickUp"
        case .data: "Data"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .agents: "terminal"
        case .voice: "waveform"
        case .clickup: "bubble.left.and.bubble.right"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    @MainActor
    func view(_ model: SettingsModel) -> some View {
        Group {
            switch self {
            case .general: GeneralTab(model: model)
            case .notifications: NotificationsTab(model: model)
            case .agents: AgentsTab(model: model)
            case .voice: VoiceTab(model: model)
            case .clickup: ClickUpTab(model: model)
            case .data: DataTab(model: model)
            case .about: AboutTab(model: model)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// Shared page chrome: Theme surface, ink text, left-aligned column. The
/// window has a fixed size, so a page that outgrows it scrolls rather than
/// clips.
private struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
        }
        .foregroundStyle(Theme.ink)
        .tint(Theme.rust)
        .background(Theme.surface)
    }
}

private func caption(_ text: String) -> some View {
    Text(text)
        .font(Theme.rounded(12))
        .foregroundStyle(Theme.bark)
        .fixedSize(horizontal: false, vertical: true)
}

private func line(_ text: String) -> some View {
    Text(text)
        .font(Theme.rounded(13))
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Page {
            Toggle(loginTitle, isOn: Binding(get: { model.loginState == .on }, set: { _ in model.toggleLogin() }))
                .disabled(model.loginState == .unavailable)
                .help(model.loginState == .unavailable ? "Move Rallo to Applications to open it at login." : "")
            Toggle("Show the pet", isOn: Binding(get: { model.petVisible }, set: { _ in model.perform(model.togglePet) }))
            Toggle("Check for updates daily", isOn: Binding(get: { model.updateCheckEnabled }, set: { model.setUpdateCheck($0) }))
                .disabled(!model.updateCheckAllowed)
            caption("Asks GitHub once a day whether a newer Rallo is out, then tells you in the menu and with a notification. Nothing about you or your notes is sent; installing still waits for you.")
            Divider()
            Text("Terminal command").font(Theme.rounded(13, .semibold))
            HStack {
                line(model.terminalEnabled ? "The rallo command is set up." : "The rallo command isn’t set up yet.")
                Spacer()
                Button(model.terminalEnabled ? "Terminal Command…" : "Enable Terminal Command…") {
                    model.openTerminalSetup()
                }
            }
            Divider()
            Text("Data folder").font(Theme.rounded(13, .semibold))
            HStack {
                Text(model.dataPathDisplay)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.bark)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button("Show in Finder") { model.showDataFolder() }
            }
        }
    }

    private var loginTitle: String {
        model.loginState == .needsApproval ? "Open at Login (Allow in System Settings…)" : "Open at Login"
    }
}

// MARK: Notifications

private struct NotificationsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Page {
            HStack {
                line(model.notificationSummary)
                Spacer()
                Button("Enable Notifications…") { model.perform(model.enableNotifications) }
            }
            if !model.notificationsAuthorized {
                Text("Notifications are off for Rallo")
                    .font(Theme.rounded(12, .semibold))
                    .foregroundStyle(Theme.error)
            }
            Toggle("Notify when an agent waits 5 minutes",
                   isOn: Binding(get: { model.notifyLongWait }, set: { _ in model.perform(model.toggleNotifyLongWait) }))
            caption("Reminders already scheduled with macOS still arrive after Rallo quits.")
        }
    }
}

// MARK: Agents

private struct AgentsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Page {
            line("Hooks let the pet wave when Claude Code or Codex waits for you. The skill teaches agents to use rallo.")
            statusRow("Hooks", check: hooks)
            statusRow("Skill", check: skill)
            HStack {
                Button("Install Hooks") { model.setupAgents("hooks") }
                Button("Update Skill") { model.setupAgents("skill") }
                if model.agentsBusy { ProgressView().controlSize(.small) }
            }
            .disabled(model.agentsBusy)
            if let message = model.agentsMessage { caption(message) }
        }
    }

    private var hooks: CLIReports.Check? {
        if case let .known(hooks, _) = model.agents { return hooks }
        return nil
    }

    private var skill: CLIReports.Check? {
        if case let .known(_, skill) = model.agents { return skill }
        return nil
    }

    /// Doctor's statuses: ok, warning (worth fixing), problem.
    private func color(_ status: String?) -> Color {
        switch status {
        case "ok": Theme.bamboo
        case "warning": Theme.rust
        case "problem": Theme.error
        default: Theme.ink
        }
    }

    private func statusRow(_ title: String, check: CLIReports.Check?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.rounded(13, .semibold)).frame(width: 48, alignment: .leading)
            Text(check.map { ($0.summary as NSString).replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Checking…")
                .font(Theme.rounded(13))
                .foregroundStyle(color(check?.status))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Voice (0013, 0014, 0015)

/// A native grouped form (System Settings style): labels left, controls
/// right, one short footer per section. Details live in tooltips, and
/// permission rows appear only when something is missing.
private struct VoiceTab: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(VoiceText.wordsKey) private var voiceWords = ""
    @AppStorage("voiceEngine") private var storedEngine = "apple"
    @AppStorage("voiceLanguage") private var language = "auto"
    @AppStorage(VoiceText.tidyKey) private var tidy = true
    @State private var confirmDelete = false

    /// Apple's engine needs macOS 26; before that only Whisper exists.
    private var engine: String {
        if #available(macOS 26, *) { storedEngine } else { storedEngine == "apple" ? "whisper" : storedEngine }
    }

    private var appleAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.voiceTypingEnabled }, set: { model.setVoiceTyping($0) })) {
                    Text("Voice typing")
                    Text("Press ⌃⌥⌘V anywhere and talk; press it again to stop.")
                }
                if model.voiceTypingEnabled, !VoicePermissions.microphoneAllowed {
                    permissionRow("Microphone", pane: "Privacy_Microphone")
                }
                if model.voiceTypingEnabled, model.voiceAccessibilityMissing {
                    permissionRow("Accessibility", pane: "Privacy_Accessibility")
                }
                if model.voiceTypingEnabled, model.voiceShortcutTaken {
                    // macOS refused it (another app has it); Try Again once that app lets go.
                    LabeledContent("⌃⌥⌘V") {
                        Text("Shortcut in use").foregroundStyle(Theme.error)
                        Button("Try Again") { model.setVoiceTyping(true) }
                    }
                }
            } footer: {
                footnote("Experimental. Audio is never saved.")
            }

            Section {
                Picker("Engine", selection: Binding(get: { engine }, set: { storedEngine = $0 })) {
                    if appleAvailable { Text("Apple, on this Mac").tag("apple") }
                    Text("Whisper, on this Mac").tag("whisper")
                    Text("Cloud, with your API key").tag("cloud")
                }
                if engine == "whisper" { modelRow }
                if engine == "cloud" { CloudVoiceRows() }
                if engine != "apple" {
                    Picker("Language", selection: $language) {
                        Text("Automatic").tag("auto")
                        Text("English").tag("en")
                        Text("Bangla").tag("bn")
                    }
                }
            } footer: {
                engineFooter
            }

            Section {
                TextField("Words to recognize", text: $voiceWords, prompt: Text("Names, terms"))
                    .help("Separate with commas. Rallo, ClickUp, cmux, Claude and Codex are built in.")
                Toggle("Remove “um”s and repeated words", isOn: $tidy)
                    .help("Turn off to type exactly what was heard.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .tint(Theme.rust)
    }

    @ViewBuilder
    private var engineFooter: some View {
        switch engine {
        case "whisper": footnote("Large-v3 turbo, kept in the shared Hugging Face cache so other Whisper tools can use it.")
        case "cloud": CloudVoiceFooter()
        default: footnote("Built into macOS. Nothing to download.")
        }
    }

    private func permissionRow(_ title: String, pane: String) -> some View {
        LabeledContent(title) {
            Text("Not allowed").foregroundStyle(Theme.error)
            Button("Open Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch model.whisperModel {
        case .checking:
            LabeledContent("Model") { ProgressView().controlSize(.small) }
        case .missing:
            LabeledContent("Model") {
                Button("Download (1.6 GB)") { model.downloadWhisperModel() }
            }
        case let .failed(message):
            LabeledContent("Model") {
                Text(message).foregroundStyle(Theme.error).lineLimit(2)
                Button("Try Again") { model.downloadWhisperModel() }
            }
        case let .downloading(fraction):
            LabeledContent("Model") {
                ProgressView(value: fraction).frame(width: 120)
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(Theme.bark)
                Button("Cancel") { model.cancelWhisperDownload() }
            }
        case let .ready(path):
            LabeledContent("Model") {
                Text("Downloaded").foregroundStyle(Theme.bark)
                    .help((path as NSString).abbreviatingWithTildeInPath)
                Button("Show in Finder") { model.showWhisperModel() }
                Button("Delete…") { confirmDelete = true }
                    .confirmationDialog("Delete the Whisper model?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete Model", role: .destructive) { model.deleteWhisperModel() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Other apps that use this file will need to download it again.")
                    }
            }
        }
    }
}

private func footnote(_ text: String) -> some View {
    Text(text).font(Theme.rounded(11.5)).foregroundStyle(Theme.bark)
}

/// Provider, model and API key rows for the cloud engine (0015). The key is
/// never shown; once saved, the field gives way to "Saved in Keychain".
private struct CloudVoiceRows: View {
    @AppStorage(CloudVoiceProvider.providerKey) private var providerID = "groq"
    @AppStorage(CloudVoiceProvider.baseURLKey) private var customBase = ""
    @State private var keyText = ""
    @State private var saved = false
    @State private var keyError = false

    private var provider: CloudVoiceProvider { CloudVoiceProvider(rawValue: providerID) ?? .groq }

    private var secret: KeychainSecret {
        KeychainSecret(service: CloudVoiceProvider.keychainService, account: provider.rawValue, label: provider.keychainLabel)
    }

    var body: some View {
        Picker("Provider", selection: $providerID) {
            ForEach(CloudVoiceProvider.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
        }
        .task(id: providerID) {
            keyText = ""
            keyError = false
            let secret = secret
            saved = await Task.detached { secret.exists() }.value
        }
        if provider == .custom {
            TextField("Address", text: $customBase, prompt: Text("https://…/v1"))
            if !customBase.isEmpty, CloudVoiceProvider.endpoint(base: customBase) == nil {
                Text("Use an https address (http only for localhost).").foregroundStyle(Theme.error)
            }
        }
        CloudModelField(provider: provider).id(provider)
        LabeledContent("API key") {
            if saved {
                Text("Saved in Keychain").foregroundStyle(Theme.bark)
                Button("Remove") { remove() }
            } else {
                SecureField("API key", text: $keyText, prompt: Text("Paste key"))
                    .labelsHidden()
                    .frame(maxWidth: 200)
                Button("Save") { save() }.disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if keyError {
            Text("Couldn’t use the Keychain.").foregroundStyle(Theme.error)
        }
    }

    private func save() {
        let secret = secret
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok = await Task.detached { secret.save(key) }.value
            keyError = !ok
            saved = ok
            if ok { keyText = "" }
        }
    }

    private func remove() {
        let secret = secret
        Task {
            let status = await Task.detached { secret.delete() }.value
            keyError = status != errSecSuccess && status != errSecItemNotFound
            saved = keyError ? saved : false
        }
    }
}

/// "Phrases are sent to Groq. Get a free key" under the engine section.
private struct CloudVoiceFooter: View {
    @AppStorage(CloudVoiceProvider.providerKey) private var providerID = "groq"

    var body: some View {
        let provider = CloudVoiceProvider(rawValue: providerID) ?? .groq
        HStack(spacing: 4) {
            footnote("Each phrase is sent to \(provider.name).")
            if let url = provider.helpURL {
                Link(provider == .groq ? "Get a free key" : "Get a key", destination: url)
                    .font(Theme.rounded(11.5, .semibold))
                    .foregroundStyle(Theme.rust)
            }
        }
        .help(provider == .groq ? "Free Groq keys allow about 20 phrases a minute." : "")
    }
}

private struct CloudModelField: View {
    let provider: CloudVoiceProvider
    @AppStorage private var model: String

    init(provider: CloudVoiceProvider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: "", provider.modelKey)
    }

    var body: some View {
        TextField("Model", text: $model, prompt: Text(provider.defaultModel.isEmpty ? "whisper-1" : provider.defaultModel))
    }
}

// MARK: ClickUp (0010)

private struct ClickUpTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Page {
            line("Rallo checks ClickUp once a minute for direct messages waiting for your reply. The token stays in your Keychain; Rallo stores only the sender’s name, never message text.")
            if model.clickUpConnected {
                line(model.clickUpStatus ?? "Connected to ClickUp.")
                Button("Disconnect ClickUp") { model.disconnect() }
            } else {
                if let status = model.clickUpStatus { line(status).foregroundStyle(Theme.error) }
                caption("Paste a personal API token from ClickUp → Settings → Apps.")
                HStack {
                    SecureField("pk_…", text: $model.token)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("ClickUp API token")
                        .onSubmit { model.connect() }
                    Button("Connect") { model.connect() }
                }
                .disabled(model.clickUpBusy)
            }
            if let message = model.clickUpMessage { caption(message) }
        }
    }
}

// MARK: Data

private struct DataTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Page {
            row("Export Backup (JSON)…", "Everything in one file Rallo can restore.", model.exportBackup)
            row("Export Spreadsheet (CSV)…", "Your notes as rows for Numbers or Excel.", model.exportSpreadsheet)
            row("Import Notes…", "Bring notes in from a backup or spreadsheet; you review them first.", model.importNotes)
        }
    }

    private func row(_ title: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        HStack {
            caption(detail)
            Spacer()
            Button(title, action: action)
        }
    }
}

// MARK: About

private struct AboutTab: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmUpdate = false
    @State private var confirmUninstall = false

    var body: some View {
        Page {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rallo").font(Theme.rounded(20, .semibold))
                    Text("Version \(model.version)").font(Theme.rounded(12)).foregroundStyle(Theme.bark)
                    HStack(spacing: 4) {
                        Link("github.com/Eyakub/Rallo", destination: URL(string: "https://github.com/Eyakub/Rallo")!)
                        Text("· MIT License").foregroundStyle(Theme.bark)
                    }
                    .font(Theme.rounded(12))
                }
            }
            HStack {
                Button("Check for Updates") { model.checkForUpdates() }
                if model.updateBusy { ProgressView().controlSize(.small) }
            }
            .disabled(model.updateBusy)
            updateResult
            Divider().padding(.top, 8)
            HStack {
                caption(model.uninstallAvailable
                    ? "Removes Rallo and everything it set up. Your notes stay unless you choose to delete them."
                    : "Uninstall from the copy of Rallo in Applications.")
                Spacer()
                Button("Uninstall Rallo…") { confirmUninstall = true }
                    .disabled(!model.uninstallAvailable || model.uninstalling)
                    .confirmationDialog("Uninstall Rallo?", isPresented: $confirmUninstall, titleVisibility: .visible) {
                        Button("Uninstall, Keep My Notes") { model.uninstall(deleteNotes: false) }
                        Button("Uninstall and Delete My Notes", role: .destructive) { model.uninstall(deleteNotes: true) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Rallo quits and removes the app, its terminal command, agent hooks and skill, Open at Login, scheduled reminders, the ClickUp token, and voice API keys. Deleting your notes saves a final export to Downloads first.")
                    }
            }
            if let message = model.uninstallMessage { line(message).foregroundStyle(Theme.error) }
        }
    }

    @ViewBuilder
    private var updateResult: some View {
        switch model.update {
        case nil:
            EmptyView()
        case let .upToDate(current):
            line("Rallo \(current) is up to date.")
        case let .available(_, latest):
            HStack {
                line("Rallo \(latest) is available.")
                Spacer()
                Button("Update Now") { confirmUpdate = true }
                    .confirmationDialog("Update Rallo to \(latest)?", isPresented: $confirmUpdate) {
                        Button("Quit Rallo and Update") { model.installUpdate() }
                    } message: {
                        Text("Rallo will quit, install \(latest), and relaunch.")
                    }
            }
        case let .failed(message):
            line(message).foregroundStyle(Theme.error)
        }
    }
}
