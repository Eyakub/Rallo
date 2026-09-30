import AppKit
import notify
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var instanceLock: InstanceLock?
    private var coordinator: AppCoordinator?
    private var terminationSource: DispatchSourceSignal?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let dataDir: String
        do {
            dataDir = try resolveDataDir(explicit: options.dataDir)
        } catch {
            NSLog("Rallo: cannot resolve data directory: %@", "\(error)")
            exit(EXIT_FAILURE)
        }
        guard let lock = Self.acquireInstanceLock(dataDir: dataDir) else {
            // Another instance owns this data directory: forward an explicit
            // show request (never for background launches) and exit.
            if options.mode != .background {
                notify_post(showSignalName(dataDir: dataDir))
            }
            exit(EXIT_SUCCESS)
        }
        instanceLock = lock
        let coordinator = AppCoordinator(dataDir: dataDir, launchMode: options.mode, options: options)
        self.coordinator = coordinator
        // Must be set before launch completes to receive the response that
        // launched the app from a notification click.
        UNUserNotificationCenter.current().delegate = coordinator.notifications
        installTerminationHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await coordinator?.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let source = Self.reopenSource()
        Task { @MainActor in coordinator?.handleReopen(source: source) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Who sent the reopen event. The CLI's `open -g` requests can queue up
    /// while the app is starting and arrive as reopen events after `open` has
    /// exited, so only a sender that resolves to a running GUI application
    /// (Finder, Dock, Spotlight, …) counts as a user asking to see Rallo.
    private static func reopenSource() -> AppCoordinator.ReopenSource {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else { return .unknown(pid: nil) }
        let pid = pid_t(descriptor.int32Value)
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier {
            return .application(bundleID: bundleID)
        }
        return .unknown(pid: pid)
    }

    /// The CLI probes the lock for an instant, so retry briefly before
    /// concluding that a real instance holds it.
    private static func acquireInstanceLock(dataDir: String) -> InstanceLock? {
        for attempt in 0..<20 {
            if let lock = try? tryAcquireInstanceLock(dataDir: dataDir) {
                return lock
            }
            if attempt < 19 { usleep(50_000) }
        }
        return nil
    }

    /// Treat SIGTERM (e.g. from the dev install script) as an ordinary quit.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }
}
