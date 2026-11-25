import FluidAudio
import Foundation

enum ParakeetEngineError: Error { case notLoaded }

/// The Parakeet TDT model through FluidAudio (0025). An actor so one
/// transcription runs at a time, like `WhisperEngine`.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private var manager: AsrManager?
    private var loadedDirectory: URL?
    private var idle: Task<Void, Never>?

    init() {
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
    }

    /// `directory` is the verified snapshot folder; `loadLocal` reads only that, never downloads.
    func load(directory: URL) async throws {
        idle?.cancel()
        if manager != nil, loadedDirectory == directory { return scheduleUnload() }
        unload()
        let models = try AsrModels.loadLocal(from: directory, version: .v2)
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        manager = loaded
        loadedDirectory = directory
        scheduleUnload()
    }

    /// English only: `language` and `prompt` are ignored.
    func transcribe(samples: [Float], language: String, prompt: String) async throws -> String {
        guard let manager else { throw ParakeetEngineError.notLoaded }
        idle?.cancel()
        defer { scheduleUnload() }
        // FluidAudio throws below 0.3 s.
        guard samples.count >= ParakeetModelStore.minimumSamples else { return "" }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }

    func unload() {
        idle?.cancel()
        let old = manager
        manager = nil
        loadedDirectory = nil
        if let old { Task { await old.cleanup() } }
    }

    /// Let the model go after 10 idle minutes.
    private func scheduleUnload() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
