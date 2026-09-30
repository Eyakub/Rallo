import Foundation
import ServiceManagement

/// Optional "Open at Login" via SMAppService (spec §10). A login launch has
/// no mode argument, so it restores the saved visibility and never reopens
/// onboarding (see AppCoordinator.applyLaunchVisibility).
@MainActor
enum LoginItem {
    enum State {
        case on
        case off
        /// Registered, but the user must allow it in System Settings.
        case needsApproval
        /// Not installed in Applications, so there's nothing stable to open.
        case unavailable
    }

    static var state: State {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard TerminalCommand.isInstalled(Bundle.main.bundleURL, home: home) else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        // Measured on macOS 27: a never-registered app reports notFound, and
        // register() still succeeds, so it means "off" here.
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// Flips the setting; for `needsApproval`, opens the Login Items page
    /// instead, since only the user can approve there.
    static func toggle(log: DiagnosticsLog) {
        do {
            switch state {
            case .on:
                try SMAppService.mainApp.unregister()
            case .off:
                try SMAppService.mainApp.register()
                if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
            case .needsApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .unavailable:
                break
            }
            log.record("login_item_toggled", ["state": "\(state)"])
        } catch {
            // The Login Items page lets the user add or allow it by hand.
            log.record("login_item_failed", ["error": "\(error)"])
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
