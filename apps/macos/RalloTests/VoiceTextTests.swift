import XCTest

final class VoiceTextTests: XCTestCase {
    func testSanitizeNeverKeepsNewlines() {
        let out = VoiceText.sanitize("a\nb\r\nc\td\u{2028}e  f\n\n")
        XCTAssertEqual(out, "a b c d e f ")
        for bad in ["\n", "\r", "\t"] { XCTAssertFalse(out.contains(bad)) }
        XCTAssertEqual(VoiceText.sanitize("a\u{0F}b\u{03}c\u{04}d\u{1B}e\u{7F}f\u{85}g"), "a b c d e f g")
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

    func testContextWords() {
        let words = VoiceText.contextWords(userList: " Muhsin, rallo ,\nSDS Manager,, ")
        XCTAssertEqual(words, VoiceText.builtInWords + ["Muhsin", "SDS Manager"])
        XCTAssertEqual(VoiceText.contextWords(userList: ""), VoiceText.builtInWords)
    }

    /// An English word list makes Whisper write Bangla in Latin letters.
    func testNoWordHintForBangla() {
        XCTAssertEqual(VoiceText.prompt(language: "bn", userList: "Muhsin, SDS Manager"), "")
        XCTAssertEqual(VoiceText.prompt(language: "en", userList: ""), VoiceText.builtInWords.joined(separator: ", "))
        XCTAssertTrue(VoiceText.prompt(language: "auto", userList: "Muhsin").hasSuffix("Muhsin"))
    }

    func testTidy() {
        XCTAssertEqual(VoiceText.tidy("set it up like like we said", dropFillers: true), "set it up like we said")
        XCTAssertEqual(VoiceText.tidy("Um, I I think, uh, it works", dropFillers: true), "I think, it works")
        XCTAssertEqual(VoiceText.tidy("it was like, like fine", dropFillers: true), "it was like fine")
        XCTAssertEqual(VoiceText.tidy("call 5 5 5 now"), "call 5 5 5 now")
        XCTAssertEqual(VoiceText.tidy("like we said", after: "set it up like"), "we said")
        XCTAssertEqual(VoiceText.tidy("um", dropFillers: true), "")
        XCTAssertEqual(VoiceText.tidy("The screw is 5 mm long", dropFillers: true), "The screw is 5 mm long")
        XCTAssertEqual(VoiceText.tidy("er kommt um 5 Uhr", dropFillers: false), "er kommt um 5 Uhr")
        XCTAssertEqual(VoiceText.tidy("I said no. No way.", dropFillers: true), "I said no. No way.")
        XCTAssertEqual(VoiceText.tidy("No means no.", after: "I said no.", dropFillers: true), "No means no.")
        XCTAssertEqual(VoiceText.tidy("uh hello", dropFillers: false), "uh hello")
        XCTAssertTrue(VoiceText.fillersApply(language: "en"))
        XCTAssertFalse(VoiceText.fillersApply(language: "de"))
    }
}
