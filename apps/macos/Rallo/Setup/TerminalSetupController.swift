import AppKit
import SwiftUI

/// "Enable Terminal Command…": shows what will happen, then links the CLI.
@MainActor
final class TerminalSetupController {
    private let log: DiagnosticsLog
    private let model = TerminalSetupModel()
    private var panel: NSPanel?
    private let appURL = Bundle.main.bundleURL
    private let home = FileManager.default.homeDirectoryForCurrentUser

    init(log: DiagnosticsLog) {
        self.log = log
        model.cliPath = TerminalCommand.cliURL(in: appURL).path
        model.onEnable = { [weak self] in self?.enable() }
        model.onClose = { [weak self] in self?.panel?.orderOut(nil) }
    }

    /// Menu title reflecting the current link, without asking the shell.
    var menuTitle: String {
        if case .enabled = TerminalCommand.inspect(appURL: appURL, home: home, pathDirectories: []) {
            return "Terminal Command…"
        }
        return "Enable Terminal Command…"
    }

    func open() {
        model.stage = .checking
        show()
        Task.detached { [appURL, home] in
            let path = TerminalCommand.loginShellPath()
            let noninteractive = TerminalCommand.loginShellPath(interactive: false)
            let state = TerminalCommand.inspect(appURL: appURL, home: home, pathDirectories: path ?? [])
            await MainActor.run { [weak self] in
                self?.model.noninteractivePath = noninteractive
                self?.model.stage = .state(state, pathKnown: path != nil)
                self?.log.record("terminal_setup_opened", ["state": Self.stateName(state)])
                self?.fit()
            }
        }
    }

    /// Identifies which branch of `TerminalCommand.State` was shown, without
    /// logging any path: a report otherwise can't tell "never opened" apart
    /// from "opened but never clicked Enable".
    private static func stateName(_ state: TerminalCommand.State) -> String {
        switch state {
        case .enabled: "enabled"
        case .available: "available"
        case .repairable: "repairable"
        case .conflict: "conflict"
        case .notInstalled: "not_installed"
        }
    }

    private func enable() {
        guard case let .state(state, pathKnown) = model.stage else { return }
        do {
            let link = try TerminalCommand.enable(state, appURL: appURL)
            log.record("terminal_command_enabled", ["link": link.path])
            let onPath: Bool = switch state {
            case let .available(_, onPath), let .repairable(_, _, onPath), let .enabled(_, onPath): onPath
            default: false
            }
            model.stage = .state(.enabled(link: link, onPath: onPath), pathKnown: pathKnown)
        } catch {
            log.record("terminal_command_failed", ["error": "\(error)"])
            model.stage = .failed(error.localizedDescription)
        }
        fit()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        fit(center: !wasVisible)
    }

    private func fit(center: Bool = false) {
        DispatchQueue.main.async { [weak panel] in
            guard let panel, let size = panel.contentView?.fittingSize else { return }
            panel.setContentSize(size)
            if center { panel.center() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Terminal Command"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: TerminalSetupView(model: model))
        return panel
    }
}

@MainActor
final class TerminalSetupModel: ObservableObject {
    enum Stage: Equatable {
        case checking
        case state(TerminalCommand.State, pathKnown: Bool)
        case failed(String)
    }

    @Published var stage: Stage = .checking
    /// PATH of a non-interactive login shell, if it answered.
    var noninteractivePath: [String]?
    var cliPath = ""
    var onEnable: () -> Void = {}
    var onClose: () -> Void = {}
}

struct TerminalSetupView: View {
    @ObservedObject var model: TerminalSetupModel
    @State private var copied: String?

    private static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#
    private static let example = #"rallo note "Call the dentist""#

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: Bundle.main.image(forResource: pose) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(Theme.rounded(18, .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    details
                }
                .padding(.top, 6)
            }
            buttons.padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(width: 400)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
    }

    private var pose: String {
        switch model.stage {
        case .state(.enabled, _): "pet-celebrate"
        case .state(.conflict, _), .state(.notInstalled, _), .failed: "pet-nudge"
        default: "pet-idle"
        }
    }

    private var title: String {
        switch model.stage {
        case .checking: "Checking your terminal setup…"
        case .state(.enabled, _): "The rallo command is ready"
        case .state(.available, _): "Use Rallo from the terminal?"
        case .state(.repairable, _): "Fix the rallo command?"
        case .state(.conflict, _): "Another rallo command already exists"
        case .state(.notInstalled, _): "Move Rallo to Applications first"
        case .failed: "Couldn’t add the command"
        }
    }

    @ViewBuilder
    private var details: some View {
        switch model.stage {
        case .checking:
            ProgressView().controlSize(.small)
        case let .state(.available(directory, onPath), pathKnown):
            paragraph("Rallo will add a `rallo` command to \(tilde(directory.path)), linked to this app. Nothing else on your Mac changes.")
            if !onPath { pathHint(directory: directory, pathKnown: pathKnown) }
        case let .state(.repairable(_, oldTarget, onPath), pathKnown):
            paragraph("Your `rallo` command points to a copy of Rallo that moved or was deleted (\(tilde(oldTarget))). Rallo can point it at this app instead.")
            if !onPath { pathHint(directory: URL(fileURLWithPath: NSString(string: "~/.local/bin").expandingTildeInPath), pathKnown: pathKnown) }
        case let .state(.enabled(link, onPath), pathKnown):
            paragraph("Try it in a terminal:")
            code(Self.example)
            if onPath {
                paragraph("If a terminal that was already open says “command not found”, run `rehash` or open a new window. Agents that were already running need a restart.")
                if let path = model.noninteractivePath,
                   !path.contains(link.deletingLastPathComponent().standardizedFileURL.path) {
                    paragraph("Tools that run commands without an interactive terminal (some agents, IDE tasks) won’t find it yet. Add this line to \(TerminalCommand.loginProfile):")
                    code(Self.pathLine)
                }
            } else {
                pathHint(directory: link.deletingLastPathComponent(), pathKnown: pathKnown)
            }
            fullPath
        case let .state(.conflict(existing), _):
            paragraph("\(tilde(existing.path)) isn’t Rallo’s, so Rallo won’t replace it. You can still run Rallo’s command by its full path:")
            fullPath
        case .state(.notInstalled, _):
            paragraph("Rallo is running from \(tilde(Bundle.main.bundlePath)). Drag it into Applications, open it from there, then try again.")
        case let .failed(message):
            paragraph(message)
            fullPath
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            switch model.stage {
            case .checking:
                EmptyView()
            case .state(.available, _):
                secondary("Cancel") { model.onClose() }
                primary("Add Command") { model.onEnable() }
            case .state(.repairable, _):
                secondary("Cancel") { model.onClose() }
                primary("Repair") { model.onEnable() }
            case .state(.enabled, _):
                // Not a dismiss action: Escape here should not silently
                // trigger a clipboard copy instead of closing the panel.
                secondary(copied == Self.example ? "Copied" : "Copy Example", isDismissive: false) { copy(Self.example) }
                primary("Done") { model.onClose() }
            default:
                primary("Done") { model.onClose() }
            }
        }
    }

    @ViewBuilder
    private func pathHint(directory: URL, pathKnown: Bool) -> some View {
        paragraph(pathKnown
                  ? "\(tilde(directory.path)) isn’t on your PATH. Add this line to ~/.zshrc, then open a new terminal:"
                  : "Rallo couldn’t read your shell’s PATH. If `rallo` isn’t found, add this line to ~/.zshrc:")
        code(Self.pathLine)
    }

    private var fullPath: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Full path").font(Theme.rounded(11, .semibold)).foregroundStyle(Theme.bark)
            code(model.cliPath)
        }
    }

    private func code(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy(text)
            } label: {
                Image(systemName: copied == text ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.bark)
            }
            .buttonStyle(.plain)
            .help("Copy")
            .accessibilityLabel("Copy \(text)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.hover))
    }

    private func paragraph(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(Theme.rounded(13))
            .foregroundStyle(Theme.bark)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.swipeSoon))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    /// `isDismissive` binds Escape (`.cancelAction`): only true for a button
    /// that actually closes the panel without side effects, e.g. "Cancel".
    @ViewBuilder
    private func secondary(_ title: String, isDismissive: Bool = true, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Text(title)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.hover))
                .overlay(Capsule().strokeBorder(Theme.fieldStroke))
        }
        .buttonStyle(.plain)
        if isDismissive {
            button.keyboardShortcut(.cancelAction)
        } else {
            button
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
    }

    private func tilde(_ path: String) -> String {
        NSString(string: path).abbreviatingWithTildeInPath
    }
}
