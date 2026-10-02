import Foundation
import whisper

enum WhisperEngineError: Error { case loadFailed, notLoaded, failed(Int32) }

/// The whisper.cpp context (0014). An actor so one transcription runs at a
/// time; it blocks its executor while whisper_full runs (seconds at most).
actor WhisperEngine {
    static let shared = WhisperEngine()

    private var context: OpaquePointer?
    private var loadedPath: String?
    private var idle: Task<Void, Never>?

    func load(path: String) throws {
        idle?.cancel()
        if context != nil, loadedPath == path { return scheduleUnload() }
        unload()
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let loaded = whisper_init_from_file_with_params(path, params) else { throw WhisperEngineError.loadFailed }
        context = loaded
        loadedPath = path
        scheduleUnload()
    }

    /// `language` is "auto", "en" or "bn"; `prompt` biases toward custom words.
    func transcribe(samples: [Float], language: String, prompt: String) throws -> String {
        guard let context else { throw WhisperEngineError.notLoaded }
        idle?.cancel()
        defer { scheduleUnload() }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.no_context = true
        params.no_timestamps = true
        params.suppress_blank = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        let status = language.withCString { lang in
            prompt.withCString { text in
                params.language = lang
                params.initial_prompt = text
                return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard status == 0 else { throw WhisperEngineError.failed(status) }
        var out = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let text = whisper_full_get_segment_text(context, i) { out += String(cString: text) }
        }
        return out
    }

    func unload() {
        idle?.cancel()
        if let context { whisper_free(context) }
        context = nil
        loadedPath = nil
    }

    /// The model holds about 2 GB; let it go after 10 idle minutes.
    private func scheduleUnload() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
