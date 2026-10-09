import AppKit
import SwiftUI
import XCTest


final class ThemeSelectionTests: XCTestCase {
    private func rgba(_ color: NSColor, _ name: NSAppearance.Name) -> [Int] {
        var out: [Int] = []
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
        }
        return out
    }

    func testSelectionTokensResolvePerAppearance() {
        XCTAssertEqual(rgba(NSColor(Theme.selection), .aqua), [0xB4, 0x50, 0x1F, 38])
        XCTAssertEqual(rgba(NSColor(Theme.selection), .darkAqua), [0xF0, 0x8A, 0x4B, 51])
        XCTAssertEqual(rgba(NSColor(Theme.selectionSoft), .aqua), [0xB4, 0x50, 0x1F, 23])
        XCTAssertEqual(rgba(NSColor(Theme.selectionSoft), .darkAqua), [0xF0, 0x8A, 0x4B, 31])
        XCTAssertEqual(rgba(Theme.textSelectionNS, .aqua), [0xB4, 0x50, 0x1F, 56])
        XCTAssertEqual(rgba(Theme.textSelectionNS, .darkAqua), [0xF0, 0x8A, 0x4B, 82])
    }
}
