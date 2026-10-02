import XCTest

final class WhisperVoiceTests: XCTestCase {
    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16000)).map { 0.3 * sin(Float($0) * 0.1) }
    }

    private func quiet(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16000)) }

    func testSilenceNeverCuts() {
        var seg = SpeechSegmenter()
        XCTAssertEqual(seg.append(quiet(30)), [])
        XCTAssertNil(seg.current)
        XCTAssertNil(seg.flush())
    }

    func testSpeechThenSilenceCutsOnce() {
        var seg = SpeechSegmenter()
        var cuts = seg.append(quiet(1) + tone(1))
        XCTAssertEqual(cuts, [])
        XCTAssertNotNil(seg.current)
        cuts = seg.append(quiet(0.5))
        XCTAssertEqual(cuts, [])
        cuts = seg.append(quiet(0.5))
        XCTAssertEqual(cuts.count, 1)
        XCTAssertLessThanOrEqual(cuts[0].lowerBound, 16000)
        XCTAssertGreaterThanOrEqual(cuts[0].upperBound, 32000)
        XCTAssertEqual(seg.append(quiet(3)), [])
        XCTAssertNil(seg.flush())
    }

    func testBlipIsDropped() {
        var seg = SpeechSegmenter()
        XCTAssertEqual(seg.append(tone(0.1) + quiet(2)), [])
        XCTAssertNil(seg.flush())
    }

    func testCapAtTwentySeconds() {
        var seg = SpeechSegmenter()
        let cuts = seg.append(tone(25))
        XCTAssertEqual(cuts.count, 1)
        XCTAssertGreaterThanOrEqual(cuts[0].count, 20 * 16000)
        XCTAssertLessThan(cuts[0].count, 20 * 16000 + SpeechSegmenter.frame)
    }

    func testFlushReturnsSpeechInProgress() {
        var seg = SpeechSegmenter()
        XCTAssertEqual(seg.append(tone(1)), [])
        let range = seg.flush()
        XCTAssertNotNil(range)
        XCTAssertGreaterThan(range?.count ?? 0, 12000)
        XCTAssertNil(seg.flush())
    }

    func testCleanRemovesAnnotations() {
        XCTAssertEqual(WhisperText.clean(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(WhisperText.clean("(music)"), "")
        XCTAssertEqual(WhisperText.clean("[BLANK_AUDIO]."), "")
        XCTAssertEqual(WhisperText.clean(" Hello  (laughs) there [x]  world. "), "Hello there world.")
        XCTAssertEqual(WhisperText.clean("আমি ভালো আছি।"), "আমি ভালো আছি।")
    }

    func testStorePaths() {
        let store = WhisperModelStore(home: URL(fileURLWithPath: "/Users/x"))
        let root = "/Users/x/.cache/huggingface/hub/models--ggerganov--whisper.cpp"
        XCTAssertEqual(store.blob.path, "\(root)/blobs/\(WhisperModelStore.sha256)")
        XCTAssertEqual(store.partial.path, store.blob.path + ".incomplete")
        XCTAssertEqual(store.snapshot.path, "\(root)/snapshots/\(WhisperModelStore.commit)/ggml-large-v3-turbo.bin")
        XCTAssertEqual(store.refsMain.path, "\(root)/refs/main")
        XCTAssertEqual(WhisperModelStore.snapshotLinkTarget, "../../blobs/\(WhisperModelStore.sha256)")
    }
}
