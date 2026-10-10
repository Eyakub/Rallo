import AppKit

/// Runs the eye-break cycle (0022): feeds `EyeBreakPlanner` the clock, idle
/// time, quiet signals and system events, and performs what each change of
/// phase asks for (`EyeBreakEffects`).
@MainActor
final class EyeBreakController {
    private var planner = EyeBreakPlanner(settings: .init(), now: Date())
    private let quiet: QuietSignals
    private let pet: PetController
    private let log: DiagnosticsLog
    private let intervalOverride: TimeInterval?
    private let overlay = EyeBreakOverlay()
    private let pill = EyeBreakPill()
    private let toast = EyeBreakToast()
    private var timer: Timer?
    private var started = false
    /// Lets go of the toast's happy pose; cancelled when a nudge or a newer toast takes over.
    private var toastRelease: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var locked = false
    private var displaysAsleep = false
    private var systemAsleep = false
    private var bubbleVisible = false
    /// The app that was frontmost when the break began; it gets focus back (§4, §5).
    private var recordedApp: NSRunningApplication?

    /// The menu's Pause Animations, wired by the coordinator.
    var animationsPaused: () -> Bool = { false }
    /// A break ended, however it ended: a reminder round waiting for it runs (0021 §8).
    var onBreakEnded: () -> Void = {}

    init(quiet: QuietSignals, pet: PetController, log: DiagnosticsLog, intervalOverride: TimeInterval?) {
        self.quiet = quiet
        self.pet = pet
        self.log = log
        self.intervalOverride = intervalOverride
        overlay.onSkip = { [weak self] in self?.change { _ = $0.skip(Date()) } }
        overlay.onPostpone = { [weak self] in self?.change { _ = $0.postpone(Date()) } }
        overlay.onEscHeld = { [weak self] in self?.change { $0.escHeld(Date()) } }
        pill.onStartNow = { [weak self] in self?.startNow() }
        pill.onPostpone = { [weak self] in self?.change { _ = $0.postpone(Date()) } }
        pill.onSkip = { [weak self] in self?.change { _ = $0.skip(Date()) } }
    }

    var isBreaking: Bool {
        if case .breaking = planner.phase { return true }
        return false
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
        arm()
    }

    func apply(_ stored: EyeBreakSettings) {
        let settings = EyeBreakPlanner.Settings(stored, intervalOverride: intervalOverride)
        guard settings != planner.settings else { return }
        change { $0.apply(settings, now: Date()) }
    }

    /// The reminder bubble opened or closed (0021): a due break waits for it.
    func setBubbleVisible(_ visible: Bool) {
        bubbleVisible = visible
        tick()
    }

    func startNow() { change { $0.startNow(Date()) } }

    func pause(until: Date) { change { $0.pause(until: until, now: Date()) } }

    func menuStatus() -> EyeBreakPlanner.MenuStatus { planner.menuStatus(now: Date()) }

    // MARK: Driving the planner

    private func tick() {
        guard started else { return }
        let hold = EyeBreakPlanner.Hold(
            callActive: planner.settings.holdOnCall && quiet.cameraOrMicInUse, bubbleVisible: bubbleVisible)
        let idle = QuietSignals.idleSeconds()
        change { $0.tick(now: Date(), idle: idle, hold: hold) }
    }

    private func change(_ body: (inout EyeBreakPlanner) -> Void) {
        let before = planner
        var after = planner
        body(&after)
        planner = after
        for effect in EyeBreakEffects.between(before, after) { perform(effect) }
        if before.phase != after.phase { log.record("eye_break_phase", ["phase": "\(after.phase)"]) }
        arm()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard started, let next = planner.nextCheck(now: Date()) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !animationsPaused()
    }

    private func perform(_ effect: EyeBreakEffect) {
        switch effect {
        case let .showPill(until):
            pill.show(until: until, total: planner.settings.warning, on: Self.screenUnderMouse())
        case .hidePill:
            pill.hide()
        case let .nudgePet(on):
            toastRelease?.cancel()
            toastRelease = nil
            pet.hold(on ? .nudge : nil)
        case let .showOverlay(until):
            if !overlay.isVisible {
                let front = NSWorkspace.shared.frontmostApplication
                // Rallo frontmost (panel or notes window open): it simply stays active.
                recordedApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            }
            overlay.show(until: until, tip: planner.tip, allowSkip: planner.settings.allowSkip, animate: motionAllowed)
            NSApp.activate()
            overlay.makeMainKey()
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: EyeBreakText.announcement(length: planner.settings.length),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        case .closeOverlay:
            overlay.close(animate: motionAllowed)
        case .restoreFocus:
            // Even if Rallo never became active: the recorded app is then still in front.
            recordedApp?.activate()
            recordedApp = nil
        case let .toast(nextIn):
            toast.show(EyeBreakText.toast(nextIn: nextIn), near: pet.isVisible ? pet.frame : nil)
            pet.hold(.happy)
            toastRelease?.cancel()
            let release = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.pet.hold(nil)
                    self?.toastRelease = nil
                }
            }
            toastRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: release)
        case .resumeAlerts:
            onBreakEnded()
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: System events (§2)

    private func observe() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = true; self?.screenAvailabilityChanged() }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // An unlock implies awake displays, even if a wake notification was missed.
                self.locked = false
                self.displaysAsleep = false
                self.systemAsleep = false
                self.screenAvailabilityChanged()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, @MainActor (EyeBreakController) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.displaysAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.displaysAsleep = false }),
            (NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.systemAsleep = false }),
        ]
        for (name, update) in pairs {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    update(self)
                    self.screenAvailabilityChanged()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.rebuild() }
        })
        // A clock change can land a warning or break in the past or the future: re-check now.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
    }

    private func screenAvailabilityChanged() {
        let available = !locked && !displaysAsleep && !systemAsleep
        change { $0.setScreenAvailable(available, now: Date()) }
    }
}
