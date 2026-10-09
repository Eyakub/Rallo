import AppKit

/// The passive floating pet window.
///
/// Window behaviour is fixed by docs/decisions/0002-pet-window-configuration.md.
/// Features must not adjust level or collection behaviour ad hoc.
final class PetPanel: NSPanel {
    static let spriteSize = NSSize(width: 112, height: 92)

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
        canHide = false
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
