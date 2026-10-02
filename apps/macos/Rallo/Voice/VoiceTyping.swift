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

    static var summary: String {
        "Microphone: \(microphoneAllowed ? "allowed" : "not allowed") · Accessibility: \(accessibilityAllowed(prompt: false) ? "allowed" : "not allowed")"
    }
}

/// Voice typing (0013): ⌃⌥⌘V toggles listening; finalized phrases are typed
/// into the focused app, live words show in a bubble. Audio and text are
/// never stored or logged.
@MainActor
final class VoiceTyping {
    enum StopReason: String { case shortcut, silence, error }

    private let log: DiagnosticsLog
    private let bubble = VoiceBubble()
    private var session: AnyObject?
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
        guard !isListening, !stopping, #available(macOS 26, *) else { return }
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
            let session = VoiceSession()
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
                if isListening { log.record("voice_failed", ["error": String(describing: type(of: error))]) }
                self.session = nil
                await session.stop()
                if isListening { stop(reason: .error) }
            }
        }
    }

    func stop(reason: StopReason) {
        guard isListening, #available(macOS 26, *) else { return }
        isListening = false
        stopping = true
        silenceTimer?.invalidate()
        silenceTimer = nil
        startTask?.cancel()
        log.record("voice_stopped", ["reason": reason.rawValue])
        let session = self.session as? VoiceSession
        self.session = nil
        Task { [weak self] in
            // Draining lets the last phrase finalize and get typed.
            await session?.stop()
            self?.stopping = false
            self?.bubble.hide()
        }
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
        let text = VoiceText.sanitize(raw).trimmingCharacters(in: .whitespaces)
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
final class VoiceSession {
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
