import AVFoundation
import Foundation

/// A problem to show the user in the bubble as-is.
struct VoiceMessage: Error { let text: String }

/// Audio from the tap thread, handed to the driver task.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ new: UnsafeBufferPointer<Float>) { lock.withLock { samples.append(contentsOf: new) } }

    func drain() -> [Float] { lock.withLock { defer { samples = [] }; return samples } }
}

/// One listening session on whisper.cpp (0014): the mic is cut into speech
/// segments by an energy VAD, each transcribed in order; while someone is
/// still speaking the bubble gets a preview about every 1.2 s.
@MainActor
final class WhisperVoiceSession: VoiceEngineSession {
    var onStatus: (String) -> Void = { _ in }
    var onResult: (String, Bool) -> Void = { _, _ in }
    var onFailure: (Error) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    private var driver: Task<Void, Never>?
    private let language = UserDefaults.standard.string(forKey: "voiceLanguage") ?? "auto"
    private let prompt = VoiceText.contextWords(userList: UserDefaults.standard.string(forKey: VoiceText.wordsKey) ?? "")
        .joined(separator: ", ")

    func start() async throws {
        onStatus("Loading Whisper…")
        guard let path = await WhisperModel().locate() else {
            throw VoiceMessage(text: "Download the Whisper model in Settings → Voice")
        }
        try await WhisperEngine.shared.load(path: path.path)
        try Task.checkCancellation()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: format) else { throw VoiceMessage(text: "No usable microphone") }
        Self.installTap(on: input, inputFormat: inputFormat, converter: converter, outFormat: format, buffer: buffer)
        engine.prepare()
        try engine.start()
        driver = Task { [weak self] in await self?.drive() }
    }

    /// Stops the mic; the driver flushes, transcribes and delivers what is left.
    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        driver?.cancel()
        await driver?.value
        driver = nil
    }

    private func drive() async {
        var segmenter = SpeechSegmenter()
        var samples: [Float] = []
        var base = 0  // absolute index of samples[0]
        var lastPreview = ContinuousClock.now
        do {
            while true {
                let cancelled = Task.isCancelled
                if !cancelled { try? await Task.sleep(for: .milliseconds(100)) }
                let new = buffer.drain()
                samples += new
                var ranges = segmenter.append(new)
                // ponytail: the last segment is flushed only on stop.
                if cancelled || Task.isCancelled, let last = segmenter.flush() { ranges.append(last) }
                for range in ranges { try await deliver(range, from: samples, base: base, isFinal: true) }
                if cancelled || Task.isCancelled { return }
                if let current = segmenter.current, current.count >= 8000, ContinuousClock.now - lastPreview >= .milliseconds(1200) {
                    try await deliver(current, from: samples, base: base, isFinal: false)
                    lastPreview = .now
                }
                // Keep only audio a segment may still need.
                let keep = segmenter.current?.lowerBound ?? max(0, base + samples.count - 4800)
                if keep - base > 160_000 {
                    samples.removeFirst(keep - base)
                    base = keep
                }
            }
        } catch {
            onFailure(error)
        }
    }

    private func deliver(_ range: Range<Int>, from samples: [Float], base: Int, isFinal: Bool) async throws {
        let lower = max(0, range.lowerBound - base)
        let upper = min(samples.count, range.upperBound - base)
        guard upper > lower else { return }
        let raw = try await WhisperEngine.shared.transcribe(samples: Array(samples[lower..<upper]), language: language, prompt: prompt)
        let text = WhisperText.clean(raw)
        if !text.isEmpty { onResult(text, isFinal) }
    }

    // Nonisolated so the audio-thread closure captures no main-actor state.
    private nonisolated static func installTap(on node: AVAudioInputNode, inputFormat: AVAudioFormat,
                                               converter: AVAudioConverter, outFormat: AVAudioFormat,
                                               buffer: SampleBuffer) {
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { input, _ in
            let capacity = AVAudioFrameCount(Double(input.frameLength) * outFormat.sampleRate / input.format.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            nonisolated(unsafe) let source = input
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return source
            }
            if error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] {
                buffer.append(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
        }
    }
}
