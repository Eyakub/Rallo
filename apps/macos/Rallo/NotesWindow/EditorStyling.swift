import Foundation

/// What the notes window's editor styles in a note's text (0019 §11). Pure:
/// ranges are UTF-16, as `NSTextView` and the core's `tag_ranges` count.
struct EditorSpan: Equatable {
    enum Kind: Equatable { case title, tag }

    let kind: Kind
    let range: NSRange
}

enum EditorStyling {
    static let titleSize: CGFloat = 24
    static let bodySize: CGFloat = 14.5

    /// The `NoteParts` title where it sits in the text (leading blank space
    /// skipped); nil when the note has none.
    static func titleRange(in text: String) -> NSRange? {
        guard let title = NoteParts(text).title else { return nil }
        let range = (text as NSString).range(of: title, options: .literal)
        return range.location == NSNotFound ? nil : range
    }

    /// The title, then each tag. The core's ranges cover the `#` and are UTF-16
    /// offsets into exactly the string passed to `tagRanges` (§7); one that
    /// doesn't fit the text is dropped.
    static func spans(text: String, tags: [TagRange]) -> [EditorSpan] {
        let length = (text as NSString).length
        var spans: [EditorSpan] = []
        if let title = titleRange(in: text) { spans.append(EditorSpan(kind: .title, range: title)) }
        for tag in tags {
            let range = NSRange(location: Int(tag.utf16Start), length: Int(tag.utf16Len))
            guard range.length > 0, NSMaxRange(range) <= length else { continue }
            spans.append(EditorSpan(kind: .tag, range: range))
        }
        return spans
    }
}

/// A note's two lines in the list: its title (or first line) and what follows.
struct RowText: Equatable {
    let title: String
    let preview: String

    init(_ text: String) {
        let parts = NoteParts(text)
        if let title = parts.title {
            self.title = title
            preview = parts.preview
        } else {
            let lines = parts.body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            title = lines.first ?? ""
            preview = lines.dropFirst().joined(separator: " ")
        }
    }

    /// An image-only note has no text to show.
    var displayTitle: String { title.isEmpty ? "Image" : title }
}
