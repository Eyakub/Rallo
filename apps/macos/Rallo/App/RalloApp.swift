import AppKit

@main
enum RalloApp {
    static func main() {
        let options = LaunchOptions.parse(CommandLine.arguments)
        if let probe = options.probe {
            exit(NotificationProbe.run(arguments: probe))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
