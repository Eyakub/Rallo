import SwiftUI

/// Tints `#tags` in row text (0019 §10). The core finds them (`tagRanges`,
/// UTF-16 offsets into the string it was given), so Swift never re-implements
/// the grammar.
enum TagTint {
    /// Rows show substrings of a note (title, body, one-line preview), so the
    /// core is asked about exactly the string that will be drawn.
    // ponytail: one small FFI call per drawn string; cache per note id if a profile ever shows it.
    static func attributed(_ text: String, size: CGFloat) -> AttributedString {
        attributed(text, ranges: tagRanges(text: text), size: size)
    }

    static func attributed(_ text: String, ranges: [TagRange], size: CGFloat) -> AttributedString {
        var result = AttributedString(text)
        let units = text.utf16
        let scalars = text.unicodeScalars
        for tag in ranges where tag.utf16Len > 0 {
            // Ranges that run past the text, or start or end inside an emoji's
            // surrogate pair, are skipped rather than trusted.
            guard let from = units.index(units.startIndex, offsetBy: Int(tag.utf16Start), limitedBy: units.endIndex),
                  let to = units.index(from, offsetBy: Int(tag.utf16Len), limitedBy: units.endIndex),
                  from.samePosition(in: scalars) != nil, to.samePosition(in: scalars) != nil,
                  let range = Range(from..<to, in: result)
            else { continue }
            result[range].foregroundColor = Theme.rust
            result[range].font = .system(size: size, weight: .semibold)
        }
        return result
    }
}
