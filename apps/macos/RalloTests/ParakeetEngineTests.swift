import XCTest

final class ParakeetEngineTests: XCTestCase {
    // Needs the real model; skipped when it isn't installed (locate() may recreate missing snapshot links and refs/main in the real ~/.cache).
    func testShortClipGivesNoText() async throws {
        guard let directory = await ParakeetModel().locate() else { throw XCTSkip("Parakeet model not installed") }
        try await ParakeetEngine.shared.load(directory: directory)
        let short = try await ParakeetEngine.shared.transcribe(samples: [Float](repeating: 0, count: 3_200), language: "en", prompt: "")
        XCTAssertEqual(short, "")
        _ = try await ParakeetEngine.shared.transcribe(samples: [Float](repeating: 0, count: 16_000), language: "en", prompt: "")
    }
}
