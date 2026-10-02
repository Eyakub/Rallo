import Foundation

/// Pure text rules for voice typing (0013). Nothing here touches AppKit.
enum VoiceText {
    /// Newlines, carriage returns, and tabs become spaces, and runs of spaces
    /// collapse, so typed text can never press Return or Tab in a terminal.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in s.unicodeScalars {
            let isBreak = CharacterSet.newlines.contains(scalar) || scalar == "\t"
            let mapped: Unicode.Scalar = isBreak ? " " : scalar
            if mapped == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            out.append(mapped)
        }
        return String(out)
    }

    /// What to type for `next` after `previous` was typed.
    static func joined(previous: String?, next: String) -> String {
        guard let previous, let last = previous.last, let first = next.first else { return next }
        if last.isWhitespace || first.isWhitespace || ".,!?;:)".contains(first) { return next }
        return " " + next
    }

    /// Splits at grapheme boundaries (so surrogate pairs and clusters stay
    /// whole) into pieces of at most `maxUTF16` UTF-16 units; one cluster
    /// longer than that is kept alone.
    static func chunks(_ s: String, maxUTF16: Int = 16) -> [String] {
        var result: [String] = []
        var current = ""
        var count = 0
        for ch in s {
            let n = ch.utf16.count
            if count + n > maxUTF16, !current.isEmpty {
                result.append(current)
                current = ""
                count = 0
            }
            current.append(ch)
            count += n
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
