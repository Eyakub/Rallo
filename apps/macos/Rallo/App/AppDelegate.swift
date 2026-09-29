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
        let coordinator = AppCoordinator(dataDir: dataDir, launchMode: options.mode)
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
        let fromCLI = Self.reopenCameFromOpenTool()
        Task { @MainActor in coordinator?.handleReopen(fromCLI: fromCLI) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The CLI's own launch request can race app startup and arrive as a
    /// reopen event; it must not override a deliberate hide.
    private static func reopenCameFromOpenTool() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pidDescriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else { return false }
        let pid = pid_t(pidDescriptor.int32Value)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer) == "/usr/bin/open"
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
