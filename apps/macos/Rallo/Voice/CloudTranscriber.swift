import Foundation

/// Transcribes one phrase through an OpenAI-compatible endpoint with the
/// user's own key (0015). Audio and text are never logged.
struct CloudTranscriber: SpeechTranscribing {
    let provider: CloudVoiceProvider
    let endpoint: URL
    let model: String
    let key: String

    /// In-memory only, like ClickUp's session: no cache or cookies on disk.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    func transcribe(samples: [Float], language: String, prompt: String) async throws -> String {
        var fields = [("model", model), ("response_format", "json"), ("temperature", "0")]
        if language != "auto" { fields.append(("language", language)) }
        // ponytail: characters, not tokens; 800 stays under Groq's 224-token cap for ordinary words.
        if !prompt.isEmpty { fields.append(("prompt", String(prompt.prefix(800)))) }
        let boundary = "rallo-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Multipart.body(boundary: boundary, fields: fields, file: .init(
            field: "file", filename: "speech.wav", mime: "audio/wav", data: WAV.encode(samples: samples)))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code != .cancelled {
            throw VoiceMessage(text: provider.unreachableMessage)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VoiceMessage(text: provider.message(forStatus: status)) }
        guard let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String else {
            throw VoiceMessage(text: provider.message(forStatus: status))
        }
        return text
    }
}
