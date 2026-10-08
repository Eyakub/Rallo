import Foundation

/// Pure cleanup of Whisper output (0014).
enum WhisperText {
    /// Removes `[...]` and `(...)` annotations such as `[BLANK_AUDIO]` or
    /// `(music)`, trims, and collapses spaces. "" when nothing real is left.
    static func clean(_ raw: String) -> String {
        var out = ""
        var depth = 0
        var closer: Character = "]"
        for ch in raw {
            if depth == 0, ch == "[" || ch == "(" {
                depth = 1
                closer = ch == "[" ? "]" : ")"
            } else if depth > 0 {
                if ch == closer { depth = 0 }
            } else {
                out.append(ch)
            }
        }
        // An unterminated annotation drops itself and the rest; text before it stays.
        let words = out.split(whereSeparator: { $0.isWhitespace })
        let text = words.joined(separator: " ")
        // Only punctuation left (say "." after a removed token) is not speech.
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
    }

    private static let stockPhrases: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "please subscribe",
        "you", "bye", "i'm sorry", "subtitles by the amara.org community",
    ]

    /// True when `text` is exactly one of Whisper's stock hallucinations
    /// (case and punctuation aside) and the audio was under 2 s. A longer
    /// segment that really says "thank you" is kept.
    static func isPhantom(_ text: String, seconds: Double) -> Bool {
        guard seconds < 2 else { return false }
        let key = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" || $0 == "." }
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return stockPhrases.contains(key)
    }

    /// Whether 16 kHz audio holds speech: 100 ms frames (at least 3), speech
    /// when the loud frames (95th percentile RMS) are above 0.008 and 2.5x the
    /// background (20th percentile). Whisper invents "Thank you." from noise,
    /// so a segment failing this is never transcribed. The idea is from
    /// hoole's `containsSpeech`.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        let frame = 1600
        let count = samples.count / frame
        guard count >= 3 else { return false }
        let levels = (0..<count).map { i -> Float in
            var sum: Float = 0
            for s in samples[(i * frame)..<((i + 1) * frame)] { sum += s * s }
            return (sum / Float(frame)).squareRoot()
        }.sorted()
        let background = levels[Int(Float(count) * 0.2)]
        let loud = levels[min(count - 1, Int(Float(count) * 0.95))]
        return loud > 0.008 && loud > background * 2.5
    }
}
