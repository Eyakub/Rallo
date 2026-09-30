import AppKit

/// The passive floating pet window.
///
/// Window behaviour is fixed by docs/decisions/0002-pet-window-configuration.md.
/// Features must not adjust level or collection behaviour ad hoc.
final class PetPanel: NSPanel {
    static let spriteSize = NSSize(width: 143, height: 118)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.spriteSize),
            // Clicking a nonactivating panel never makes Rallo the active app
            // and never disturbs the frontmost app's text cursor.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        title = "Rallo"
    }

    // A passive pet never takes keyboard focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows, hides, and positions the pet; reports clicks and finished drags.
@MainActor
final class PetController {
    private let panel = PetPanel()
    private let petView: PetView
    private var observers: [NSObjectProtocol] = []
    private var displaysAsleep = false
    private var savedOrigin: NSPoint?

    var onClick: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var contextMenu: () -> NSMenu? = { nil }

    init() {
        petView = PetView(frame: NSRect(origin: .zero, size: PetPanel.spriteSize))
        panel.contentView = petView
        petView.onClick = { [weak self] in self?.onClick() }
        petView.onDragEnded = { [weak self] origin in self?.onMoved(origin) }
        petView.menuProvider = { [weak self] in self?.contextMenu() }
        observe()
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    var window: NSWindow { panel }

    /// Orders the pet in without activating Rallo.
    func show(savedOrigin: NSPoint?) {
        self.savedOrigin = savedOrigin
        panel.setFrameOrigin(PetPlacementPolicy.resolve(saved: savedOrigin, size: PetPanel.spriteSize))
        panel.orderFrontRegardless()
        updateCanAnimate()
    }

    /// Hidden means zero animation frames, not merely an invisible window.
    func hide() {
        petView.stopAll()
        petView.canAnimate = false
        panel.orderOut(nil)
    }

    func move(savedOrigin: NSPoint?) {
        self.savedOrigin = savedOrigin
        panel.setFrameOrigin(PetPlacementPolicy.resolve(saved: savedOrigin, size: PetPanel.spriteSize))
    }

    func apply(pose: PetView.Pose, moment: PetView.Moment, animate: Bool, ambient: Bool, dueCount: Int,
               label: String, done: @escaping () -> Void) {
        petView.apply(pose: pose, moment: moment, animate: animate, ambient: ambient, dueCount: dueCount,
                      label: label, done: done)
    }

    private func updateCanAnimate() {
        petView.canAnimate = panel.isVisible && panel.occlusionState.contains(.visible) && !displaysAsleep
    }

    private func observe() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCanAnimate() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysAsleep = true
                self?.updateCanAnimate()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displaysAsleep = false
                self?.updateCanAnimate()
            }
        })
        // A display was unplugged or rearranged: keep the pet fully on a
        // screen that still exists, without forgetting the saved placement.
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.panel.setFrameOrigin(PetPlacementPolicy.resolve(saved: self.savedOrigin, size: PetPanel.spriteSize))
            }
        })
    }

    /// Renders the pet view into a PNG without Screen Recording permission.
    func snapshotPNG() -> Data? {
        guard let rep = petView.bitmapImageRepForCachingDisplay(in: petView.bounds) else { return nil }
        petView.cacheDisplay(in: petView.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
