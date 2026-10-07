import Foundation

/// How a note's text is shown in its row (0018): a title only when the user
/// wrote one, by starting a new line or writing ": " after a short first
/// part. Otherwise the whole note is body text.
struct NoteParts: Equatable {
    static let maxTitleLength = 60

    /// The bold first part, or nil when the note has no title.
    let title: String?
    /// Everything after the title, or the whole note when there is none.
    let body: String

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let split = Self.split(trimmed) {
            title = split.title
            body = split.body
        } else {
            title = nil
            body = trimmed
        }
    }

    /// What toasts and VoiceOver call the note: its title, or its first line.
    var name: String { title ?? String(body.prefix { !$0.isNewline }) }

    /// The body flattened to one line for the collapsed preview.
    var preview: String {
        body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    private static func split(_ text: String) -> (title: String, body: String)? {
        let firstLine = text.prefix { !$0.isNewline }
        let candidate: (Substring, Substring)?
        if firstLine.endIndex < text.endIndex {
            candidate = (firstLine, text[firstLine.endIndex...])
        } else if let colon = firstLine.range(of: ": ") {
            candidate = (firstLine[..<colon.lowerBound], text[colon.upperBound...])
        } else {
            candidate = nil
        }
        guard let (rawTitle, rawBody) = candidate else { return nil }
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= maxTitleLength, !body.isEmpty else { return nil }
        return (title, body)
    }
}

extension ItemSnapshot {
    /// What toasts and VoiceOver call a note: its title or first line, or
    /// "Image" for a note that is only images (0018).
    var name: String { text.isEmpty ? "Image" : NoteParts(text).name }
}
