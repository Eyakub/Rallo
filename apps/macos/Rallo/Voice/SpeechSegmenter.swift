import Foundation

/// Energy-based voice activity detection over 30 ms frames of 16 kHz mono
/// audio (0014). Pure: it only sees samples and returns absolute index
/// ranges, so it is unit-tested without a microphone.
struct SpeechSegmenter {
    static let frame = 480
    private static let frameMs = 30
    private static let minSpeechFrames = 300 / frameMs
    private static let cutSilenceFrames = 700 / frameMs
    private static let maxSamples = 20 * 16000
    private static let preRollFrames = 3
    private static let tailFrames = 3

    private var pending: [Float] = []
    /// Absolute index of the first sample not yet in a whole frame.
    private var position = 0
    private var floor: Float = 0.002
    private var start: Int?
    private var lastSpeechEnd = 0
    private var lastCut = 0
    private var speechFrames = 0
    private var silentFrames = 0

    /// The in-progress speech span, once speech has begun.
    var current: Range<Int>? { start.map { $0..<position } }

    /// Feeds samples; returns the segments that finished, in order.
    mutating func append(_ samples: [Float]) -> [Range<Int>] {
        pending += samples
        var done: [Range<Int>] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            var sum: Float = 0
            for i in offset..<(offset + Self.frame) { sum += pending[i] * pending[i] }
            offset += Self.frame
            if let range = step(rms: (sum / Float(Self.frame)).squareRoot()) { done.append(range) }
        }
        pending.removeFirst(offset)
        return done
    }

    /// Ends the segment in progress, if it holds enough speech.
    mutating func flush() -> Range<Int>? {
        defer { reset(at: position) }
        guard let start, speechFrames >= Self.minSpeechFrames else { return nil }
        return start..<min(position, lastSpeechEnd + Self.tailFrames * Self.frame)
    }

    private mutating func reset(at index: Int) {
        start = nil
        speechFrames = 0
        silentFrames = 0
        lastCut = index
    }

    /// Handles one frame ending at `position + frame`.
    private mutating func step(rms: Float) -> Range<Int>? {
        let begin = position
        position += Self.frame
        let isSpeech = rms > max(0.008, floor * 3)
        // Drops to a quiet frame at once, rises slowly (barely during speech,
        // so a long sentence can't raise it): a decaying minimum.
        floor = rms < floor ? rms : floor + (rms - floor) * (isSpeech ? 0.0001 : 0.002)
        if isSpeech {
            if start == nil { start = max(lastCut, begin - Self.preRollFrames * Self.frame) }
            speechFrames += 1
            silentFrames = 0
            lastSpeechEnd = position
        } else if start != nil {
            silentFrames += 1
            if silentFrames >= Self.cutSilenceFrames {
                guard speechFrames >= Self.minSpeechFrames else {
                    reset(at: position)  // a click or cough, not speech
                    return nil
                }
                return finish(end: min(position, lastSpeechEnd + Self.tailFrames * Self.frame))
            }
        }
        if let start, position - start >= Self.maxSamples { return finish(end: position) }
        return nil
    }

    private mutating func finish(end: Int) -> Range<Int>? {
        let range = start.map { $0..<end }
        reset(at: position)
        return range
    }
}
