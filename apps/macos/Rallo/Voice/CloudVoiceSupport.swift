import Foundation

/// The cloud voice engine's providers (0015). Pure: no network, no Keychain.
enum CloudVoiceProvider: String, CaseIterable, Sendable {
    case groq, openai, custom

    static let keychainService = "rallo-voice-api-key"
    static let providerKey = "voiceCloudProvider"
    static let baseURLKey = "voiceCloudBaseURL"

    var name: String {
        switch self {
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .custom: "Custom"
        }
    }

    var defaultBase: String {
        switch self {
        case .groq: "https://api.groq.com/openai/v1"
        case .openai: "https://api.openai.com/v1"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .groq: "whisper-large-v3-turbo"
        case .openai: "whisper-1"
        case .custom: ""
        }
    }

    var helpURL: URL? {
        switch self {
        case .groq: URL(string: "https://console.groq.com/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .custom: nil
        }
    }

    /// Custom keeps its model in `voiceCloudModel`; the presets' overrides are per provider.
    var modelKey: String { self == .custom ? "voiceCloudModel" : "voiceCloudModel.\(rawValue)" }

    var keychainLabel: String { "Rallo: \(name) API key" }

    /// https only, except a local whisper-server on this Mac.
    static func endpoint(base: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        return URL(string: text + "/audio/transcriptions")
    }

    /// The endpoint and model to use, or nil when a custom base URL or model is missing or invalid.
    func resolve(defaults: UserDefaults = .standard) -> (endpoint: URL, model: String)? {
        let base = self == .custom ? defaults.string(forKey: Self.baseURLKey) ?? "" : defaultBase
        let typed = defaults.string(forKey: modelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = typed.isEmpty ? defaultModel : typed
        guard let endpoint = Self.endpoint(base: base), !model.isEmpty else { return nil }
        return (endpoint, model)
    }

    func message(forStatus code: Int) -> String {
        switch code {
        case 401, 403: "\(name) didn’t accept the API key. Check Settings → Voice."
        case 429: "\(name)’s rate limit was reached. Try again in a minute."
        default: "\(name) couldn’t transcribe (HTTP \(code))."
        }
    }

    var unreachableMessage: String { "Couldn’t reach \(name)." }
    var missingKeyMessage: String { "Add your \(name) API key in Settings → Voice" }
}

/// 16-bit PCM mono WAV in memory.
enum WAV {
    static func encode(samples: [Float], sampleRate: Int = 16000) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// multipart/form-data, as the OpenAI-compatible transcription endpoints take it.
enum Multipart {
    struct File { let field: String, filename: String, mime: String, data: Data }

    static func body(boundary: String, fields: [(String, String)], file: File) -> Data {
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mime)\r\n\r\n")
        body.append(file.data)
        add("\r\n--\(boundary)--\r\n")
        return body
    }
}
