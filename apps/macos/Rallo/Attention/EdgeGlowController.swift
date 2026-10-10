import AppKit

/// The edge glow (0021 §3): a rust pulse around every display, three times
/// in about 5 s, or one steady fade under Reduce Motion. Click-through.
@MainActor
final class EdgeGlowController {
    private var windows: [NSWindow] = []
    private var generation = 0

    func pulse(fades: Bool) {
        stop()
        generation += 1
        windows = NSScreen.screens.map(Self.window(on:))
        windows.forEach { $0.orderFrontRegardless() }
        if fades {
            step(generation, values: [1, 1, 0], durations: [0.8, 1.5, 0.8])
        } else {
            step(generation, values: [1, 0, 1, 0, 1, 0], durations: [0.6, 1.0, 0.6, 1.0, 0.6, 1.0])
        }
    }

    func stop() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func step(_ current: Int, values: [CGFloat], durations: [TimeInterval]) {
        guard current == generation else { return }
        guard let value = values.first, let duration = durations.first else { return stop() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            windows.forEach { $0.animator().alphaValue = value }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.step(current, values: Array(values.dropFirst()), durations: Array(durations.dropFirst()))
            }
        })
    }

    private static func window(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = EdgeGlowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.setFrame(screen.frame, display: false)
        return window
    }
}

/// A soft rust band along the display's edges, fading inwards.
private final class EdgeGlowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let steps = 24
        for index in 0..<steps {
            let fraction = CGFloat(index) / CGFloat(steps)
            Theme.rustNS.withAlphaComponent(0.6 * (1 - fraction)).setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: CGFloat(index) * 2 + 1, dy: CGFloat(index) * 2 + 1))
            path.lineWidth = 2
            path.stroke()
        }
    }
}
