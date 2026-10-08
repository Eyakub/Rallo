import SwiftUI
import XCTest

/// 0019 §10: tags in row text are tinted from the core's UTF-16 ranges.
final class TagTintTests: XCTestCase {
    /// The substrings that carry a colour, in order.
    private func tinted(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.foregroundColor != nil }.map { String(text[$0.range].characters) }
    }

    func testTintsEachRangeAndNothingElse() {
        let text = "fix #bug and #q4_plan today"
        let ranges = [
            TagRange(utf16Start: 4, utf16Len: 4, name: "bug"),
            TagRange(utf16Start: 13, utf16Len: 8, name: "q4_plan"),
        ]
        XCTAssertEqual(tinted(TagTint.attributed(text, ranges: ranges, size: 14)), ["#bug", "#q4_plan"])
        XCTAssertEqual(String(TagTint.attributed(text, ranges: ranges, size: 14).characters), text)
    }

    func testNoRangesIsPlainText() {
        XCTAssertEqual(tinted(TagTint.attributed("nothing here", ranges: [], size: 14)), [])
    }

    func testEmojiBeforeATagCountsAsTwoUTF16UnitsEach() {
        // "🦊🦊 #bug": two surrogate pairs and a space, so the tag starts at 5.
        let text = "🦊🦊 #bug"
        let tint = TagTint.attributed(text, ranges: [TagRange(utf16Start: 5, utf16Len: 4, name: "bug")], size: 14)
        XCTAssertEqual(tinted(tint), ["#bug"])
    }

    func testBanglaTagWithVowelSigns() {
        // "কাজ" is three UTF-16 units; "কাজ #কাজ শেষ": the tag starts at 4 and is 4 long.
        let text = "কাজ #কাজ শেষ"
        let tint = TagTint.attributed(text, ranges: [TagRange(utf16Start: 4, utf16Len: 4, name: "কাজ")], size: 14)
        XCTAssertEqual(tinted(tint), ["#কাজ"])
    }

    func testATagAtTheStartAndBeforePunctuation() {
        let text = "#bug, then #ship."
        let ranges = [
            TagRange(utf16Start: 0, utf16Len: 4, name: "bug"),
            TagRange(utf16Start: 11, utf16Len: 5, name: "ship"),
        ]
        XCTAssertEqual(tinted(TagTint.attributed(text, ranges: ranges, size: 14)), ["#bug", "#ship"])
    }

    func testStaleRangesAreIgnoredNotCrashed() {
        // Out of bounds, running past the end, and starting inside an emoji's surrogate pair.
        let text = "🦊#bug"
        let ranges = [
            TagRange(utf16Start: 50, utf16Len: 4, name: "x"),
            TagRange(utf16Start: 2, utf16Len: 40, name: "y"),
            TagRange(utf16Start: 1, utf16Len: 5, name: "z"),
            TagRange(utf16Start: 2, utf16Len: 0, name: "empty"),
        ]
        let tint = TagTint.attributed(text, ranges: ranges, size: 14)
        XCTAssertEqual(tinted(tint), [])
        XCTAssertEqual(String(tint.characters), text)
    }

    func testAskingTheCoreTintsTheRightCharactersAfterEmojiAndBangla() {
        XCTAssertEqual(tinted(TagTint.attributed("🦊 ship #Bug- now", size: 14)), ["#Bug"])
        XCTAssertEqual(tinted(TagTint.attributed("কাজ শেষ #কাজ", size: 14)), ["#কাজ"])
        XCTAssertEqual(tinted(TagTint.attributed("Review PR #482, C#, a#b", size: 14)), [])
    }
}
