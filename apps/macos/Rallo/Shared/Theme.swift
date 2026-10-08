import AppKit
import SwiftUI

/// Rallo's palette, drawn from the red panda itself, with explicit light and
/// dark variants. Views that paint their own background must use these
/// instead of system label colours, which turn white in Dark Mode.
enum Theme {
    // Surfaces: warm white by day, bamboo-forest night by dark.
    static let surfaceTop = Color(light: 0xFCF8F5, dark: 0x221A16)
    static let surfaceBottom = Color(light: 0xF8EDE4, dark: 0x1A1411)
    // Paw ink / belly cream.
    static let ink = Color(light: 0x2B1A13, dark: 0xF5E8DC)
    // Bark: secondary text (≥ 4.5:1 on both surfaces).
    static let bark = Color(light: 0x7D5F50, dark: 0xB59C8D)
    // Fur rust: the accent. Lighter ember on dark for contrast.
    static let rust = Color(light: 0xB4501F, dark: 0xF08A4B)
    // Bamboo: completion.
    static let bamboo = Color(light: 0x5E8C4A, dark: 0x8DBF74)
    static let field = Color(light: 0xFFFFFF, dark: 0xFFFFFF, darkAlpha: 0.06)
    static let fieldStroke = Color(light: 0xE8D6C8, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let hover = Color(light: 0x2B1A13, lightAlpha: 0.045, dark: 0xF5E8DC, darkAlpha: 0.06)
    static let divider = Color(light: 0x2B1A13, lightAlpha: 0.14, dark: 0xF5E8DC, darkAlpha: 0.12)
    static let toast = Color(light: 0x2B1A13, dark: 0xF5E8DC)
    static let onToast = Color(light: 0xF5E8DC, dark: 0x2B1A13)
    // The toast inverts the surface, so its accent inverts too.
    static let toastAccent = Color(light: 0xF08A4B, dark: 0xB4501F)
    static let highlight = Color(light: 0xB4501F, lightAlpha: 0.10, dark: 0xF08A4B, darkAlpha: 0.14)
    // The folder dropdown (0019 §10) and the dialog's backdrop.
    static let menu = Color(light: 0xFAF6F3, lightAlpha: 0.98, dark: 0x2E2622, darkAlpha: 0.98)
    static let menuStroke = Color(light: 0x2B1A13, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.14)
    static let scrim = Color(light: 0x2B1A13, lightAlpha: 0.12, dark: 0x000000, darkAlpha: 0.40)
    // The dialog card: a step lighter than the Dark scrim so its edge reads.
    static let card = Color(light: 0xFCF8F5, dark: 0x2A211C)
    // Text on rust fills: white fails contrast on the lighter dark-mode rust.
    static let onRust = Color(light: 0xFFFFFF, dark: 0x1A1411)
    static let error = Color(light: 0xB3261E, dark: 0xFF8A80)
    // Swipe-action fills carry white labels, so they stay deep in both modes.
    static let swipeDelete = Color(nsColor: NSColor(hex: 0xB3261E))
    static let swipeSoon = Color(nsColor: NSColor(hex: 0xB4501F))
    static let swipeLater = Color(nsColor: NSColor(hex: 0x8C4A2F))
    static let swipeTomorrow = Color(nsColor: NSColor(hex: 0x4E6E8E))

    static var surface: LinearGradient {
        LinearGradient(colors: [surfaceTop, surfaceBottom], startPoint: .top, endPoint: .bottom)
    }

    /// The app's own voice (titles, empty states, buttons).
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
