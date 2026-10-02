import XCTest

final class CloudVoiceTests: XCTestCase {
    private func le(_ data: Data, _ at: Int, _ size: Int) -> Int {
        (0..<size).reduce(0) { $0 | Int(data[at + $1]) << (8 * $1) }
    }

    func testWAVHeader() {
        let wav = WAV.encode(samples: [0, 0.5, -0.5, 2, -2])
        XCTAssertEqual(wav.count, 44 + 10)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(le(wav, 4, 4), 36 + 10)
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(le(wav, 20, 2), 1)
        XCTAssertEqual(le(wav, 22, 2), 1)
        XCTAssertEqual(le(wav, 24, 4), 16000)
        XCTAssertEqual(le(wav, 34, 2), 16)
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(le(wav, 40, 4), 10)
    }

    func testWAVClamps() {
        let wav = WAV.encode(samples: [3, -3])
        XCTAssertEqual(Int16(truncatingIfNeeded: le(wav, 44, 2)), 32767)
        XCTAssertEqual(Int16(truncatingIfNeeded: le(wav, 46, 2)), -32767)
    }

    func testMultipart() {
        let file = Multipart.File(field: "file", filename: "a.wav", mime: "audio/wav", data: Data("AUDIO".utf8))
        let body = String(decoding: Multipart.body(boundary: "B", fields: [("model", "m"), ("temperature", "0")], file: file), as: UTF8.self)
        XCTAssertTrue(body.contains("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n"))
        XCTAssertTrue(body.contains("name=\"temperature\"\r\n\r\n0\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\nAUDIO\r\n"))
        XCTAssertTrue(body.hasSuffix("\r\n--B--\r\n"))
        XCTAssertFalse(body.contains("language"))
    }

    func testEndpoints() {
        XCTAssertEqual(CloudVoiceProvider.endpoint(base: CloudVoiceProvider.groq.defaultBase)?.absoluteString,
                       "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(CloudVoiceProvider.endpoint(base: CloudVoiceProvider.openai.defaultBase)?.absoluteString,
                       "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertNotNil(CloudVoiceProvider.endpoint(base: "https://example.com/v1/"))
        XCTAssertNotNil(CloudVoiceProvider.endpoint(base: "http://localhost:8080/v1"))
        XCTAssertNotNil(CloudVoiceProvider.endpoint(base: "http://127.0.0.1:8080"))
        XCTAssertNotNil(CloudVoiceProvider.endpoint(base: "http://[::1]:8080"))
        XCTAssertNil(CloudVoiceProvider.endpoint(base: "http://example.com"))
        XCTAssertNil(CloudVoiceProvider.endpoint(base: "ftp://localhost"))
        XCTAssertNil(CloudVoiceProvider.endpoint(base: "not a url"))
        XCTAssertNil(CloudVoiceProvider.endpoint(base: ""))
    }

    func testPresetModels() {
        let defaults = UserDefaults(suiteName: "CloudVoiceTests")!
        defer { defaults.removePersistentDomain(forName: "CloudVoiceTests") }
        XCTAssertEqual(CloudVoiceProvider.groq.resolve(defaults: defaults)?.model, "whisper-large-v3-turbo")
        defaults.set("whisper-large-v3", forKey: CloudVoiceProvider.groq.modelKey)
        XCTAssertEqual(CloudVoiceProvider.groq.resolve(defaults: defaults)?.model, "whisper-large-v3")
        XCTAssertNil(CloudVoiceProvider.custom.resolve(defaults: defaults))
    }

    func testErrorMessages() {
        XCTAssertEqual(CloudVoiceProvider.groq.message(forStatus: 401), "Groq didn’t accept the API key. Check Settings → Voice.")
        XCTAssertEqual(CloudVoiceProvider.groq.message(forStatus: 403), CloudVoiceProvider.groq.message(forStatus: 401))
        XCTAssertEqual(CloudVoiceProvider.openai.message(forStatus: 429), "OpenAI’s rate limit was reached. Try again in a minute.")
        XCTAssertEqual(CloudVoiceProvider.custom.message(forStatus: 500), "Custom couldn’t transcribe (HTTP 500).")
        XCTAssertEqual(CloudVoiceProvider.groq.unreachableMessage, "Couldn’t reach Groq.")
    }
}
