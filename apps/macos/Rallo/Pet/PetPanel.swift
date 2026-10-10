import AppKit

/// Shows, hides, and positions the pet; reports clicks and finished drags.
@MainActor
final class PetController {
    private let panel = PetPanel()
    private let petView: PetView
    private var observers: [NSObjectProtocol] = []
    private var displaysAsleep = false
    private var savedOrigin: NSPoint?
    private var summon = PetSummonState()
    private var hopTimer: Timer?
    /// Bumped by every show, hide, hop and fade so a stale completion does nothing.
    private var animation = 0
    /// A post-summon hide fade is pending: the panel is visible but the user wants it hidden.
    private var hidingAfterSummon = false

    var onClick: () -> Void = {}
    var onMoved: (NSPoint) -> Void = { _ in }
    var contextMenu: () -> NSMenu? = { nil }

    init() {
        petView = PetView(frame: NSRect(origin: .zero, size: PetPanel.spriteSize))
        panel.contentView = petView
        petView.onClick = { [weak self] in self?.onClick() }
        petView.onDragEnded = { [weak self] origin in
            guard let self, self.summon.savesDrag else { return }
            self.onMoved(origin)
        }
        petView.menuProvider = { [weak self] in self?.contextMenu() }
        observe()
    }

    /// The user's choice: a hidden pet shown only for a summon still reads as hidden.
    var isVisible: Bool { summon.isVisible(panelVisible: panel.isVisible) }
    var frame: NSRect { panel.frame }
    var window: NSWindow { panel }

    /// Orders the pet in without activating Rallo.
    func show(savedOrigin: NSPoint?) {
        self.savedOrigin = savedOrigin
        guard !summon.isActive else { return summon.userSetVisible(true) }
        cancelAnimation()
        panel.setFrameOrigin(PetPlacementPolicy.resolve(saved: savedOrigin, size: PetPanel.spriteSize))
        panel.orderFrontRegardless()
        updateCanAnimate()
    }

    /// Hidden means zero animation frames, not merely an invisible window.
    func hide() {
        guard !summon.isActive else { return summon.userSetVisible(false) }
        cancelAnimation()
        hidePanel()
    }

    func move(savedOrigin: NSPoint?) {
        self.savedOrigin = savedOrigin
        guard summon.followsPlacement else { return }
        panel.setFrameOrigin(PetPlacementPolicy.resolve(saved: savedOrigin, size: PetPanel.spriteSize))
    }

    /// 0021 §3: the pet comes to `origin` for an alert, hopping (or fading,
    /// under Reduce Motion). Its saved placement and Show/Hide stay untouched.
    func beginSummon(at origin: NSPoint, fades: Bool) {
        let showing = panel.isVisible && !hidingAfterSummon
        summon.begin(panelVisible: showing)
        if showing && !fades { hop(to: origin) } else { fade(to: origin) }
    }

    /// Sends the pet home (its saved placement, as now resolved), or hides it again.
    func endSummon(fades: Bool) {
        switch summon.end() {
        case .returnHome?:
            let home = PetPlacementPolicy.resolve(saved: savedOrigin, size: PetPanel.spriteSize)
            if fades { fade(to: home) } else { hop(to: home) }
        case .hide?:
            fade(to: panel.frame.origin, thenHide: true)
        case nil:
            break
        }
    }

    /// Supersedes any hop or fade in flight and leaves the pet fully opaque.
    private func cancelAnimation() {
        animation += 1
        hopTimer?.invalidate()
        hidingAfterSummon = false
        panel.alphaValue = 1
    }

    private func hidePanel() {
        petView.stopAll()
        petView.canAnimate = false
        panel.orderOut(nil)
    }

    /// A short hop along an arc, about 0.6 s (0021 §3).
    private func hop(to target: NSPoint, duration: TimeInterval = 0.6) {
        cancelAnimation()
        let token = animation
        let start = panel.frame.origin
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.animation == token else { return timer.invalidate() }
                let t = min(1, (CACurrentMediaTime() - began) / duration)
                let eased = t * t * (3 - 2 * t)
                let lift = 320 * t * (1 - t)  // peaks 80 pt above the straight line
                self.panel.setFrameOrigin(NSPoint(x: start.x + (target.x - start.x) * eased,
                                                  y: start.y + (target.y - start.y) * eased + lift))
                if t >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hopTimer = timer
    }

    /// Reduce Motion (0021 §8): fade out where it is, fade in where it goes.
    private func fade(to origin: NSPoint, thenHide: Bool = false) {
        cancelAnimation()
        let token = animation
        hidingAfterSummon = thenHide
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = panel.isVisible ? 0.2 : 0
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animation == token else { return }
                if thenHide {
                    self.hidingAfterSummon = false
                    self.hidePanel()
                    self.panel.alphaValue = 1
                    return
                }
                self.panel.setFrameOrigin(origin)
                self.panel.orderFrontRegardless()
                self.updateCanAnimate()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    self.panel.animator().alphaValue = 1
                }
            }
        })
    }

    func apply(pose: PetView.Pose, moment: PetView.Moment, animate: Bool, ambient: Bool, dueCount: Int,
               agentsWaiting: Int, label: String, done: @escaping () -> Void) {
        petView.apply(pose: pose, moment: moment, animate: animate, ambient: ambient, dueCount: dueCount,
                      agentsWaiting: agentsWaiting, label: label, done: done)
    }

    /// Voice typing (0013): the listening pose while dictating, a nod per phrase.
    func setListening(_ on: Bool) { petView.setListening(on) }
    func heard() { petView.heard() }

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
                guard let self, self.panel.isVisible, self.summon.followsPlacement else { return }
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
