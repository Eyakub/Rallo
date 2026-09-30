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
