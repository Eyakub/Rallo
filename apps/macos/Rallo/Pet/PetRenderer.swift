import AppKit
import QuartzCore

/// Core Animation sprite view. The pose and which one-off motion to play
/// come from the Rust reducer (docs/decisions/0006); this view owns only
/// timing and rendering. All motion is transform-only, capped at 12 fps,
/// and stops entirely when the pet is hidden, occluded, paused, or the
/// user prefers reduced motion.
final class PetView: NSView {
    enum Pose: String {
        /// Drawn without its eyes; `eyes` adds them so they can move.
        case idle = "pet-idle-base"
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
    /// Furthest lean toward the cursor, in radians (about 5.7°).
    private static let maxLean: CGFloat = 0.1
    /// Between the idle pose's eyes, in view points (from the art).
    private static let eyesCenter = CGPoint(x: 55, y: 68)
    /// Furthest the eyes move toward the cursor, in points.
    private static let maxLook = CGSize(width: 2, height: 1.5)
    /// Holds the hover lean, so it composes with the sprite's own motion.
    private let leanLayer = CALayer()
    private let sprite = CALayer()
    /// The idle pose's eyes (scripts/split-pet-eyes.py), inside the sprite
    /// so they breathe, tilt, and lean with it.
    private let eyes = CALayer()
    private let badge = CAShapeLayer()
    private let badgeText = CATextLayer()
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false
    private var ambientTimer: Timer?
    private var momentWork: DispatchWorkItem?
    private var steadyPose: Pose = .idle
    private var ambientPose: Pose?
    private var motionAllowed = false
    private var leanAngle: CGFloat = 0
    private var lookOffset = CGSize.zero
    private var label = "Rallo"

    var onClick: () -> Void = {}
    var onDragEnded: (NSPoint) -> Void = { _ in }
    var menuProvider: () -> NSMenu? = { nil }

    /// Whether ambient motion may run at all (visible, not occluded, display
    /// awake); set by the controller.
    var canAnimate = false {
        didSet {
            guard canAnimate != oldValue else { return }
            rescheduleAmbient()
            if !canAnimate { resetLean() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // Rotations and hops pivot on the feet, not the middle of the art.
        leanLayer.anchorPoint = CGPoint(x: 0.5, y: 0.08)
        leanLayer.frame = bounds
        leanLayer.actions = ["transform": NSNull()]
        layer?.addSublayer(leanLayer)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0.08)
        sprite.frame = leanLayer.bounds
        sprite.contentsGravity = .resizeAspect
        sprite.contents = Self.image(for: steadyPose)
        sprite.actions = ["contents": NSNull(), "transform": NSNull()]
        leanLayer.addSublayer(sprite)
        eyes.frame = sprite.bounds
        eyes.contentsGravity = .resizeAspect
        eyes.contents = Bundle.main.image(forResource: "pet-idle-eyes")
        eyes.actions = ["transform": NSNull(), "hidden": NSNull()]
        sprite.addSublayer(eyes)
        // Local to this view: the pet notices the cursor only while it's
        // over the pet. No global mouse monitoring (spec §2).
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                              .inVisibleRect], owner: self))

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
        motionAllowed = animate
        if !animate || pose == .sleep { resetLean() }

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
        resetLean()
    }

    private func show(_ pose: Pose, fade: Bool) {
        eyes.isHidden = pose != .idle
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

    /// "Occasional small movement": one short motion every 12–25 s, only
    /// while idle or asleep and allowed to animate. Asleep, two slow breaths;
    /// awake, a breath or a look around.
    private func rescheduleAmbient() {
        ambientTimer?.invalidate()
        ambientTimer = nil
        guard canAnimate, ambientPose != nil else { return }
        let timer = Timer(timeInterval: .random(in: 12...25), repeats: false) { [weak self] _ in
            guard let self, self.canAnimate, let pose = self.ambientPose else { return }
            if pose == .sleep {
                self.add(keyframes: "transform.scale.y", values: [1, 1.045, 1, 1.045, 1], duration: 5)
            } else if Bool.random() {
                self.add(keyframes: "transform.scale.y", values: [1, 1.04, 1], duration: 2.4)
            } else {
                self.add(keyframes: "transform.rotation.z", values: [0, 0.07, -0.045, 0], duration: 1.8)
            }
            self.rescheduleAmbient()
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        ambientTimer = timer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        sprite.contentsScale = scale
        eyes.contentsScale = scale
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
        } else if event.clickCount < 2 {
            // A double-click is one request, not open-then-close.
            onClick()
        }
    }

    override func mouseEntered(with event: NSEvent) { leanToward(event) }
    override func mouseMoved(with event: NSEvent) { leanToward(event) }
    override func mouseExited(with event: NSEvent) {
        lean(to: 0)
        look(toward: .zero)
    }

    /// Leans toward the cursor's side of the pet, pivoting on its feet, and
    /// turns the eyes toward it.
    private func leanToward(_ event: NSEvent) {
        guard canAnimate, motionAllowed, steadyPose != .sleep else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clamp = { (value: CGFloat) in max(-1, min(1, value)) }
        lean(to: -clamp((point.x - bounds.midX) / (bounds.width / 2)) * Self.maxLean)
        look(toward: CGSize(width: clamp((point.x - Self.eyesCenter.x) / 40) * Self.maxLook.width,
                            height: clamp((point.y - Self.eyesCenter.y) / 40) * Self.maxLook.height))
    }

    private func lean(to angle: CGFloat) {
        guard abs(angle - leanAngle) > 0.004 else { return }
        leanAngle = angle
        ease(leanLayer, "transform.rotation.z", to: angle)
    }

    private func look(toward offset: CGSize) {
        guard hypot(offset.width - lookOffset.width, offset.height - lookOffset.height) > 0.1 else { return }
        lookOffset = offset
        ease(eyes, "transform.translation", to: NSValue(size: offset))
    }

    private func ease(_ layer: CALayer, _ keyPath: String, to value: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.preferredFrameRateRange = Self.frameRate
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(animation, forKey: keyPath)
    }

    /// Straight up, eyes ahead, at once: used when motion stops being allowed.
    private func resetLean() {
        leanLayer.removeAllAnimations()
        eyes.removeAllAnimations()
        leanAngle = 0
        lookOffset = .zero
        leanLayer.setValue(0, forKeyPath: "transform.rotation.z")
        eyes.setValue(NSValue(size: .zero), forKeyPath: "transform.translation")
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityHelp() -> String? { "Opens or closes your notes" }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
