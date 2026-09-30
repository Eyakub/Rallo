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

    var onClick: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var contextMenu: () -> NSMenu? = { nil }

    init() {
        petView = PetView(frame: NSRect(origin: .zero, size: PetPanel.spriteSize))
        panel.contentView = petView
        petView.onClick = { [weak self] in self?.onClick() }
        petView.onDragEnded = { [weak self] origin in self?.onMoved(origin) }
        petView.menuProvider = { [weak self] in self?.contextMenu() }
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    var window: NSWindow { panel }

    /// Orders the pet in without activating Rallo.
    func show(savedOrigin: NSPoint?) {
        panel.setFrameOrigin(PetPlacementPolicy.resolve(saved: savedOrigin, size: PetPanel.spriteSize))
        panel.orderFrontRegardless()
        petView.setAnimating(true)
    }

    func hide() {
        petView.setAnimating(false)
        panel.orderOut(nil)
    }

    func move(savedOrigin: NSPoint?) {
        panel.setFrameOrigin(PetPlacementPolicy.resolve(saved: savedOrigin, size: PetPanel.spriteSize))
    }

    func setPose(_ pose: PetView.Pose) {
        petView.pose = pose
    }

    /// Renders the pet view into a PNG without Screen Recording permission.
    func snapshotPNG() -> Data? {
        guard let rep = petView.bitmapImageRepForCachingDisplay(in: petView.bounds) else { return nil }
        petView.cacheDisplay(in: petView.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
