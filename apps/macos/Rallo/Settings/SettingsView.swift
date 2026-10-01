import AppKit
import SwiftUI

struct SettingsView: View {
    static let width: CGFloat = 540
    static let height: CGFloat = 400

    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            NotificationsTab(model: model).tabItem { Label("Notifications", systemImage: "bell") }
            AgentsTab(model: model).tabItem { Label("Agents", systemImage: "terminal") }
            ClickUpTab(model: model).tabItem { Label("ClickUp", systemImage: "bubble.left.and.bubble.right") }
            DataTab(model: model).tabItem { Label("Data", systemImage: "externaldrive") }
            AboutTab(model: model).tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: Self.width, height: Self.height)
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

    private func statusRow(_ title: String, check: CLIReports.Check?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.rounded(13, .semibold)).frame(width: 48, alignment: .leading)
            Text(check?.summary ?? "Checking…")
                .font(Theme.rounded(13))
                .foregroundStyle(check?.status == "ok" || check == nil ? Theme.ink : Theme.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
                }
            }
            HStack {
                Button("Check for Updates") { model.checkForUpdates() }
                if model.updateBusy { ProgressView().controlSize(.small) }
            }
            .disabled(model.updateBusy)
            updateResult
            Spacer()
            HStack {
                Link("github.com/Eyakub/Rallo", destination: URL(string: "https://github.com/Eyakub/Rallo")!)
                Spacer()
                Text("MIT License").foregroundStyle(Theme.bark)
            }
            .font(Theme.rounded(12))
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
