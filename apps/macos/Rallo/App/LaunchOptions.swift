import Foundation

/// How this process was started. The CLI passes `--background` or `--show`;
/// Finder, login, and notification clicks start it with no mode argument.
struct LaunchOptions {
    enum Mode {
        case interactive
        case background
        case show
    }

    var mode: Mode = .interactive
    var dataDir: String?
    /// Test-only crash point for the notification drainer (see FaultInjection).
    var faultInjection: String?
    /// Arguments after `--probe`: run a notification characterization and exit.
    var probe: [String]?
    /// `--prepare-uninstall`: undo what the bundle ID owns (Login Item,
    /// notifications, Keychain token), print a JSON report, and exit. Run by
    /// `rallo uninstall` (see UninstallPreparation).
    var prepareUninstall = false
    /// Screenshot mode (scripts/screenshots.sh), honoured only with an
    /// explicit `--data-dir`: `light`/`dark` for this instance, and what to
    /// open once it's up (`notes`, `menu`, `settings` or `settings:<tab>`).
    var demoAppearance: String?
    var demoOpen: String?

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--background":
                options.mode = .background
            case "--show":
                options.mode = .show
            case "--data-dir" where index + 1 < arguments.count:
                options.dataDir = arguments[index + 1]
                index += 1
            case "--fault-injection" where index + 1 < arguments.count:
                options.faultInjection = arguments[index + 1]
                index += 1
            case "--demo-appearance" where index + 1 < arguments.count:
                options.demoAppearance = arguments[index + 1]
                index += 1
            case "--demo-open" where index + 1 < arguments.count:
                options.demoOpen = arguments[index + 1]
                index += 1
            case "--prepare-uninstall":
                options.prepareUninstall = true
            case "--probe":
                options.probe = Array(arguments[(index + 1)...])
                return options
            default:
                // AppKit and Xcode pass their own arguments; ignore them.
                break
            }
            index += 1
        }
        return options
    }
}
