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
        XCTAssertEqual(WhisperText.clean("Hello there (laughs"), "Hello there")
        XCTAssertEqual(WhisperText.clean("[BLANK_AUDIO]."), "")
        XCTAssertEqual(WhisperText.clean(" Hello  (laughs) there [x]  world. "), "Hello there world.")
        XCTAssertEqual(WhisperText.clean("আমি ভালো আছি।"), "আমি ভালো আছি।")
    }

    func testStorePaths() {
        let store = WhisperModelStore(home: URL(fileURLWithPath: "/Users/x"))
        let root = "/Users/x/.cache/huggingface/hub/models--ggerganov--whisper.cpp"
        XCTAssertEqual(store.blob.path, "\(root)/blobs/\(store.kind.sha256)")
        XCTAssertEqual(store.partial.path, store.blob.path + ".rallo-download")
        XCTAssertEqual(store.snapshot.path, "\(root)/snapshots/\(WhisperModelStore.commit)/ggml-large-v3-turbo.bin")
        XCTAssertEqual(store.kind, .turbo16)
        XCTAssertEqual(store.refsMain.path, "\(root)/refs/main")
        XCTAssertEqual(store.snapshotLinkTarget, "../../blobs/\(store.kind.sha256)")
    }

    func testEightBitTurboFile() {
        let kind = WhisperModelKind.turbo8
        XCTAssertEqual(kind.fileName, "ggml-large-v3-turbo-q8_0.bin")
        XCTAssertEqual(kind.size, 874_188_075)
        XCTAssertEqual(kind.sha256, "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1")
        XCTAssertEqual(kind.displayName, "Large-v3 turbo · 8-bit · all languages · 874 MB")
        XCTAssertEqual(WhisperModelKind.turbo16.displayName, "Large-v3 turbo · 16-bit · all languages · 1.6 GB")
        XCTAssertEqual(WhisperModelKind.smallEnglish.displayName, "Small · English only · 190 MB")
        XCTAssertEqual(Set(WhisperModelKind.allCases.map(\.sha256)).count, 3)
    }

    func testDefaultKindKeepsAnInstalledSixteenBit() {
        XCTAssertEqual(WhisperModelKind.defaultKind(turbo16Installed: true), .turbo16)
        XCTAssertEqual(WhisperModelKind.defaultKind(turbo16Installed: false), .turbo8)
    }

    func testSmallEnglishStoreSharesTheCache() {
        let store = WhisperModelStore(home: URL(fileURLWithPath: "/Users/x"), kind: .smallEnglish)
        let root = "/Users/x/.cache/huggingface/hub/models--ggerganov--whisper.cpp"
        XCTAssertEqual(store.blob.path, "\(root)/blobs/bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30")
        XCTAssertEqual(store.snapshot.path, "\(root)/snapshots/\(WhisperModelStore.commit)/ggml-small.en-q5_1.bin")
        XCTAssertEqual(WhisperModelKind.smallEnglish.size, 190_098_681)
        XCTAssertEqual(WhisperModelKind.smallEnglish.languages, ["en"])
        XCTAssertNil(WhisperModelKind.turbo16.languages)
        XCTAssertEqual(WhisperModelKind.smallEnglish.url.lastPathComponent, "ggml-small.en-q5_1.bin")
    }

    // MARK: phantom-text guard

    /// Noise of a given level: a deterministic pseudo-random sequence.
    private func noise(_ seconds: Double, level: Float) -> [Float] {
        var x: UInt32 = 12345
        return (0..<Int(seconds * 16000)).map { _ in
            x = x &* 1_664_525 &+ 1_013_904_223
            return level * (Float(x >> 8) / Float(1 << 24) * 2 - 1)
        }
    }

    func testSilenceAndSteadyNoiseAreNotSpeech() {
        XCTAssertFalse(WhisperText.containsSpeech(quiet(2)))
        XCTAssertFalse(WhisperText.containsSpeech(noise(2, level: 0.02)))
    }

    func testToneBurstOverNoiseIsSpeech() {
        let samples = noise(0.8, level: 0.003) + tone(0.6).map { $0 * 0.5 } + noise(0.8, level: 0.003)
        XCTAssertTrue(WhisperText.containsSpeech(samples))
    }

    /// A segment as `SpeechSegmenter` cuts it: only 90 ms of quiet on each side.
    func testShortWordSegmentIsTranscribed() {
        let word = noise(0.09, level: 0.003) + tone(0.4).map { $0 * 0.5 } + noise(0.09, level: 0.003)
        XCTAssertTrue(WhisperText.worthTranscribing(word))
        XCTAssertFalse(WhisperText.containsSpeech(word), "the whole-clip check alone would drop this word")
    }

    func testLongSteadyNoiseSegmentIsNotTranscribed() {
        XCTAssertFalse(WhisperText.worthTranscribing(noise(3, level: 0.02)))
    }

    func testLongSpeechSegmentIsTranscribed() {
        let syllable = tone(0.25).map { $0 * 0.5 } + noise(0.15, level: 0.003)
        XCTAssertTrue(WhisperText.worthTranscribing(Array(repeating: syllable, count: 8).flatMap { $0 }))
    }

    func testFewerThanThreeFramesIsNotSpeech() {
        XCTAssertFalse(WhisperText.containsSpeech(tone(0.25)))
    }

    func testStockPhraseOnShortAudioIsDropped() {
        XCTAssertTrue(WhisperText.isPhantom("Thank you.", seconds: 1.2))
        XCTAssertTrue(WhisperText.isPhantom(" Thanks for watching! ", seconds: 1.2))
        XCTAssertTrue(WhisperText.isPhantom("You", seconds: 0.5))
    }

    func testStockPhraseOnLongAudioIsKept() {
        XCTAssertFalse(WhisperText.isPhantom("Thank you.", seconds: 3))
    }

    func testLongerSentenceIsKept() {
        XCTAssertFalse(WhisperText.isPhantom("Thank you so much", seconds: 1))
    }
}
