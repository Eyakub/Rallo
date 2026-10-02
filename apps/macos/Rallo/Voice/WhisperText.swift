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
}
