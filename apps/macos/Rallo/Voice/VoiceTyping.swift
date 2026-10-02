import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Speech

/// Permission checks shared by voice typing and Settings.
enum VoicePermissions {
    static var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func accessibilityAllowed(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt's literal value: the global var isn't concurrency-safe to read.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

}

/// A listening engine: Apple's (macOS 26+), Whisper (0014) or cloud (0015).
@MainActor
protocol VoiceEngineSession: AnyObject {
    var onStatus: (String) -> Void { get set }
    var onResult: (String, Bool) -> Void { get set }
    var onFailure: (Error) -> Void { get set }
    func start() async throws
    func stop() async
}

/// Voice typing (0013): ⌃⌥⌘V toggles listening; finalized phrases are typed
/// into the focused app, live words show in a bubble. Audio and text are
/// never stored or logged.
@MainActor
final class VoiceTyping {
    enum StopReason: String { case shortcut, silence, error }

    private let log: DiagnosticsLog
    private let bubble = VoiceBubble()
    private var session: (any VoiceEngineSession)?
    private var startTask: Task<Void, Never>?
    private var silenceTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var lastTyped: String?
    private(set) var isListening = false
    private var stopping = false

    var petFrame: () -> NSRect? {
        get { bubble.petFrame }
        set { bubble.petFrame = newValue }
    }

    init(log: DiagnosticsLog) { self.log = log }

    func toggle() {
        if isListening { stop(reason: .shortcut) } else { start() }
    }

    func start() {
        guard !isListening, !stopping else { return }
        isListening = true
        lastTyped = nil
        hideTask?.cancel()
        bubble.show("Listening…", listening: true)
        startTask = Task { [weak self] in
            guard let self else { return }
            guard await VoicePermissions.requestMicrophone() else { return fail(message: "Allow Rallo under Privacy & Security → Microphone") }
            guard VoicePermissions.accessibilityAllowed(prompt: true) else {
                return fail(message: "Allow Rallo under Privacy & Security → Accessibility")
            }
            guard isListening else { return }
            let session = Self.makeSession()
            session.onStatus = { [weak self] in self?.bubble.show($0, listening: false) }
            session.onResult = { [weak self] text, isFinal in self?.handle(text, isFinal: isFinal) }
            session.onFailure = { [weak self] error in
                guard let self, isListening else { return }
                log.record("voice_failed", ["error": String(describing: type(of: error))])
                stop(reason: .error)
            }
            self.session = session
            do {
                try await session.start()
                guard isListening else { return await session.stop() }
                log.record("voice_started")
                bubble.show("Listening…", listening: true)
                armSilenceTimer()
            } catch {
                self.session = nil
                await session.stop()
                if let message = error as? VoiceMessage, isListening { return fail(message: message.text) }
                if isListening { log.record("voice_failed", ["error": String(describing: type(of: error))]) }
                if isListening { stop(reason: .error) }
            }
        }
    }

    func stop(reason: StopReason) {
        guard isListening else { return }
        isListening = false
        stopping = true
        silenceTimer?.invalidate()
        silenceTimer = nil
        startTask?.cancel()
        log.record("voice_stopped", ["reason": reason.rawValue])
        let session = self.session
        self.session = nil
        Task { [weak self] in
            // Draining lets the last phrase finalize and get typed.
            await session?.stop()
            self?.stopping = false
            self?.bubble.hide()
        }
    }

    /// Whisper or cloud on request, and Whisper on macOS 14–25 where Apple's engine isn't there.
    private static func makeSession() -> any VoiceEngineSession {
        let engine = UserDefaults.standard.string(forKey: "voiceEngine")
        if engine == "cloud" { return WhisperVoiceSession.cloud() }
        if #available(macOS 26, *), engine != "whisper" { return VoiceSession() }
        return WhisperVoiceSession.local()
    }

    /// Permission problems: say so for a few seconds and don't start.
    private func fail(message: String) {
        isListening = false
        bubble.show(message, listening: false)
        flashThenHide()
    }

    private func flashThenHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !isListening else { return }
            bubble.hide()
        }
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: .silence) }
        }
    }

    private func handle(_ raw: String, isFinal: Bool) {
        if isListening { armSilenceTimer() }
        var text = VoiceText.sanitize(raw).trimmingCharacters(in: .whitespaces)
        if UserDefaults.standard.object(forKey: VoiceText.tidyKey) as? Bool ?? true {
            text = VoiceText.tidy(text, after: isFinal ? lastTyped : nil)
        }
        guard !text.isEmpty else { return }
        guard isFinal else {
            if isListening { bubble.show(text, listening: true) }
            return
        }
        if IsSecureEventInputEnabled() {
            bubble.show("Can’t type here: secure input is on", listening: isListening)
            return
        }
        TextTyper.type(VoiceText.joined(previous: lastTyped, next: text))
        lastTyped = text
        if isListening { bubble.show(text, listening: true) }
    }
}

/// One listening session on Apple's on-device DictationTranscriber.
@available(macOS 26, *)
@MainActor
final class VoiceSession: VoiceEngineSession {
    var onStatus: (String) -> Void = { _ in }
    var onResult: (String, Bool) -> Void = { _, _ in }
    var onFailure: (Error) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    func start() async throws {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus("Downloading Apple’s speech model…")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.noAudioFormat
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { throw VoiceError.noAudioFormat }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        // Biases recognition toward names it doesn't know ("Rallo" → "Rao" without it).
        let context = AnalysisContext()
        context.contextualStrings[.general] = VoiceText.contextWords(
            userList: UserDefaults.standard.string(forKey: VoiceText.wordsKey) ?? "")
        try await analyzer.setContext(context)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                self?.onFailure(error)
            }
        }
        try await analyzer.start(inputSequence: stream)
        Self.installTap(on: input, inputFormat: inputFormat, converter: converter, outFormat: format, continuation: continuation)
        engine.prepare()
        try engine.start()
    }

    /// Stops the mic, lets the analyzer finalize what it heard, and waits for
    /// the last results. Safe to call after a failed `start`.
    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        await resultsTask?.value
        resultsTask = nil
    }

    // Nonisolated so the audio-thread closure captures no main-actor state.
    private nonisolated static func installTap(on node: AVAudioInputNode, inputFormat: AVAudioFormat,
                                               converter: AVAudioConverter, outFormat: AVAudioFormat,
                                               continuation: AsyncStream<AnalyzerInput>.Continuation) {
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            nonisolated(unsafe) let source = buffer
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
            if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        }
    }
}

private enum VoiceError: Error { case noAudioFormat }
