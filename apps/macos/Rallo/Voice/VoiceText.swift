import Foundation

/// Pure text rules for voice typing (0013). Nothing here touches AppKit.
enum VoiceText {
    /// UserDefaults key for the user's "Words to recognize" (Settings → General).
    static let wordsKey = "voiceTypingWords"
    /// Words the engine would otherwise mishear ("Rallo" became "Rao").
    static let builtInWords = ["Rallo", "ClickUp", "cmux", "Claude", "Codex", "Grok", "Gemini"]

    /// UserDefaults key for "Clean up stutters and fillers" (on unless set false).
    static let tidyKey = "voiceTidy"
    private static let fillers: Set<String> = ["um", "umm", "uh", "uhm", "er", "erm", "hmm", "mm", "mhm"]

    /// Fillers are English; true when the voice language is English, or auto on an English Mac.
    static func fillersApply(language: String? = UserDefaults.standard.string(forKey: "voiceLanguage")) -> Bool {
        switch language {
        case nil, "auto": Locale.current.language.languageCode == .english
        case "en": true
        default: false
        }
    }

    /// Drops filler sounds ("um", "uh") and collapses a word said twice in a
    /// row ("like like", "I I think"), also across the boundary with the text
    /// typed before (`previous`). Words with digits are never collapsed, so
    /// "5 5 5" stays. A filler used as a real word ("like" in "it was, like,
    /// fine") needs understanding and is left to AI cleanup.
    static func tidy(_ text: String, after previous: String? = nil, dropFillers: Bool = fillersApply()) -> String {
        func word(_ token: Substring) -> String {
            token.trimmingCharacters(in: .punctuationCharacters).lowercased()
        }
        var out: [Substring] = []
        var prevToken = previous?.split(separator: " ").last
        var last = prevToken.map(word)
        for token in text.split(separator: " ") {
            let current = word(token)
            // "5 mm" and "5 Uhr" are not fillers; neither is "no" after "no."
            let afterDigit = prevToken?.contains(where: \.isNumber) ?? false
            if dropFillers, !afterDigit, fillers.contains(current) { continue }
            let sentenceEnd = prevToken.map { ".!?".contains($0.last ?? " ") } ?? false
            if !current.isEmpty, current == last, !sentenceEnd, !current.contains(where: \.isNumber) {
                // Keep the later token's punctuation ("like like," → "like,").
                if !out.isEmpty { out[out.count - 1] = token }
                prevToken = token
                continue
            }
            out.append(token)
            last = current
            prevToken = token
        }
        return out.joined(separator: " ")
    }

    /// Built-in words plus the user's comma- or newline-separated list,
    /// trimmed, without duplicates (case-insensitive), at most 100.
    static func contextWords(userList: String) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        let user = userList.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        for word in builtInWords + user where !word.isEmpty && seen.insert(word.lowercased()).inserted {
            words.append(word)
        }
        return Array(words.prefix(100))
    }

    /// Newlines, tabs and other control characters become spaces, and runs of spaces
    /// collapse, so typed text can never press Return or Tab in a terminal.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in s.unicodeScalars {
            // Control characters (^O, ^C, ESC...) would act as shortcuts in a terminal.
            let isBreak = CharacterSet.newlines.contains(scalar) || scalar.properties.generalCategory == .control
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
