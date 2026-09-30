import AppKit
import QuartzCore

/// Core Animation sprite view. The pose and which one-off motion to play
/// come from the Rust reducer (docs/decisions/0006); this view owns only
/// timing and rendering. All motion is transform-only, capped at 12 fps,
/// and stops entirely when the pet is hidden, occluded, paused, or the
/// user prefers reduced motion.
final class PetView: NSView {
    enum Pose: String {
        case idle = "pet-idle"
        case sleep = "pet-sleep"
        case nudge = "pet-nudge"
        case celebrate = "pet-celebrate"
    }

    /// One-off motion answering something that just happened.
    enum Moment {
        case none
        /// A reminder just became due.
        case attention
        /// Something was marked done.
        case celebrate
        /// Something was saved.
        case acknowledge
    }

    private static let dragThreshold: CGFloat = 3
    private static let frameRate = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 12)
    private let sprite = CALayer()
    private let badge = CAShapeLayer()
    private let badgeText = CATextLayer()
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false
    private var ambientTimer: Timer?
    private var momentWork: DispatchWorkItem?
    private var steadyPose: Pose = .idle
    private var ambientPose: Pose?
    private var label = "Rallo"

    var onClick: () -> Void = {}
    var onDragEnded: (NSPoint) -> Void = { _ in }
    var menuProvider: () -> NSMenu? = { nil }

    /// Whether ambient motion may run at all (visible, not occluded, display
    /// awake); set by the controller.
    var canAnimate = false {
        didSet { if canAnimate != oldValue { rescheduleAmbient() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // Rotations and hops pivot on the feet, not the middle of the art.
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0.08)
        sprite.frame = bounds
        sprite.contentsGravity = .resizeAspect
        sprite.contents = Self.image(for: steadyPose)
        sprite.actions = ["contents": NSNull(), "transform": NSNull()]
        layer?.addSublayer(sprite)

        let diameter: CGFloat = 20
        badge.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil)
        badge.fillColor = NSColor(hex: 0xB4501F).cgColor
        badge.strokeColor = NSColor.white.cgColor
        badge.lineWidth = 1.5
        badge.frame = CGRect(x: bounds.width - diameter - 22, y: bounds.height - diameter - 10,
                             width: diameter, height: diameter)
        badge.isHidden = true
        badge.actions = ["hidden": NSNull()]
        badgeText.frame = CGRect(x: 0, y: 3, width: diameter, height: 14)
        badgeText.alignmentMode = .center
        badgeText.fontSize = 11
        badgeText.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        badgeText.foregroundColor = NSColor.white.cgColor
        badge.addSublayer(badgeText)
        layer?.addSublayer(badge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static var cache: [Pose: NSImage] = [:]

    private static func image(for pose: Pose) -> NSImage? {
        if let cached = cache[pose] { return cached }
        let image = Bundle.main.image(forResource: pose.rawValue)
        cache[pose] = image
        return image
    }

    /// Shows `pose` (after `moment`, if any) and calls `done` once the moment
    /// has finished, so the caller can recompute. With `animate` false the
    /// moment is shown as a still pose for the same beat, never as motion.
    func apply(pose: Pose, moment: Moment, animate: Bool, ambient: Bool, dueCount: Int, label: String,
               done: @escaping () -> Void) {
        momentWork?.cancel()
        sprite.removeAllAnimations()
        self.label = label
        toolTip = label
        setBadge(dueCount)
        steadyPose = pose
        ambientPose = ambient ? pose : nil

        let (momentPose, duration): (Pose, TimeInterval) = switch moment {
        case .none: (pose, 0)
        case .attention: (.nudge, 0.9)
        case .celebrate: (.celebrate, 1.6)
        case .acknowledge: (pose, 0.45)
        }
        show(momentPose, fade: animate)
        if animate { play(moment) }
        guard duration > 0 else {
            rescheduleAmbient()
            done()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.show(self.steadyPose, fade: animate)
            self.rescheduleAmbient()
            done()
        }
        momentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stopAll() {
        momentWork?.cancel()
        ambientTimer?.invalidate()
        ambientTimer = nil
        sprite.removeAllAnimations()
    }

    private func show(_ pose: Pose, fade: Bool) {
        guard sprite.contents as AnyObject? !== Self.image(for: pose) else { return }
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.18
            sprite.add(transition, forKey: "pose")
        }
        sprite.contents = Self.image(for: pose)
    }

    private func setBadge(_ count: Int) {
        badge.isHidden = count == 0
        badgeText.string = count > 9 ? "9+" : "\(count)"
        badgeText.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: Motion

    private func play(_ moment: Moment) {
        switch moment {
        case .none:
            break
        case .attention:
            add(keyframes: "transform.rotation.z", values: [0, -0.07, 0.07, -0.05, 0.03, 0], duration: 0.9)
        case .celebrate:
            add(keyframes: "transform.translation.y", values: [0, 12, 0, 5, 0], duration: 0.8)
        case .acknowledge:
            add(keyframes: "transform.scale.y", values: [1, 0.95, 1.02, 1], duration: 0.45)
        }
    }

    private func add(keyframes keyPath: String, values: [Double], duration: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = Self.frameRate
        sprite.add(animation, forKey: keyPath)
    }

    /// "Occasional small movement": one short, subtle motion every 25–45 s,
    /// only while idle or asleep and allowed to animate.
    private func rescheduleAmbient() {
        ambientTimer?.invalidate()
        ambientTimer = nil
        guard canAnimate, ambientPose != nil else { return }
        let timer = Timer(timeInterval: .random(in: 25...45), repeats: false) { [weak self] _ in
            guard let self, self.canAnimate, let pose = self.ambientPose else { return }
            if pose == .sleep {
                self.add(keyframes: "transform.scale.y", values: [1, 1.018, 1], duration: 2.4)
            } else {
                self.add(keyframes: "transform.rotation.z", values: [0, 0.025, -0.015, 0], duration: 1.4)
            }
            self.rescheduleAmbient()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        ambientTimer = timer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        sprite.contentsScale = scale
        badge.contentsScale = scale
        badgeText.contentsScale = scale
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.mouse.x
        let dy = now.y - start.mouse.y
        if !dragging && hypot(dx, dy) < Self.dragThreshold { return }
        dragging = true
        window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragging = false }
        guard dragStart != nil else { return }
        if dragging, let window {
            onDragEnded(window.frame.origin)
        } else {
            onClick()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityHelp() -> String? { "Opens your notes" }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
