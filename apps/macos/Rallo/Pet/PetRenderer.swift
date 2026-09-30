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
        /// Faces for play while asleep (same bodies as sleep and idle).
        case drowsy = "pet-drowsy"
        case content = "pet-content"
        case grumpy = "pet-grumpy"
        /// The saved "got it!" face (idle's body).
        case happy = "pet-happy"
        /// The other end of the nudge's wave (nudge's body).
        case wave = "pet-wave2"
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
    /// A check that pops up where the badge sits when something is saved
    /// (the two never show together: a due pet doesn't acknowledge).
    private let savedMark = CAShapeLayer()
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
    /// The face play is showing over the sleeping pet, and the work that
    /// puts it back to sleep.
    private var playPose: Pose?
    private var playWork: DispatchWorkItem?
    private var stroke = Stroke()
    private var lastStir: TimeInterval = 0
    private var lastPurr: TimeInterval = 0
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
        // Without this the count cross-fades, so a badge appearing shows the
        // stale "0" it kept while hidden.
        badgeText.actions = ["contents": NSNull()]
        badge.addSublayer(badgeText)
        layer?.addSublayer(badge)

        savedMark.path = badge.path
        savedMark.fillColor = NSColor(hex: 0x5E8C4A).cgColor
        savedMark.strokeColor = NSColor.white.cgColor
        savedMark.lineWidth = 1.5
        savedMark.frame = badge.frame
        savedMark.opacity = 0
        let check = CAShapeLayer()
        let tick = CGMutablePath()
        tick.move(to: CGPoint(x: 5.5, y: 10.5))
        tick.addLine(to: CGPoint(x: 8.5, y: 7))
        tick.addLine(to: CGPoint(x: 14.5, y: 13.5))
        check.path = tick
        check.fillColor = nil
        check.strokeColor = NSColor.white.cgColor
        check.lineWidth = 2.2
        check.lineCap = .round
        check.lineJoin = .round
        savedMark.addSublayer(check)
        layer?.addSublayer(savedMark)
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
        endPlay()
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
        case .attention: (.nudge, 2.4)
        case .celebrate: (.celebrate, 1.6)
        case .acknowledge: (.happy, 1.2)
        }
        show(momentPose, fade: animate)
        if animate { play(moment) }
        if moment == .acknowledge { showSavedMark(popping: animate) }
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
        endPlay()
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
            // A startled hop, then the paw waves three times (swapping the
            // two nudge frames) with a sway in time; then still, with the badge.
            add(keyframes: "transform.translation.y", values: [0, 11, 0, 0], duration: 2.4,
                keyTimes: [0, 0.08, 0.17, 1])
            add(keyframes: "transform.rotation.z", values: [0, 0, 0.04, 0, 0.04, 0, 0.04, 0],
                duration: 2.4, keyTimes: [0, 0.2, 0.32, 0.44, 0.56, 0.68, 0.8, 1])
            let wave = CAKeyframeAnimation(keyPath: "contents")
            let frames = [Pose.nudge, .wave].map { Self.image(for: $0) as Any }
            wave.values = [0, 1, 0, 1, 0, 1, 0].map { frames[$0] }
            wave.keyTimes = [0, 0.2, 0.32, 0.44, 0.56, 0.68, 0.8, 1]
            wave.calculationMode = .discrete
            wave.duration = 2.4
            sprite.add(wave, forKey: "wave")
        case .celebrate:
            add(keyframes: "transform.translation.y", values: [0, 12, 0, 5, 0], duration: 0.8)
        case .acknowledge:
            // Crouch, hop, land.
            add(keyframes: "transform.scale.y", values: [1, 0.9, 1.06, 0.95, 1], duration: 0.6)
            add(keyframes: "transform.translation.y", values: [0, 0, 9, 0, 0], duration: 0.6)
        }
    }

    /// Fades the check in, holds it, and fades it out; with motion allowed it
    /// also pops in. Without motion the fade alone still shows the save.
    private func showSavedMark(popping: Bool) {
        savedMark.removeAllAnimations()
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.8, 1]
        let group = CAAnimationGroup()
        group.animations = [fade]
        if popping {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.3, 1.15, 1, 1]
            pop.keyTimes = [0, 0.14, 0.24, 1]
            group.animations?.append(pop)
        }
        group.duration = 1.4
        group.preferredFrameRateRange = Self.frameRate
        savedMark.add(group, forKey: "saved")
    }

    private func add(keyframes keyPath: String, values: [Double], duration: TimeInterval,
                     keyTimes: [Double]? = nil) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        if let keyTimes {
            // Ease each step on its own, not the whole timeline.
            animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
            animation.timingFunctions = Array(repeating: ease, count: values.count - 1)
        } else {
            animation.timingFunction = ease
        }
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
            guard let self, self.canAnimate, self.playPose == nil, let pose = self.ambientPose else { return }
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
        savedMark.contentsScale = scale
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

    override func mouseEntered(with event: NSEvent) {
        stroke = Stroke()
        if asleep, playAllowed, event.timestamp - lastStir > 6 {
            lastStir = event.timestamp
            showPlay(.drowsy, for: 1.6)
            add(keyframes: "transform.scale.y", values: [1, 1.06, 0.98, 1], duration: 1.2)
            add(keyframes: "transform.rotation.z", values: [0, 0.03, -0.03, 0], duration: 1.2)
        }
        leanToward(event)
    }

    override func mouseMoved(with event: NSEvent) {
        play(with: event)
        leanToward(event)
    }

    override func mouseExited(with event: NSEvent) {
        lean(to: 0)
        look(toward: .zero)
    }

    /// Leans toward the cursor's side of the pet, pivoting on its feet, and
    /// turns the eyes toward it.
    private func leanToward(_ event: NSEvent) {
        guard playAllowed, awake else { return }
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

    // MARK: Play (asleep)

    private var playAllowed: Bool { canAnimate && motionAllowed }
    /// Asleep with no play face showing.
    private var asleep: Bool { steadyPose == .sleep && playPose == nil }
    /// Up, whether by the reducer's pose or woken by a tickle.
    private var awake: Bool { steadyPose != .sleep || playPose == .idle || playPose == .grumpy }

    /// Slow strokes back and forth pet it; a fast jiggle tickles it awake,
    /// and tickling it again while it's up makes it grumpy. Presentation
    /// only: the reducer's pose is untouched (0006).
    private func play(with event: NSEvent) {
        guard playAllowed, steadyPose == .sleep else { return }
        let x = convert(event.locationInWindow, from: nil).x
        guard let turn = stroke.add(x: x, at: event.timestamp) else { return }
        if stroke.turns(fasterThan: 500, within: 1.2, now: turn) >= 3 {
            stroke = Stroke()
            if awake {
                showPlay(.grumpy, for: 2)
                add(keyframes: "transform.scale.x", values: [1, 1.05, 1], duration: 0.4)
            } else {
                showPlay(.idle, for: 4)
                add(keyframes: "transform.translation.y", values: [0, 8, 0], duration: 0.4)
            }
        } else if !awake, turn - lastPurr > 2.5, stroke.turns(slowerThan: 400, within: 3, now: turn) >= 2 {
            lastPurr = turn
            stroke = Stroke()
            showPlay(.content, for: 2.2)
            add(keyframes: "transform.scale.y", values: [1, 0.94, 1.04, 0.98, 1], duration: 0.9)
        }
    }

    /// Shows `pose` for `seconds`, then settles back into the steady pose.
    private func showPlay(_ pose: Pose, for seconds: TimeInterval) {
        playWork?.cancel()
        playPose = pose
        show(pose, fade: true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.endPlay()
            self.lean(to: 0)
            self.look(toward: .zero)
            self.show(self.steadyPose, fade: true)
            self.add(keyframes: "transform.scale.y", values: [1, 0.95, 1], duration: 0.5)
        }
        playWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func endPlay() {
        playWork?.cancel()
        playWork = nil
        playPose = nil
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
