import AppKit
import SwiftUI

/// Rallo's warm palette with explicit light and dark variants. Views that
/// paint their own background must use these instead of system label
/// colours, which would turn white on a cream background in Dark Mode.
enum Theme {
    static let backgroundTop = Color(light: 0xFFF7EC, dark: 0x2B211C)
    static let backgroundBottom = Color(light: 0xFCE4CE, dark: 0x1C1512)
    static let textPrimary = Color(light: 0x3B2A21, dark: 0xF7EADF)
    static let textSecondary = Color(light: 0x86695A, dark: 0xBCA597)
    static let accent = Color(light: 0xCF6A31, dark: 0xF2935A)
    static let field = Color(light: 0xFFFFFF, lightAlpha: 0.92, dark: 0xFFFFFF, darkAlpha: 0.07)
    static let fieldBorder = Color(light: 0xEBC6A8, dark: 0xFFFFFF, darkAlpha: 0.12)
    static let row = Color(light: 0xFFFFFF, lightAlpha: 0.55, dark: 0xFFFFFF, darkAlpha: 0.04)
    static let rowHighlight = Color(light: 0xCF6A31, lightAlpha: 0.14, dark: 0xF2935A, darkAlpha: 0.18)
    static let error = Color(light: 0xB3261E, dark: 0xFF8A80)

    static var background: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
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
