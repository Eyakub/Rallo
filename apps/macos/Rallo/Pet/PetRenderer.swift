import AppKit
import QuartzCore

/// Core Animation sprite view. Swift owns animation timing and rendering;
/// the pet's base state comes from the Rust reducer (M3).
final class PetView: NSView {
    enum Pose: String {
        case idle = "pet-idle"
        case blink = "pet-blink"
        case sleep = "pet-sleep"
    }

    private static let dragThreshold: CGFloat = 3
    private let sprite = CALayer()
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false

    var onClick: () -> Void = {}
    var onDragEnded: (NSPoint) -> Void = { _ in }
    var menuProvider: () -> NSMenu? = { nil }

    var pose: Pose = .idle {
        didSet { if pose != oldValue { sprite.contents = Self.image(for: pose) } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        sprite.frame = bounds
        sprite.contentsGravity = .resizeAspect
        sprite.contents = Self.image(for: pose)
        sprite.actions = ["contents": NSNull()]
        layer?.addSublayer(sprite)
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

    /// M0 renders static frames only; idle motion arrives with the M3 renderer.
    func setAnimating(_ animating: Bool) {
        if !animating { sprite.removeAllAnimations() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sprite.contentsScale = window?.backingScaleFactor ?? 2
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
    override func accessibilityLabel() -> String? { "Rallo" }
    override func accessibilityHelp() -> String? { "Opens your notes" }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
