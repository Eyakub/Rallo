import AppKit
import Carbon

/// The summon (0021 §3): borrows the pet, dims the display under the
/// pointer, shows the bubble; gives it all back after an answer or 60 s.
@MainActor
final class SummonController {
    static let timeout: TimeInterval = 60

    private let pet: PetController
    private let bubble = SummonBubblePanel()
    private var dim: NSWindow?
    private var timeoutTimer: Timer?
    private var fades = false
    private var petOrigin = NSPoint.zero
    private(set) var alertID: String?

    var actions = SummonBubbleActions()
    /// After a timeout or `dismiss()`.
    var onClosed: () -> Void = {}
    var isPresented: Bool { alertID != nil }

    init(pet: PetController) {
        self.pet = pet
    }

    /// Shows the bubble for `alertID`, summoning the pet first if it isn't
    /// here yet. False when the pet can't show (0021 §8): secure input. A
    /// bubble already up always moves on, so it never keeps a handled alert.
    @discardableResult
    func present(alertID: String, content: SummonBubbleContent, fades: Bool) -> Bool {
        if !isPresented {
            guard !IsSecureEventInputEnabled() else { return false }
            let pointer = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
            else { return false }
            let size = PetPanel.spriteSize
            petOrigin = NSPoint(x: (screen.frame.midX - size.width / 2).rounded(),
                                y: (screen.frame.midY - size.height / 2 - 60).rounded())
            self.fades = fades
            showDim(on: screen)
            pet.beginSummon(at: petOrigin, fades: fades)
        }
        self.alertID = alertID
        bubble.show(SummonBubbleView(alertID: alertID, content: content, actions: actions),
                    above: NSRect(origin: petOrigin, size: PetPanel.spriteSize))
        restartTimeout()
        return true
    }

    func dismiss() {
        guard isPresented else { return }
        alertID = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        bubble.orderOut(nil)
        dim?.orderOut(nil)
        dim = nil
        pet.endSummon(fades: fades)
        onClosed()
    }

    /// Unanswered for 60 s: the pet goes home and the dim lifts; the alert
    /// stays pending (a timeout is not handled, 0021 §4).
    private func restartTimeout() {
        timeoutTimer?.invalidate()
        let timer = Timer(timeInterval: Self.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    private func showDim(on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Under the pet and the bubble (both .statusBar), over everything else.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = NSColor.black.withAlphaComponent(0.18)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        dim = window
    }
}
