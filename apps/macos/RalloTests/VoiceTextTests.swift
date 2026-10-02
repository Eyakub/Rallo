import XCTest

final class VoiceTextTests: XCTestCase {
    func testSanitizeNeverKeepsNewlines() {
        let out = VoiceText.sanitize("a\nb\r\nc\td\u{2028}e  f\n\n")
        XCTAssertEqual(out, "a b c d e f ")
        for bad in ["\n", "\r", "\t"] { XCTAssertFalse(out.contains(bad)) }
    }

    func testJoinedSpacing() {
        XCTAssertEqual(VoiceText.joined(previous: nil, next: "hello"), "hello")
        XCTAssertEqual(VoiceText.joined(previous: "hello", next: "world"), " world")
        XCTAssertEqual(VoiceText.joined(previous: "hello ", next: "world"), "world")
        XCTAssertEqual(VoiceText.joined(previous: "hello", next: " world"), " world")
        for p in [".", ",", "!", "?", ";", ":", ")"] {
            XCTAssertEqual(VoiceText.joined(previous: "hello", next: p + "x"), p + "x")
        }
    }

    func testChunksKeepEmojiWholeAndRejoin() {
        let s = "héllo 😀 wörld 👨‍👩‍👧‍👦 done 🇧🇩🇧🇩 end"
        for max in [1, 2, 4, 16] {
            let parts = VoiceText.chunks(s, maxUTF16: max)
            XCTAssertEqual(parts.joined(), s)
            for part in parts where part.count > 1 { XCTAssertLessThanOrEqual(part.utf16.count, max) }
        }
        XCTAssertEqual(VoiceText.chunks("😀😀😀", maxUTF16: 4), ["😀😀", "😀"])
        XCTAssertEqual(VoiceText.chunks(""), [])
    }
}
