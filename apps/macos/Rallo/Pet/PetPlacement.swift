import AppKit

/// Default and recovered pet positions, in global AppKit screen coordinates.
enum PetPlacementPolicy {
    static let margin: CGFloat = 24

    /// Bottom-right of the primary display's usable area.
    static func defaultOrigin(size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return .zero }
        let area = screen.visibleFrame
        return NSPoint(x: area.maxX - size.width - margin, y: area.minY + margin)
    }

    /// Keeps a saved position if it still touches a display, clamped fully
    /// into that display's usable area; otherwise falls back to the default.
    static func resolve(saved: NSPoint?, size: NSSize) -> NSPoint {
        guard let saved else { return defaultOrigin(size: size) }
        let rect = NSRect(origin: saved, size: size)
        guard let screen = NSScreen.screens.max(by: { overlap(rect, $0.visibleFrame) < overlap(rect, $1.visibleFrame) }),
              overlap(rect, screen.visibleFrame) > 0 else {
            return defaultOrigin(size: size)
        }
        let area = screen.visibleFrame
        return NSPoint(
            x: min(max(rect.minX, area.minX), area.maxX - size.width),
            y: min(max(rect.minY, area.minY), area.maxY - size.height)
        )
    }

    private static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
